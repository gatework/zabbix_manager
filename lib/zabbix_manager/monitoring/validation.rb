# frozen_string_literal: true

require "bigdecimal"

class ZabbixManager
  class Monitoring
    # 监控输入的形状、数值和表达式边界；不做静默类型强制转换。
    # 校验容器不代表授权；数值允许可解析的十进制字符串，ID 不接受浮点或布尔值。
    # @api private
    module Validation
      ITEM_KEY = /\A[A-Za-z0-9_.-]+(?:\[(?:[A-Za-z0-9_.:,\/\- {}\#$]|"(?:[^"\\\r\n]|\\.)*")*\])?\z/
      HOST_NAME = /\A[A-Za-z0-9 ._-]+\z/

      module_function

      def hash!(value, name)
        raise Invalid, "#{name} must be a hash" unless value.is_a?(Hash)

        value.deep_symbolize_keys
      end

      def array!(value, name)
        raise Invalid, "#{name} must be an array" unless value.is_a?(Array)

        value
      end

      # 字符串 "false" 不能作为真值启用提前终止等控制分支。
      def boolean!(value, name)
        raise Invalid, "#{name} must be true or false" unless value == true || value == false

        value
      end

      def text!(value, name)
        raise Invalid, "#{name} must be a non-empty string" unless value.is_a?(String) && value.present?

        value
      end

      def positive_id!(value, name)
        unless value.to_s.match?(/\A[1-9]\d*\z/) && (value.is_a?(Integer) || value.is_a?(String))
          raise Invalid, "#{name} must be a positive integer"
        end

        value
      end

      def host!(host)
        positive_id!(host[:hostid], "host.hostid")
        text!(host[:host], "host.host")
        raise Invalid, "host.host contains unsupported characters" unless HOST_NAME.match?(host[:host])
      end

      def item_key!(key)
        text!(key, "item key_")
        raise Invalid, "item key_ contains unsupported expression characters" unless ITEM_KEY.match?(key)

        key
      end

      def number!(value, name)
        number = BigDecimal(value.to_s)
        raise Invalid, "#{name} must be finite" unless number.finite?

        number
      rescue ArgumentError, TypeError
        raise Invalid, "#{name} must be a finite number"
      end

      def window!(window)
        unless window.is_a?(String) && window.match?(/\A[1-9]\d*[smhdw]\z/)
          raise Invalid, "window must use a positive Zabbix duration such as 5m or 1h"
        end

        window
      end

      def priority!(priority)
        unless (priority.is_a?(Integer) || priority.is_a?(String)) && priority.to_s.match?(/\A[0-5]\z/)
          raise Invalid, "priority must be an integer between 0 and 5"
        end

        priority.to_i
      end

      def format_number(number)
        number.to_i == number ? number.to_i.to_s : number.to_s("F")
      end
    end
  end
end
