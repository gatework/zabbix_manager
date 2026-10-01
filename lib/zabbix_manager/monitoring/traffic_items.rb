# frozen_string_literal: true

class ZabbixManager
  class Monitoring
    # 精确匹配已发现接口，并证明流量项的方向与 bit/s 语义。
    class TrafficItems
      OCTET_OID = /\A\.?1\.3\.6\.1\.2\.1\.31\.1\.1\.1\.(6|10)(?:\.\d+)*\z/
      INTERFACE_TOKEN = /(?<![A-Za-z0-9\/._-])(?:[A-Za-z][A-Za-z_-]*)?\d+(?:[\/.:]\d+)*(?![A-Za-z0-9\/._-]|:\d)/

      def self.interface_identity(value)
        value.downcase.gsub(/\s+|[-_]/, "")
             .sub(/\Atengigabitethernet/, "te")
             .sub(/\Agigabitethernet/, "gi")
             .sub(/\Aethernet/, "eth")
      end

      def self.counter_direction(value)
        oid = value.to_s
        oid = oid.delete_prefix("get[").delete_suffix("]") if oid.start_with?("get[") && oid.end_with?("]")
        match = OCTET_OID.match(oid)
        return unless match

        match[1] == "6" ? :inbound : :outbound
      end

      # Match a complete interface token, including subinterfaces and common vendor aliases.
      # @api private
      def self.interface_matches?(item, interface_name)
        identity = interface_identity(interface_name)
        [item["name"], item["key_"], item["snmp_oid"]].compact.any? do |field|
          field.to_s.scan(INTERFACE_TOKEN).any? { |token| interface_identity(token) == identity }
        end
      end

      def initialize(items)
        @items = items
      end

      def for_interface(interface_name)
        identity = self.class.interface_identity(interface_name)
        candidates = @items.select do |item|
          traffic_item?(item) && interface_item?(item, identity)
        end
        selected = %i[inbound outbound].to_h do |direction|
          matches = candidates.select { |item| direction_item?(item, direction) }
          unless matches.one?
            raise Conflict, "expected one #{direction} traffic item for #{interface_name}, found #{matches.length}"
          end

          item = matches.first.deep_symbolize_keys
          Validation.positive_id!(item[:itemid], "traffic itemid")
          Validation.item_key!(item[:key_])
          self.class.validate_bps!(item)
          [direction, item]
        end
        if selected[:inbound][:itemid].to_s == selected[:outbound][:itemid].to_s
          raise Conflict, "inbound and outbound traffic items must have distinct itemids"
        end

        selected
      end

      def self.validate_bps!(item)
        unless item[:units] == "bps"
          raise Invalid, "traffic item #{item[:itemid] || item[:key_]} must use bps units"
        end
        return unless raw_counter?(item)

        steps = Validation.array!(item.fetch(:preprocessing, []), "traffic preprocessing")
                          .map { |step| Validation.hash!(step, "traffic preprocessing step") }
        if steps.first&.dig(:type).to_s == "28"
          oid, format = steps.first[:params].to_s.split("\n")
          steps = steps.drop(1) if counter_direction(oid) && format == "0"
        end
        change_per_second = steps.count { |step| step[:type].to_s == "10" } == 1
        multipliers = steps.select { |step| step[:type].to_s == "1" }
        bits_multiplier = multipliers.one? && Validation.number!(multipliers.first[:params], "multiplier") == 8
        return if change_per_second && bits_multiplier && steps.length == 2

        raise Invalid,
              "raw octet item #{item[:itemid] || item[:key_]} requires change-per-second and multiplier 8 preprocessing"
      end

      def self.raw_counter?(item)
        counter_direction(item[:snmp_oid]) || item[:key_].match?(/ifhc(in|out)octets/i) ||
          (%w[0 7].include?(item[:type].to_s) && item[:key_].match?(/\Anet\.if\.(in|out)\[/))
      end
      private_class_method :raw_counter?

      private

      def interface_item?(item, identity)
        self.class.interface_matches?(item, identity)
      end

      def traffic_item?(item)
        blob = [item["key_"], item["name"]].join(" ").downcase
        return false if blob.match?(/error|discard|drop|packet|status|utilization|percentage|percent/)

        self.class.counter_direction(item["snmp_oid"]) ||
          blob.match?(/net\.if\.(in|out)(?:\[|\b)|ifhc(in|out)octets|inbound|outbound/)
      end

      def direction_item?(item, direction)
        counter = self.class.counter_direction(item["snmp_oid"])
        return counter == direction if counter

        blob = [item["key_"], item["name"]].join(" ").downcase
        inbound = blob.match?(/net\.if\.in\b|ifhcin|inbound/)
        outbound = blob.match?(/net\.if\.out\b|ifhcout|outbound/)
        direction == :inbound ? inbound && !outbound : outbound && !inbound
      end
    end
  end
end
