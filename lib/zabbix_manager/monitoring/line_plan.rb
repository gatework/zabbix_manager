# frozen_string_literal: true

class ZabbixManager
  class Monitoring
    # 统一生成触发器属性，供预览和实际执行复用。
    # 状态触发器 ID 确认之前，依赖以指标类型名称表示。
    # @api private
    class LinePlan
      def initialize(client, line, host, items, icmp_item)
        @client, @line, @host, @items, @icmp_item = client, line, host, items, icmp_item
        @expressions = Expressions.new(client, host[:host])
        @line_id = line.resolved_id(host[:hostid])
        validate_metadata_version!
      end

      # 纯本地构造计划，不写远端；依赖保留为指标名称，执行时转换为已确认 triggerid。
      # @return [Hash] 端点身份、监控项 ID、触发器属性及依赖计划
      def to_h
        triggers = {}
        triggers[:interface_status] = status_trigger if @items[:status]
        triggers[:bandwidth] = bandwidth_trigger
        triggers[:low_traffic] = low_trigger if @line.low_traffic
        triggers[:reachability] = reachability_trigger if @icmp_item
        dependencies = triggers.keys.to_h do |kind|
          [kind, @items[:status] && kind != :interface_status ? [:interface_status] : []]
        end
        itemids = @items.transform_values { |item| item.fetch(:itemid).to_i }
        itemids[:reachability] = @icmp_item[:itemid].to_i if @icmp_item&.dig(:itemid)
        {
          hostid: @host[:hostid].to_i, host: @host[:host], interface: @line.interface_name, line_id: @line_id,
          itemids: itemids, triggers: triggers, dependencies: dependencies, icmp_item: @icmp_item
        }
      end

      private

      def validate_metadata_version!
        { opdata: "4.4", event_name: "5.2" }.each do |field, minimum|
          next unless @line.metadata.key?(field) && @expressions.version < Gem::Version.new(minimum)

          raise Invalid, "#{field} requires Zabbix #{minimum} or newer"
        end
      end

      def bandwidth_trigger
        attributes = Thresholds.new(@client).prepare_triggers(
          host: @host, interface: @line.interface(hostid: @host[:hostid]),
          items: { inbound_bps: @items[:inbound], outbound_bps: @items[:outbound] },
          thresholds: { bandwidth: @line.threshold }
        ).fetch(:bandwidth)
        attributes[:expression] = guarded(attributes[:expression])
        attributes[:recovery_expression] = guarded(attributes[:recovery_expression])
        decorate(attributes)
      end

      def low_trigger
        config = @line.low_traffic
        problem = traffic_expression(config[:window], "<", config[:below_bps], "and")
        recovery = traffic_expression(config[:recovery_window], ">=", config[:recovery_bps], "or")
        trigger(:low_traffic, guarded(problem), guarded(recovery), "low traffic")
      end

      def status_trigger
        key = @items.fetch(:status).fetch(:key_)
        trigger(:interface_status, compare(key, "last", nil, "<>", 1),
                compare(key, "last", nil, "=", 1), "interface down")
      end

      def reachability_trigger
        key = @icmp_item.fetch(:attributes).fetch(:key_)
        trigger(:reachability, compare(key, "max", "5m", "=", 0),
                compare(key, "min", "2m", "=", 1), "ICMP unreachable")
      end

      def trigger(kind, problem, recovery, label)
        key = "interface:#{@line_id}:#{kind}"
        raise Invalid, "managed_key is too long" if key.length > Triggers::MAX_MANAGED_KEY_LENGTH

        decorate(
          hostid: @host[:hostid], managed_key: key,
          description: "#{@line.interface_name} #{label}", expression: problem,
          recovery_mode: 1, recovery_expression: recovery, priority: @line.threshold[:priority], manual_close: 1,
          tags: [
            { tag: "managed_by", value: "zabbix_manager" }, { tag: "interface", value: @line.interface_name },
            { tag: "metric", value: kind.to_s }
          ] + @line.threshold[:tags]
        )
      end

      def decorate(attributes)
        attributes.merge(@line.metadata).merge(
          status: 0, tags: (attributes[:tags] + [{ tag: "line_id", value: @line_id }]).uniq
        )
      end

      def guarded(expression)
        return expression unless @items[:speed]

        "(#{expression}) and #{compare(@items[:speed][:key_], 'last', nil, '>', 0)}"
      end

      def traffic_expression(window, operator, value, joiner)
        %i[inbound outbound].map do |direction|
          compare(@items.fetch(direction).fetch(:key_), "avg", window, operator, value)
        end.join(" #{joiner} ")
      end

      def compare(...)
        @expressions.compare(...)
      end
    end
  end
end
