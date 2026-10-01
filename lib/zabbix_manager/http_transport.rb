# frozen_string_literal: true

require "net/http"
require "openssl"
require "socket"
require "timeout"
require "uri"

class ZabbixManager
  # 持有串行复用的 Net::HTTP 会话，负责代理、TLS、连接关闭及网络错误转换。
  # 超时配置作用于连接、读取和写入阶段；传输失败不重放请求。
  class HttpTransport
    DEFAULT_TIMEOUT = 60
    DEFAULT_KEEP_ALIVE_TIMEOUT = 30
    DEFAULT_MAX_RESPONSE_BYTES = 64 * 1024 * 1024
    # 仅用于中止单次网络操作，不包裹业务编排或应用层事务。
    class RequestDeadline < Timeout::Error; end
    private_constant :RequestDeadline
    NETWORK_ERRORS = [
      Timeout::Error, EOFError, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
      Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    ].freeze

    attr_reader :uri

    # 解析连接、超时和代理配置，并准备持久会话。
    # @param options [Hash] URL、超时、TLS 和代理设置；不会在初始化时连接
    # @raise [Invalid] URL、超时或布尔选项无效
    def initialize(options)
      @options = options.dup.freeze
      validate_boolean_options!
      @uri = parse_uri(options.fetch(:url))
      @timeout = positive_number(options.fetch(:timeout, DEFAULT_TIMEOUT), :timeout)
      @request_timeout = positive_number(options.fetch(:request_timeout, @timeout), :request_timeout)
      @max_response_bytes = options.fetch(:max_response_bytes, DEFAULT_MAX_RESPONSE_BYTES)
      unless @max_response_bytes.is_a?(Integer) && @max_response_bytes.positive?
        raise Invalid, "max_response_bytes must be a positive integer"
      end

      @open_timeout = positive_number(options.fetch(:open_timeout, @timeout), :open_timeout)
      @read_timeout = positive_number(options.fetch(:read_timeout, @timeout), :read_timeout)
      @write_timeout = positive_number(options.fetch(:write_timeout, @timeout), :write_timeout)
      @keep_alive_timeout = positive_number(
        options.fetch(:keep_alive_timeout, DEFAULT_KEEP_ALIVE_TIMEOUT), :keep_alive_timeout
      )
      @proxy_uri = proxy_uri(options)
      @mutex = Mutex.new
      @http = nil
      @pid = nil
    end

    # 串行发送请求，失败时关闭连接但不自动重放写操作。
    # @param body [String] 已序列化的 JSON-RPC 请求
    # @param bearer_token [String, nil] 当前请求的 API 认证凭据
    # @return [String] HTTP 成功响应正文，由 Client 验证 JSON-RPC 协议
    # @raise [TransportError] HTTP 状态失败、连接中断或超时；写入可能已生效
    def request(body, bearer_token: nil)
      request = build_request(body, bearer_token)
      @mutex.synchronize do
        # Net::HTTP 原生阶段超时仍生效；额外期限只覆盖连接、发送及读取，不重放 POST。
        Timeout.timeout(@request_timeout, RequestDeadline) { read_response(request) }
      rescue TransportError
        disconnect
        raise
      rescue *NETWORK_ERRORS => e
        disconnect
        raise TransportError, "#{e.class}: request failed for #{safe_url}", cause: nil
      rescue StandardError
        disconnect
        raise
      end
    end

    # 显式关闭当前持久连接。
    # @return [true] 重复关闭也成功，下一次请求按需重新连接
    def close
      @mutex.synchronize { disconnect }
      true
    end

    # 返回不包含 URL 凭据和查询串的安全地址。
    # @return [String]
    def safe_url
      port = @uri.port == @uri.default_port ? nil : ":#{@uri.port}"
      "#{@uri.scheme}://#{@uri.host}#{port}#{@uri.path}"
    end

    # 返回不包含代理凭据和请求配置的传输层摘要
    # @return [String]
    # @api private
    def inspect
      "#<#{self.class} url=#{safe_url.inspect} persistent=true>"
    end

    private

    # 流式累计解压后的响应字节，避免在检查上限之前缓冲整个正文。
    def read_response(request)
      body = +""
      active_http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          raise TransportError, "HTTP Error: #{response.code} on #{safe_url}"
        end

        response.read_body do |chunk|
          if body.bytesize + chunk.bytesize > @max_response_bytes
            raise TransportError, "HTTP response exceeds max_response_bytes on #{safe_url}"
          end

          body << chunk
        end
      end
      body
    end

    # 校验并解析 HTTP 或 HTTPS API 地址。
    def parse_uri(value)
      uri = URI.parse(value)
      unless %w[http https].include?(uri.scheme) && uri.hostname && !uri.hostname.empty? &&
             (1..65_535).cover?(uri.port)
        raise Invalid, "url must be an absolute HTTP or HTTPS URL with a valid port"
      end

      uri.freeze
    rescue URI::InvalidURIError, TypeError
      raise Invalid, "url must be an absolute HTTP or HTTPS URL", cause: nil
    end

    # 防止字符串布尔值改变 TLS 校验或代理开关。
    def validate_boolean_options!
      %i[verify_ssl no_proxy].each do |name|
        next unless @options.key?(name)
        next if [true, false].include?(@options[name])

        raise Invalid, "#{name} must be true or false"
      end
    end

    # 把超时配置转换为有限正数。
    def positive_number(value, name)
      number = Float(value)
      raise ArgumentError unless number.finite? && number.positive?

      number
    rescue ArgumentError, TypeError
      raise Invalid, "#{name} must be a finite number greater than zero", cause: nil
    end

    # 复用标准库的代理发现与排除规则，并拒绝无法兑现的代理协议。
    def proxy_uri(options)
      return if options[:no_proxy]

      value = options[:proxy]
      uri = value.nil? ? URI::HTTP.build(host: @uri.hostname, port: @uri.port).find_proxy : URI.parse(value)
      return unless uri
      unless uri.is_a?(URI::HTTP) && uri.scheme == "http" && uri.hostname &&
             (1..65_535).cover?(uri.port) && ["", "/"].include?(uri.path) && !uri.query && !uri.fragment
        raise Invalid, "proxy must be an absolute HTTP URL without a path, query or fragment"
      end

      uri.freeze
    rescue URI::InvalidURIError, TypeError
      raise Invalid, "proxy must be an absolute HTTP URL", cause: nil
    end

    # 复用已启动连接，并在 fork 后放弃继承套接字。
    def active_http
      abandon_inherited_connection if @pid && @pid != Process.pid
      @http ||= build_http
      @http.start unless @http.started?
      @pid = Process.pid
      @http
    end

    # 子进程不能向父进程继承的 TLS 套接字发送 close_notify。
    def abandon_inherited_connection
      @http = nil
      @pid = nil
    end

    # 创建并配置 Net::HTTP 实例。
    def build_http
      http = Net::HTTP.new(@uri.hostname, @uri.port, *proxy_arguments)

      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @write_timeout
      http.keep_alive_timeout = @keep_alive_timeout
      http.max_retries = 0
      configure_tls(http)
      http
    end

    # 向 Net::HTTP 传入已解析代理，避免二次环境发现；凭据使用 URI 百分号解码。
    def proxy_arguments
      return [nil] unless @proxy_uri

      [
        @proxy_uri.hostname,
        @proxy_uri.port,
        @proxy_uri.user && URI::DEFAULT_PARSER.unescape(@proxy_uri.user),
        @proxy_uri.password && URI::DEFAULT_PARSER.unescape(@proxy_uri.password)
      ]
    end

    # 配置 HTTPS；证书校验默认关闭，按调用方选项开启。
    def configure_tls(http)
      return unless @uri.scheme == "https"

      http.use_ssl = true
      http.verify_mode = @options[:verify_ssl] == true ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      http.ca_file = @options[:ca_file] if @options[:ca_file]
    end

    # 构建 JSON-RPC POST，并在需要时写入 Bearer 或 Basic 认证。
    def build_request(body, bearer_token)
      if bearer_token && @options[:http_user]
        raise Invalid, "HTTP Basic authentication cannot be combined with Bearer authentication"
      end

      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Content-Type"] = "application/json-rpc"
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{bearer_token}" if bearer_token
      request.basic_auth(@options[:http_user], @options[:http_password]) if @options[:http_user]
      request.body = body
      request
    end

    # 安全结束连接并清理当前进程的会话状态。
    def disconnect
      @http.finish if @pid == Process.pid && @http&.started?
    rescue *NETWORK_ERRORS
      nil
    ensure
      @http = nil
      @pid = nil
    end
  end
end
