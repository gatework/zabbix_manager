# frozen_string_literal: true

require "json"
require "logger"
require "active_support"
require "active_support/logger"
require "active_support/tagged_logging"

class ZabbixManager
  # 持有一个已认证连接，管理 JSON-RPC 请求的完整生命周期。
  class Client
    SUPPORTED_MAJOR_VERSIONS = (4..7)
    UNAUTHENTICATED_METHODS = %w[apiinfo.version user.login].freeze
    UPSERT_MUTEX_STRIPES = 64
    LOG_LEVELS = { debug: Logger::DEBUG, info: Logger::INFO, warn: Logger::WARN,
                   error: Logger::ERROR, fatal: Logger::FATAL, unknown: Logger::UNKNOWN }.freeze
    private_constant :LOG_LEVELS

    attr_reader :options, :logger, :api_version

    # 校验配置后立即查询服务器版本并完成认证。
    # 初始化失败时关闭连接；成功后的客户端生命周期由调用方负责。
    # @param options [Hash] 显式连接、凭据、日志及锁配置
    # @raise [Invalid] 连接配置无效或相互冲突
    # @raise [ApiError, TransportError, ProtocolError] 版本查询或认证失败
    def initialize(**options)
      @settings = Configuration.parse(options)
      @options = sanitized_options.freeze
      @logger = build_logger
      @id_mutex = Mutex.new
      @next_id = 0
      @upsert_mutexes = Array.new(UPSERT_MUTEX_STRIPES) { Mutex.new }
      @transport = HttpTransport.new(@settings)
      validate_token_transport!
      @api_version = api_request(method: "apiinfo.version")
      validate_api_version!
      validate_http_auth_compatibility!
      @credential_type = @settings[:api_token] ? :api_token : :user_session
      @auth_token = @settings[:api_token] || login
      unless @auth_token.is_a?(String) && !@auth_token.empty?
        raise ProtocolError, "Invalid authentication response"
      end

      log(:info, "client.connected", version: @api_version, credential_type: @credential_type)
      log(:warn, "tls.verification_disabled", url: @transport.safe_url) if insecure_https?
      log(:warn, "token.sent_over_http", url: @transport.safe_url) if insecure_token_transport?
    rescue StandardError
      @transport&.close
      raise
    end

    # 执行一次请求，不重放失败或结果未确认的变更。
    # @param method [String] 原生 API 方法，例如 "history.get"
    # @param params [Hash, Array] 原生 Zabbix 参数，不将参数值写入日志
    # @return [Object] 解码后的 JSON-RPC 结果，保留服务器返回的标量类型
    # @raise [Invalid] 方法名或参数容器无效
    # @raise [ApiError] 服务器明确拒绝请求
    # @raise [TransportError, ProtocolError] 未收到能够确认结果的有效响应
    def api_request(method:, params: {})
      method = method.dup.freeze if method.is_a?(String)
      validate_request!(method, params)
      started_at = monotonic_time
      message = request_message(method, params)
      log(:debug, "request.started", method: method, request_id: message[:id])
      body = @transport.request(JSON.generate(message), bearer_token: bearer_token_for(method))
      result = parse_response(body, message.fetch(:id))
      log(:info, "request.completed", method: method, request_id: message[:id], duration_ms: elapsed_ms(started_at))
      result
    rescue StandardError => error
      if started_at
        log(:warn, "request.failed", method: method, request_id: message&.fetch(:id),
                                     duration_ms: elapsed_ms(started_at), error: error.class.name)
      end
      raise
    end

    # 注销密码认证会话；API token 仅需清理本地状态。
    # 远端注销失败时仍清除本地认证令牌并关闭传输连接。
    # @return [Boolean] 服务器注销结果；API token 模式返回 true
    # @raise [ApiError, TransportError] 远端会话注销失败
    def logout
      @credential_type == :user_session && @auth_token ? api_request(method: "user.logout", params: []) : true
    ensure
      @auth_token = nil
      close
    end

    # 关闭连接但不撤销凭据；后续请求按需重新连接。
    # @return [true]
    def close
      @transport.close
    end

    # 延迟构造日志元数据；日志失败不能改变远端写入结果。
    # @param level [Symbol] Ruby Logger 日志级别方法
    # @param event [String] 稳定的事件名称
    # @param data [Hash] 序列化之前经过脱敏的元数据
    # @return [Object, nil] 日志返回值；日志关闭或失败时返回 nil
    def log(level, event, data = {})
      return unless @logger

      severity = LOG_LEVELS[level]
      return if severity && @logger.respond_to?(:level) && @logger.level > severity

      @logger.tagged("zabbix_manager") do
        @logger.public_send(level) { JSON.generate(LogSanitizer.sanitize(data.merge(event: event))) }
      end
    rescue StandardError
      nil
    end

    # @return [String] 仅包含脱敏配置的诊断摘要
    def inspect
      "#<#{self.class} options=#{@options.inspect}>"
    end

    # 应用层锁适配器可将本地串行化扩展到多个工作进程。
    # 锁不可重入；调用方不能在块内再次获取 upsert 锁。
    # @param key [String] 被保护操作的稳定、非秘密身份
    # @yield 需要串行执行的读取、修改和写入操作
    # @return [Object] 块的返回值
    def with_upsert_lock(key, &block)
      @upsert_mutexes[key.hash % UPSERT_MUTEX_STRIPES].synchronize do
        coordinator = @settings[:upsert_lock]
        coordinator ? coordinator.call(key, &block) : yield
      end
    end

    private

    def sanitized_options
      LogSanitizer.sanitize(@settings.except(:logger, :upsert_lock)).tap do |safe|
        safe[:uncertain_write_delays].freeze
        %i[url proxy].each do |key|
          safe[key] = LogSanitizer.sanitize_url(@settings[key]) if @settings[key]
        end
      end
    end

    def build_logger
      source = @settings[:logger]
      return if source.nil? && @settings[:log_level].nil?

      source ||= ActiveSupport::Logger.new($stderr)
      ActiveSupport::TaggedLogging.new(source).tap do |logger|
        logger.level = @settings[:log_level] if @settings.key?(:log_level)
      end
    rescue ArgumentError, TypeError
      raise Invalid, "log_level must be a Ruby Logger severity", cause: nil
    end

    def validate_request!(method, params)
      valid_method = method.is_a?(String) && method.valid_encoding? && method.ascii_only? &&
                     method.match?(/\A[a-z][a-z0-9_]*\.[a-z][a-zA-Z0-9_]*\z/)
      unless valid_method
        raise Invalid, "method must be a Zabbix API method name"
      end
      raise Invalid, "params must be a Hash or Array" unless params.is_a?(Hash) || params.is_a?(Array)
    end

    def request_message(method, params)
      request_id = @id_mutex.synchronize { @next_id += 1 }
      { method: method, params: params, id: request_id, jsonrpc: "2.0" }.tap do |message|
        message[:auth] = @auth_token if @auth_token && authenticated_method?(method) && api_major_version < 7
      end
    end

    def parse_response(body, request_id)
      response = JSON.parse(body)
      unless response.is_a?(Hash) && response["jsonrpc"] == "2.0" && response["id"] == request_id
        raise ProtocolError, "Invalid JSON-RPC response envelope or request ID"
      end
      unless response.key?("result") ^ response.key?("error")
        raise ProtocolError, "Invalid JSON-RPC response: expected exactly one result or error"
      end

      raise_api_error(response) if response.key?("error")
      response.fetch("result")
    rescue JSON::ParserError, TypeError
      raise ProtocolError, "Invalid JSON response", cause: nil
    end

    def raise_api_error(response)
      error = response["error"]
      unless error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
        raise ProtocolError, "Invalid JSON-RPC error response"
      end

      # 服务器文本可能回显任意请求值，包括宏及秘密。
      safe_response = response.slice("jsonrpc", "id").merge("error" => error.slice("code"))
      raise ApiError.new("Zabbix API error #{error.fetch("code")}", safe_response)
    end

    def login
      parameter = api_major_version >= 6 ? :username : :user
      api_request(method: "user.login", params: { parameter => @settings[:username], password: @settings[:password] })
    end

    def validate_api_version!
      match = @api_version.is_a?(String) && @api_version.match(/\A(\d+)\.(\d+)\.(\d+)\z/)
      raise ProtocolError, "Invalid API version response" unless match
      return if SUPPORTED_MAJOR_VERSIONS.cover?(match[1].to_i)
      raise ApiError, "Zabbix API version is not supported" unless @settings[:ignore_version]

      log(:warn, "version.unsupported", version: @api_version)
    end

    def validate_http_auth_compatibility!
      return unless api_major_version >= 7 && @settings[:http_user]

      raise Invalid, "HTTP Basic authentication cannot be combined with Zabbix 7 Bearer authentication"
    end

    def validate_token_transport!
      return unless insecure_token_transport? && @settings[:allow_insecure_http] != true

      raise Invalid, "api_token requires HTTPS unless allow_insecure_http is true"
    end

    def insecure_token_transport?
      @settings[:api_token] && @transport.uri.scheme == "http"
    end

    def insecure_https?
      @transport.uri.scheme == "https" && @settings[:verify_ssl] != true
    end

    def api_major_version
      @api_version.to_s.split(".", 2).first.to_i
    end

    def bearer_token_for(method)
      @auth_token if authenticated_method?(method) && api_major_version >= 7
    end

    def authenticated_method?(method)
      !UNAUTHENTICATED_METHODS.include?(method)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round(2) if started_at
    end
  end
end
