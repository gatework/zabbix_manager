# frozen_string_literal: true

class ZabbixManager
  class Monitoring
    # Generate the API version's trigger syntax from validated host, key and numeric inputs.
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
