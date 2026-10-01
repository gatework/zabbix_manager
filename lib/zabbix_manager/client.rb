# frozen_string_literal: true

require "json"
require "logger"
require "active_support"
require "active_support/logger"
require "active_support/tagged_logging"

class ZabbixManager
  # Owns one authenticated connection and its JSON-RPC request lifecycle.
  class Client
    SUPPORTED_MAJOR_VERSIONS = (4..7)
    UNAUTHENTICATED_METHODS = %w[apiinfo.version user.login].freeze
    UPSERT_MUTEX_STRIPES = 64

    attr_reader :options, :logger, :api_version

    # Validate settings, fetch the server version and authenticate immediately.
    # Failed initialization closes its connection; the caller owns a successful client.
    # @param options [Hash] explicit connection, credential, logger and lock settings
    # @raise [Invalid] connection settings are invalid or conflicting
    # @raise [ApiError, TransportError, ProtocolError] version lookup or authentication fails
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

    # Perform one request. A failed or unconfirmed mutation is never replayed.
    # @param method [String] native API method, such as "history.get"
    # @param params [Hash, Array] native Zabbix parameters; values are not logged
    # @return [Object] decoded JSON-RPC result, preserving the server's scalar types
    # @raise [Invalid] method name or parameter container is invalid
    # @raise [ApiError] the server explicitly rejects the request
    # @raise [TransportError, ProtocolError] no valid response confirms the result
    def api_request(method:, params: {})
      validate_request!(method, params)
      started_at = monotonic_time
      message = request_message(method, params)
      log(:debug, "request.started", method: method)
      body = @transport.request(JSON.generate(message), bearer_token: bearer_token_for(method))
      result = parse_response(body, message.fetch(:id))
      log(:info, "request.completed", method: method, duration_ms: elapsed_ms(started_at))
      result
    rescue StandardError => error
      log(:warn, "request.failed", method: method, duration_ms: elapsed_ms(started_at), error: error.class.name)
      raise
    end

    # Revoke a password session; API tokens only need local cleanup.
    # Local credentials and transport are cleared even if remote logout fails.
    # @return [Boolean] the server logout result, or true for an API token
    # @raise [ApiError, TransportError] remote session logout fails
    def logout
      @credential_type == :user_session && @auth_token ? api_request(method: "user.logout", params: []) : true
    ensure
      @auth_token = nil
      close
    end

    # Close the connection without revoking credentials; a later request reconnects.
    # @return [true]
    def close
      @transport.close
    end

    # Log metadata lazily. Logging failure must not change a remote write result.
    # @param level [Symbol] Ruby Logger severity method
    # @param event [String] stable event name
    # @param data [Hash] metadata filtered before serialization
    # @return [Object, nil] logger result, or nil when logging is disabled or fails
    def log(level, event, data = {})
      return unless @logger

      @logger.tagged("zabbix_manager") do
        @logger.public_send(level) { JSON.generate(LogSanitizer.sanitize(data.merge(event: event))) }
      end
    rescue StandardError
      nil
    end

    # @return [String] a diagnostic representation containing only sanitized options
    def inspect
      "#<#{self.class} options=#{@options.inspect}>"
    end

    # Application locks extend local serialization across worker processes.
    # Locks are not reentrant; callers must not acquire another upsert lock inside the block.
    # @param key [String] stable non-secret identity of the protected operation
    # @yield the read/modify/write operation to serialize
    # @return [Object] the block's result
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
      unless method.is_a?(String) && method.match?(/\A[a-z][a-z0-9_]*\.[a-z][a-zA-Z0-9_]*\z/)
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

      # Server text can echo arbitrary request values, including macros and secrets.
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
