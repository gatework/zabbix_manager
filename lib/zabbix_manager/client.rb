# frozen_string_literal: true

require "json"
require "logger"

class ZabbixManager
  class Client
    SUPPORTED_MAJOR_VERSIONS = (4..7).freeze
    UNAUTHENTICATED_METHODS = %w[apiinfo.version user.login].freeze
    BLANK_NORMALIZED_OPTIONS = %i[api_token username user password http_user http_password].freeze
    UPSERT_MUTEX_STRIPES = 64
    DEFAULT_UNCERTAIN_WRITE_DELAYS = [0, 0.25, 1, 2].freeze

    attr_reader :options, :sanitized_options, :logger

    # 构建按服务端版本选择认证方式并复用 HTTP 会话的客户端。
    # @return [Client]
    # @api public
    def initialize(options = {})
      @raw_options = normalize_options(options)
      validate_credentials!
      validate_uncertain_write_delays!
      @sanitized_options = sanitize_options(@raw_options).freeze
      @options = @sanitized_options
      @logger = build_logger
      @id_mutex = Mutex.new
      @next_id = 0
      @upsert_mutexes = Array.new(UPSERT_MUTEX_STRIPES) { Mutex.new }
      validate_upsert_lock!
      @transport = HttpTransport.new(@raw_options)
      validate_token_transport!
      @api_version = api_version
      validate_api_version!
      validate_http_auth_compatibility!
      @credential_type = @raw_options[:api_token] ? :api_token : :user_session
      @auth_token = @raw_options[:api_token] || auth
      log(:info, "client.connected", version: @api_version, credential_type: @credential_type)
      log(:warn, "tls.verification_disabled", url: @transport.safe_url) if insecure_https?
      log(:warn, "token.sent_over_http", url: @transport.safe_url) if insecure_token_transport?
    rescue StandardError
      @transport&.close
      raise
    end

    # 分配线程安全的 JSON-RPC 请求编号。
    # @return [Integer]
    # @api semipublic
    def id
      @id_mutex.synchronize { @next_id += 1 }
    end

    # 返回首次查询后缓存的远端 Zabbix API 版本。
    # @return [String]
    # @api public
    def api_version
      @api_version ||= api_request(method: "apiinfo.version", params: {})
    end

    # 使用用户名和密码创建 Zabbix 会话。
    # @return [String] Zabbix session token
    # @api semipublic
    def auth
      api_request(
        method: "user.login",
        params: {
          login_parameter => username,
          password: @raw_options[:password]
        }
      )
    end

    # 判断是否启用调试日志。
    # @return [Boolean]
    # @api semipublic
    def debug?
      @raw_options[:debug] == true
    end

    # 序列化 JSON-RPC 请求并按版本加入请求体认证。
    # @return [String]
    # @api semipublic
    def message_json(body)
      method = fetch_body_value(body, :method)
      message = {
        method: method,
        params: fetch_body_value(body, :params) || {},
        id: id,
        jsonrpc: "2.0"
      }
      message[:auth] = @auth_token if @auth_token && body_authentication?(method)
      JSON.generate(message)
    end

    # 通过持久连接发送请求，并按版本加入 Bearer 令牌。
    # @return [String] raw response body
    # @api semipublic
    def http_request(body)
      method = JSON.parse(body).fetch("method")
      @transport.request(body, bearer_token: bearer_token_for(method))
    end

    # 解析 JSON-RPC 响应并统一转换协议错误。
    # @return [Object]
    # @api semipublic
    def _request(body)
      parsed = JSON.parse(http_request(body))
      raise_api_error(parsed, body) if parsed["error"]
      unless parsed.key?("result")
        raise ApiError.new("Invalid JSON-RPC response: missing result", LogSanitizer.sanitize(parsed))
      end

      parsed["result"]
    rescue JSON::ParserError => e
      raise ApiError, "Invalid JSON response: #{e.message}"
    end

    # 格式化请求摘要并隐藏全部参数值。
    # @return [String]
    # @api semipublic
    def pretty_body(body)
      parsed = JSON.parse(body)
      parsed["params"] = LogSanitizer::REDACTED if parsed.key?("params")
      JSON.pretty_generate(LogSanitizer.sanitize(parsed))
    end

    # 执行 Zabbix JSON-RPC 方法并记录脱敏耗时日志。
    # @return [Object] decoded result value
    # @api public
    def api_request(body)
      method = fetch_body_value(body, :method)
      started_at = monotonic_time
      log(:debug, "request.started", method: method)
      result = _request(message_json(body))
      log(:info, "request.completed", method: method, duration_ms: elapsed_ms(started_at))
      result
    rescue StandardError => e
      log(:warn, "request.failed", method: method, duration_ms: elapsed_ms(started_at), error: e.class.name)
      raise
    end
    alias manager_request api_request

    # 注销用户名会话并关闭持久连接；API 令牌无需远端注销。
    # @return [Object] logout result
    # @api public
    def logout
      result = @credential_type == :user_session && @auth_token ? api_request(method: "user.logout", params: []) : true
      result
    ensure
      @auth_token = nil
      close
    end

    # 关闭持久 HTTP 连接。
    # @return [Object]
    # @api public
    def close
      @transport.close
    end

    # 输出结构化且已脱敏的客户端事件。
    # @return [void]
    # @api semipublic
    def log(level, event, data = {})
      return unless @logger

      sanitized = LogSanitizer.sanitize(data)
      details = sanitized.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
      @logger.public_send(level, ["[zabbix_manager]", event, details].reject(&:empty?).join(" "))
    end

    # 返回不包含凭据的客户端摘要，避免对象检查时泄漏配置
    # @return [String]
    # @api public
    def inspect
      "#<#{self.class} options=#{@sanitized_options.inspect}>"
    end

    # 以业务键串行执行幂等写入，并可接入跨进程锁实现
    # @return [Object] 代码块结果
    # @api semipublic
    def with_upsert_lock(key, &block)
      mutex = @upsert_mutexes[key.hash % UPSERT_MUTEX_STRIPES]
      mutex.synchronize do
        coordinator = @raw_options[:upsert_lock]
        coordinator ? coordinator.call(key, &block) : yield
      end
    end

    private

      # 统一配置键并把页面提交的空凭据归一化为 nil
      # @return [Hash]
      # @api private
      def normalize_options(options)
        unless options.respond_to?(:each_pair)
          raise Invalid, "options must be a hash-like object"
        end

        normalized = options.to_h.transform_keys(&:to_sym)
        BLANK_NORMALIZED_OPTIONS.each do |key|
          value = normalized[key].presence
          value ? normalized[key] = value : normalized.delete(key)
        end
        normalized
      end

      # 脱敏普通凭据，并清理 URL 和代理地址中的 userinfo 与查询串。
      def sanitize_options(options)
        sanitized = LogSanitizer.sanitize(options)
        %i[url proxy].each do |key|
          sanitized[key] = LogSanitizer.sanitize_url(options[key]) if options[key]
        end
        sanitized
      end

      # 校验页面配置只能选择 API 令牌或用户名密码之一。
      # @return [void]
      # @api private
      def validate_credentials!
        raise Invalid, "url is required" if @raw_options[:url].nil? || @raw_options[:url].to_s.empty?

        token_present = @raw_options[:api_token].present?
        username_present = username.present?
        password_present = @raw_options[:password].present?
        if token_present && (username_present || password_present)
          raise Invalid, "api_token cannot be combined with username/password"
        end
        return if token_present || (username_present && password_present)

        raise Invalid, "provide api_token or both username and password"
      end

      # 校验传输结果不确定时的只读回查退避窗口。
      def validate_uncertain_write_delays!
        values = @raw_options.fetch(:uncertain_write_delays, DEFAULT_UNCERTAIN_WRITE_DELAYS)
        delays = Array(values).map { |value| Float(value) }
        unless delays.any? && delays.length <= 10 && delays.all? { |delay| delay >= 0 } && delays.sum <= 60
          raise Invalid, "uncertain_write_delays must contain 1 to 10 non-negative seconds totaling at most 60"
        end

        @raw_options[:uncertain_write_delays] = delays.freeze
      rescue ArgumentError, TypeError
        raise Invalid, "uncertain_write_delays must contain numeric seconds"
      end

      # 校验可选的跨进程幂等锁适配器。
      # @return [void]
      # @api private
      def validate_upsert_lock!
        lock = @raw_options[:upsert_lock]
        return if lock.nil? || lock.respond_to?(:call)

        raise Invalid, "upsert_lock must respond to call(key, &block)"
      end

      # 校验服务端版本格式及支持范围。
      # @return [void]
      # @api private
      def validate_api_version!
        match = @api_version.to_s.match(/\A(\d+)\.(\d+)\.(\d+)\z/)
        supported = match && SUPPORTED_MAJOR_VERSIONS.cover?(match[1].to_i)
        return if supported

        message = "Zabbix API version #{@api_version.inspect} is not supported"
        if @raw_options[:ignore_version]
          log(:warn, "version.unsupported", version: @api_version)
        else
          raise ApiError, message
        end
      end

      # 拒绝 Zabbix 7 Bearer 认证与 HTTP Basic 复用同一认证头。
      # @return [void]
      # @api private
      def validate_http_auth_compatibility!
        return unless api_major_version >= 7 && @raw_options[:http_user].present?

        raise Invalid, "HTTP Basic authentication cannot be combined with Zabbix 7 Bearer authentication"
      end

      # 默认阻止 API 令牌通过明文 HTTP 发送
      # @return [void]
      # @api private
      def validate_token_transport!
        return unless @raw_options[:api_token] && insecure_token_transport?
        return if @raw_options[:allow_insecure_http] == true

        raise Invalid, "api_token requires HTTPS unless allow_insecure_http is true"
      end

      # 判断当前令牌连接是否使用明文 HTTP
      # @return [Boolean]
      # @api private
      def insecure_token_transport?
        @raw_options[:api_token].present? && @transport.uri.scheme == "http"
      end

      # 提取已缓存 API 版本的主版本号。
      def api_major_version
        @api_version.to_s.split(".", 2).first.to_i
      end

      # 根据服务端版本选择登录用户名字段。
      def login_parameter
        api_major_version >= 6 ? :username : :user
      end

      # 返回统一后的登录用户名。
      def username
        @raw_options[:username] || @raw_options[:user]
      end

      # 判断当前方法是否应在 JSON-RPC 请求体中携带认证值。
      def body_authentication?(method)
        authenticated_method?(method) && api_major_version < 7
      end

      # 判断当前方法是否应使用 Bearer 认证头。
      def bearer_token_for(method)
        @auth_token if authenticated_method?(method) && api_major_version >= 7
      end

      # 排除版本查询和登录方法，判断请求是否需要认证。
      def authenticated_method?(method)
        !UNAUTHENTICATED_METHODS.include?(method.to_s)
      end

      # 同时读取符号键和字符串键的请求字段。
      def fetch_body_value(body, key)
        body[key] || body[key.to_s]
      end

      # 使用脱敏响应和请求摘要构造 API 异常。
      def raise_api_error(parsed, request_body)
        safe_response = LogSanitizer.sanitize(parsed)
        error = safe_response["error"]
        message = "Zabbix API error #{error["code"]}: #{error["message"]}"
        message = "#{message} (#{error["data"]})" if error["data"]
        raise ApiError.new("#{message}\nRequest:\n#{pretty_body(request_body)}", safe_response)
      end

      # 优先使用调用方日志器，调试模式下才创建默认日志器。
      def build_logger
        return @raw_options[:logger] if @raw_options[:logger]
        return unless debug?

        Logger.new($stdout).tap { |value| value.level = Logger::DEBUG }
      end

      # 判断 HTTPS 是否按项目要求关闭证书校验。
      def insecure_https?
        @transport.uri.scheme == "https" && @raw_options[:verify_ssl] != true
      end

      # 读取不受系统时间校准影响的单调时钟。
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # 计算并格式化请求耗时毫秒数。
      def elapsed_ms(started_at)
        ((monotonic_time - started_at) * 1_000).round(1)
      end
  end
end
