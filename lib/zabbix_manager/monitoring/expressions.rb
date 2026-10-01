# frozen_string_literal: true

class ZabbixManager
  class Monitoring
    # 根据 API 版本，将已校验的主机、监控项键和数值转换为触发器表达式。
    # @api private
    class Expressions
      attr_reader :version

      def initialize(client, host)
        version = client.api_version.to_s
        unless version.match?(/\A\d+\.\d+(?:\.\d+)?\z/)
          raise Invalid, "Zabbix API version must be a numeric release version"
        end

        @host = host
        @version = Gem::Version.new(version)
        @modern = @version >= Gem::Version.new("5.4")
      end

      # 只接受上层已校验的函数、运算符、窗口和主机；这里再次校验嵌入表达式的 item key。
      # last 不带窗口；其他函数按 5.4 前后语法生成，数值不使用科学计数法。
      # @return [String] 一个可组合的比较表达式
      def compare(key, function, window, operator, value)
        Validation.item_key!(key)
        call = if @modern
                 source = "/#{@host}/#{key}"
                 function == "last" ? "last(#{source})" : "#{function}(#{source},#{window})"
               else
                 "{#{@host}:#{key}.#{function}(#{function == 'last' ? '' : window})}"
               end
        "#{call}#{operator}#{Validation.format_number(value)}"
      end
    end
  end
end
