# frozen_string_literal: true

class ZabbixManager
  class Monitoring
    # Native trigger ownership, retirement and problem reads for one line endpoint.
    # No persistent state is required; confirmed tags and IDs define the managed scope.
    # @api private
    class LineLifecycle
      KINDS = %i[interface_status bandwidth low_traffic reachability].freeze

      def initialize(manager, hostid, line_id)
        Validation.positive_id!(hostid, "hostid")
        unless line_id.is_a?(String) || line_id.is_a?(Integer)
          raise Invalid, "line_id must be a string or integer"
        end

        @line_id = Validation.text!(line_id.to_s, "line_id")
        @prefix = "interface:#{@line_id}:"
        @keys = KINDS.map { |kind| "#{@prefix}#{kind}" }
        if @keys.any? { |key| key.length > Triggers::MAX_MANAGED_KEY_LENGTH }
          raise Invalid, "managed_key is too long"
        end

        @manager, @hostid = manager, hostid
      end

      def inventory
        records = @manager.client.api_request(
          method: "trigger.get",
          params: {
            hostids: @hostid, tags: [{ tag: "zabbix_manager_id", value: @prefix, operator: 0 }],
            output: "extend", selectTags: "extend", selectItems: ["itemid", "name"], expandExpression: true
          }
        )
        unless records.is_a?(Array) && records.all? { |record| record.is_a?(Hash) }
          raise ProtocolError, "trigger.get must return an array of trigger objects"
        end

        records.each do |record|
          tags = record["tags"]
          valid_tags = tags.is_a?(Array) && tags.all? do |tag|
            tag.is_a?(Hash) && tag["tag"].is_a?(String) && tag["value"].is_a?(String)
          end
          raise ProtocolError, "trigger.get must include valid tags for ownership verification" unless valid_tags
        end
        selected = records.select { |record| managed_key(record) }
        selected.each { |record| validate_receipt!(record) }
        ids = selected.map { |record| record["triggerid"].to_s }
        raise ProtocolError, "trigger.get returned duplicate trigger IDs" unless ids.uniq == ids

        identities = selected.map { |record| managed_key(record) }
        raise Conflict, "multiple triggers use the same line managed key" unless identities.uniq == identities

        selected
      end

      def owned(records = inventory)
        records.select do |record|
          owner = tag_values(record, "managed_by")
          ids = tag_values(record, "line_id")
          owner == ["zabbix_manager"] && (ids.empty? || ids == [@line_id])
        end
      end

      def validate_ownership!(records, desired_keys)
        foreign = records - owned(records)
        if foreign.any? { |record| desired_keys.include?(managed_key(record)) }
          raise Conflict, "line managed key belongs to another owner"
        end
      end

      def disable(records = owned)
        return [] if records.empty?

        @manager.triggers.set_status(hostid: @hostid, triggerids: records.map { |record| record.fetch("triggerid") },
                                     enabled: false)
      end

      def retire(records, desired_keys)
        disable(owned(records).reject { |record| desired_keys.include?(managed_key(record)) })
      end

      def problems(time_from:, time_till:, limit:)
        from = timestamp(time_from, "time_from")
        till = timestamp(time_till, "time_till")
        raise Invalid, "time_from must not be after time_till" if from > till
        unless limit.is_a?(Integer) && limit.between?(1, 1000)
          raise Invalid, "limit must be an integer between 1 and 1000"
        end

        ids = owned.map { |record| record.fetch("triggerid").to_s }
        records = if ids.empty?
                    []
                  else
                    @manager.client.api_request(
                      method: "problem.get",
                      params: {
                        hostids: @hostid, objectids: ids, source: 0, object: 0, recent: true,
                        time_from: from, time_till: till, output: "extend", selectTags: "extend",
                        sortfield: "eventid", sortorder: "DESC", limit: limit + 1
                      }
                    )
                  end
        unless records.is_a?(Array) && records.all? { |record| record.is_a?(Hash) }
          raise ProtocolError, "problem.get must return an array of problem objects"
        end
        unless records.all? { |record| ids.include?(record["objectid"].to_s) }
          raise ProtocolError, "problem.get returned a trigger outside the requested line"
        end
        raise ProtocolError, "problem.get exceeded the requested limit" if records.length > limit + 1

        validate_problems!(records, from, till)

        { problems: records.first(limit), truncated: records.length > limit, time_from: from, time_till: till,
          limit: limit }
      end

      private

      def tag_values(record, name)
        Array(record["tags"]).filter_map do |tag|
          tag["value"] if tag.is_a?(Hash) && tag["tag"] == name
        end.uniq
      end

      def managed_key(record)
        values = tag_values(record, "zabbix_manager_id")
        matches = values & @keys
        raise Conflict, "trigger has multiple line managed keys" if matches.any? && values.length > 1

        matches.first
      end

      def validate_receipt!(record)
        Validation.positive_id!(record["triggerid"], "triggerid")
      rescue Invalid => error
        raise ProtocolError, error.message
      end

      def timestamp(value, name)
        value = value.to_i if value.is_a?(Time)
        raise Invalid, "#{name} must be a non-negative Integer or Time" unless value.is_a?(Integer) && value >= 0

        value
      end

      def validate_problems!(records, from, till)
        records.each do |record|
          Validation.positive_id!(record["eventid"], "eventid")
          clock = record["clock"]
          unless (clock.is_a?(Integer) || clock.is_a?(String)) && clock.to_s.match?(/\A\d+\z/) &&
                 clock.to_i.between?(from, till)
            raise ProtocolError, "problem.get returned an invalid or out-of-range clock"
          end
        end
        ids = records.map { |record| record["eventid"].to_s }
        raise ProtocolError, "problem.get returned duplicate event IDs" unless ids.uniq == ids
      rescue Invalid => error
        raise ProtocolError, error.message
      end
    end
  end
end
