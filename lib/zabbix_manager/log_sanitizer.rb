# frozen_string_literal: true

require "uri"

class ZabbixManager
  module LogSanitizer
    REDACTED = "[FILTERED]"
    MAX_STRING_LENGTH = 2_000
    SENSITIVE_KEY_NAMES = "auth|authorization|api_token|community|cookie|http_password|password|passwd|" \
                          "privatekey|secret|sessionid|snmp_community|snmpv3_authpassphrase|" \
                          "snmpv3_privpassphrase|tls_psk|tls_psk_identity|token"
    SENSITIVE_KEYS = /\A(?:#{SENSITIVE_KEY_NAMES})\z/i.freeze

    module_function

    # 递归脱敏结构化对象，并限制字符串长度。
    def sanitize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), result|
          result[key] = sensitive_key?(key) ? REDACTED : sanitize(child)
        end
      when Array
        value.map { |child| sanitize(child) }
      when String
        sanitize_string(value)
      else
        value
      end
    end

    # 移除 URL 中的用户名、密码、查询串和片段。
    def sanitize_url(value)
      uri = URI.parse(value.to_s)
      uri.user = nil
      uri.password = nil
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      sanitize_string(value.to_s)
    end

    # 清理字符串中的认证头和常见敏感键值。
    def sanitize_string(value)
      sanitized = value.dup
      sanitized.gsub!(/\b(Bearer|Basic)\s+[^\s,;]+/i, "\\1 #{REDACTED}")
      sanitized.gsub!(
        /((?:authorization)["']?\s*(?:=>|:|=)\s*)[^,;}\]]+/i,
        "\\1#{REDACTED}"
      )
      sanitized.gsub!(
        /((?:#{SENSITIVE_KEY_NAMES})["']?\s*(?:=>|:|=)\s*)(["'])(.*?)\2/i,
        "\\1\\2#{REDACTED}\\2"
      )
      sanitized.gsub!(
        /((?:#{SENSITIVE_KEY_NAMES})["']?\s*(?:=>|:|=)\s*)(?!["'])[^,;}\]]+/i,
        "\\1#{REDACTED}"
      )
      sanitized.length > MAX_STRING_LENGTH ? "#{sanitized[0, MAX_STRING_LENGTH]}...[TRUNCATED]" : sanitized
    end

    # 判断字段名是否属于敏感配置。
    def sensitive_key?(key)
      key.to_s.match?(SENSITIVE_KEYS)
    end
  end
end
