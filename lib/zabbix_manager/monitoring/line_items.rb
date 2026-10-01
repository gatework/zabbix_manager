# frozen_string_literal: true

class ZabbixManager
  class Monitoring
    # 解析端点的数值监控项，并复用主机已有的共享 ICMP 检查。
    # 不重命名、启用、删除或接管已有 ICMP 监控项。
    # @api private
    class LineItems
      PATTERNS = {
        speed: /net\.if\.speed|ifhighspeed|interface speed|接口速率|1\.3\.6\.1\.2\.1\.31\.1\.1\.1\.15\./i,
        status: /net\.if\.(?:status|oper)|ifoperstatus|operational status|接口状态|1\.3\.6\.1\.2\.1\.2\.2\.1\.8\./i
      }.freeze

      def initialize(items)
        @items = items
      end

      # 两个流量方向必须唯一、不同且属于目标主机；附加指标只在选择器启用时解析。
      # @return [Hash{Symbol => Hash}] 流量及可选状态/速率监控项
      # @raise [Invalid, Conflict, ProtocolError] 量纲、身份、归属或响应结构无法确认
      def resolve(line, candidates, hostid:)
        unless candidates.is_a?(Array) && candidates.all? { |item| item.is_a?(Hash) }
          raise ProtocolError, "item.get must return an array of item objects"
        end

        selected = TrafficItems.new(candidates).for_interface(line.interface_name)
        %i[status speed].each do |kind|
          selector = line.public_send(kind)
          next unless selector

          matches = candidates.select do |item|
            if selector.is_a?(Hash)
              item["itemid"].to_s == selector[:itemid].to_s
            else
              TrafficItems.interface_matches?(item, line.interface_name) &&
                [item["key_"], item["name"], item["snmp_oid"]].join(" ").match?(PATTERNS.fetch(kind))
            end
          end
          raise Conflict,
                "expected one #{kind} item for #{line.interface_name}, found #{matches.length}" unless matches.one?

          selected[kind] = matches.first.deep_symbolize_keys
        end
        selected.each do |kind, item|
          validate_numeric!(item, kind)
          raise ProtocolError, "#{kind} item belongs to another host" unless item[:hostid].to_s == hostid.to_s
        end
        unless selected.values.map { |item| item[:itemid].to_s }.uniq.length == selected.length
          raise Conflict, "line metrics must refer to distinct items"
        end

        selected
      end

      # 查询稳定 ICMP key 并生成候选属性；缺失对象在执行阶段才创建。
      # @return [Hash] attributes 及已有 itemid（不存在时为 nil）
      def icmp_plan(hostid, target)
        attributes = {
          hostid: hostid, name: "ICMP #{target}", key_: "icmpping[#{target}]", type: 3,
          value_type: 3, delay: "1m", history: "30d", trends: "365d", status: 0
        }
        current = find_icmp(attributes)
        { attributes: attributes, itemid: current&.fetch(:itemid) }
      end

      # 在调用方工作流互斥锁内再次查询，不覆盖已有共享监控项。
      def ensure_icmp(plan)
        current = find_icmp(plan.fetch(:attributes))
        return current.fetch(:itemid).to_i if current

        @items.create(plan.fetch(:attributes))
      end

      private

      def find_icmp(attributes)
        matches = @items.for_host(attributes[:hostid], keys: attributes[:key_])
        unless matches.is_a?(Array) && matches.all? { |item| item.is_a?(Hash) }
          raise ProtocolError, "item.get must return an array of item objects"
        end
        raise Conflict, "multiple items use ICMP key #{attributes[:key_]}" if matches.length > 1
        return if matches.empty?

        item = matches.first.deep_symbolize_keys
        unless item[:hostid].to_s == attributes[:hostid].to_s && item[:key_] == attributes[:key_]
          raise ProtocolError, "item.get returned an ICMP item outside the requested host and key"
        end

        validate_numeric!(item, :reachability)
        unless item[:type].to_s == "3" && item[:value_type].to_s == "3"
          raise Conflict, "existing ICMP item must be an unsigned simple check"
        end

        item
      end

      def validate_numeric!(item, kind)
        Validation.positive_id!(item[:itemid], "#{kind} itemid")
        Validation.item_key!(item[:key_])
        unless %w[0 3].include?(item[:value_type].to_s)
          raise Invalid, "#{kind} item must have a numeric value_type"
        end
        raise Conflict, "#{kind} item must be enabled" unless item[:status].to_s == "0"
        return unless kind == :status && item[:value_type].to_s != "3"

        raise Invalid, "status item must use unsigned integer values with 1 meaning up"
      end
    end
  end
end
