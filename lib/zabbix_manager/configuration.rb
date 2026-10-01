# frozen_string_literal: true

class ZabbixManager
  # 在首次网络访问之前统一校验连接配置。
  class Configuration
    ENVIRONMENT_KEYS = {
      url: "ZABBIX_URL", api_token: "ZABBIX_API_TOKEN",
      username: "ZABBIX_USERNAME", password: "ZABBIX_PASSWORD"
    }.freeze
    CREDENTIALS = %i[api_token username password http_user http_password].freeze
    BOOLEAN_OPTIONS = %i[verify_ssl allow_insecure_http no_proxy ignore_version].freeze
    OPTIONS = (CREDENTIALS + BOOLEAN_OPTIONS + %i[
      url proxy ca_file timeout request_timeout max_response_bytes
      open_timeout read_timeout write_timeout keep_alive_timeout
      logger log_level upsert_lock uncertain_write_delays
    ]).freeze
    DEFAULT_UNCERTAIN_WRITE_DELAYS = [0, 0.25, 1, 2].freeze

    # 仅从指定环境映射读取连接身份字段。
    # 显式选项优先于环境值，包含用于清除凭据的 nil。
    def self.from_env(env, overrides)
      ENVIRONMENT_KEYS.to_h { |key, name| [key, env[name]] }.merge(overrides)
    end

    # 返回已校验的配置，不修改调用方持有的值。
    def self.parse(options)
      new(options).to_h
    end

    def initialize(options)
      raise Invalid, "options must be a Hash" unless options.is_a?(Hash)

      @options = options.symbolize_keys
      @options.assert_valid_keys(*OPTIONS)
      @options.transform_values! { |value| value.is_a?(String) ? value.dup.freeze : value }
      validate_credentials!
      validate_booleans!
      validate_delays!
      validate_collaborators!
    rescue ArgumentError => error
      raise Invalid, error.message, cause: nil
    end

    def to_h
      @options.freeze
    end

    def inspect
      "#<#{self.class}>"
    end

    private

    def validate_credentials!
      CREDENTIALS.each do |key|
        value = @options[key]
        raise Invalid, "#{key} must be a String" unless value.nil? || value.is_a?(String)

        @options.delete(key) if value.blank?
      end
      raise Invalid, "url is required" if @options[:url].blank?

      token = @options[:api_token]
      username = @options[:username]
      password = @options[:password]
      if token && (username || password)
        raise Invalid, "api_token cannot be combined with username/password"
      end
      raise Invalid, "provide api_token or both username and password" unless token || (username && password)
      return unless @options[:http_password] && !@options[:http_user]

      raise Invalid, "http_password requires http_user"
    end

    def validate_booleans!
      BOOLEAN_OPTIONS.each do |key|
        next unless @options.key?(key)
        next if [true, false].include?(@options[key])

        raise Invalid, "#{key} must be true or false"
      end
    end

    def validate_delays!
      values = @options.fetch(:uncertain_write_delays, DEFAULT_UNCERTAIN_WRITE_DELAYS)
      raise Invalid, "uncertain_write_delays must be an Array" unless values.is_a?(Array)

      delays = values.map { |value| Float(value, exception: false) }
      finite_nonnegative = delays.all? { |value| value && value.finite? && value >= 0 }
      unless (1..10).cover?(delays.size) && finite_nonnegative && delays.sum <= 60
        raise Invalid, "uncertain_write_delays must contain 1 to 10 non-negative seconds totaling at most 60"
      end

      @options[:uncertain_write_delays] = delays.freeze
    end

    def validate_collaborators!
      lock = @options[:upsert_lock]
      raise Invalid, "upsert_lock must respond to call(key, &block)" if lock && !lock.respond_to?(:call)

      logger = @options[:logger]
      return if logger.nil? || %i[debug info warn formatter formatter=].all? { |method| logger.respond_to?(method) }

      raise Invalid, "logger must support the Ruby Logger interface"
    end
  end
end
