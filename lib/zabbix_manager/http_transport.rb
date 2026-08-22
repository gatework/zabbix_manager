# frozen_string_literal: true

require "net/http"
require "openssl"
require "socket"
require "timeout"
require "uri"

class ZabbixManager
  class HttpTransport
    DEFAULT_TIMEOUT = 60
    DEFAULT_KEEP_ALIVE_TIMEOUT = 30
    NETWORK_ERRORS = [
      Timeout::Error, EOFError, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
      Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    ].freeze

    attr_reader :uri

    # 解析连接、超时和代理配置，并准备持久会话。
    def initialize(options)
      @options = options
      @uri = parse_uri(options.fetch(:url))
      @timeout = positive_number(options.fetch(:timeout, DEFAULT_TIMEOUT), :timeout)
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
    def request(body, bearer_token: nil)
      @mutex.synchronize do
        response = active_http.request(build_request(body, bearer_token))
        unless response.is_a?(Net::HTTPSuccess)
          raise TransportError, "HTTP Error: #{response.code} on #{safe_url}"
        end

        response.body
      rescue TransportError
        disconnect
        raise
      rescue *NETWORK_ERRORS => e
        disconnect
        raise TransportError, "#{e.class}: request failed for #{safe_url}"
      rescue StandardError
        disconnect
        raise
      end
    end

    # 显式关闭当前持久连接。
    def close
      @mutex.synchronize { disconnect }
      true
    end

    # 返回不包含 URL 凭据和查询串的安全地址。
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

      # 校验并解析 HTTP 或 HTTPS API 地址。
      def parse_uri(value)
        uri = URI.parse(value.to_s)
        unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty?
          raise Invalid, "url must be an absolute HTTP or HTTPS URL"
        end

        uri
      rescue URI::InvalidURIError
        raise Invalid, "url must be an absolute HTTP or HTTPS URL"
      end

      # 把超时配置转换为正数。
      def positive_number(value, name)
        number = Float(value)
        raise Invalid unless number.positive?

        number
      rescue ArgumentError, TypeError
        raise Invalid, "#{name} must be greater than zero"
      end

      # 按显式配置和环境变量顺序解析代理。
      def proxy_uri(options)
        return if options[:no_proxy]

        value = options[:proxy] || environment_proxy
        return if value.nil? || value.empty?

        uri = URI.parse(value)
        unless %w[http https].include?(uri.scheme) && uri.host.present?
          raise Invalid, "proxy must be an absolute HTTP or HTTPS URL"
        end

        uri
      rescue URI::InvalidURIError
        raise Invalid, "proxy must be a valid URL"
      end

      # 根据目标协议选择对应的环境代理。
      def environment_proxy
        return ENV["http_proxy"] || ENV["HTTP_PROXY"] unless @uri.scheme == "https"

        ENV["https_proxy"] || ENV["HTTPS_PROXY"] || ENV["http_proxy"] || ENV["HTTP_PROXY"]
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
        http = @proxy_uri ? build_proxy_http : Net::HTTP.new(@uri.host, @uri.port)

        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @write_timeout if http.respond_to?(:write_timeout=)
        http.keep_alive_timeout = @keep_alive_timeout if http.respond_to?(:keep_alive_timeout=)
        configure_tls(http)
        http
      end

      # 创建使用显式代理的 Net::HTTP 实例。
      def build_proxy_http
        Net::HTTP::Proxy(
          @proxy_uri.host,
          @proxy_uri.port,
          @proxy_uri.user,
          @proxy_uri.password
        ).new(@uri.host, @uri.port)
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
        @http.finish if @http&.started?
      rescue IOError, SystemCallError
        nil
      ensure
        @http = nil
        @pid = nil
      end
  end
end
