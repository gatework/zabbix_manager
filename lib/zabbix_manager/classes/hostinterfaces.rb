# frozen_string_literal: true

class ZabbixManager
  # 封装高频使用的 Zabbix 主机接口查询与幂等更新。
  class HostInterfaces < Basic
    # 返回对应的 Zabbix API 模块名。
    # @return [String]
    def method_name
      "hostinterface"
    end

    # 返回接口对象的主键字段。
    # @return [String]
    def key
      "interfaceid"
    end

    # 使用接口 ID 作为通用查询标识。
    # @return [String]
    def identify
      "interfaceid"
    end

    # 查询指定主机的全部接口，可选择同时返回关联监控项。
    # @return [Array<Hash>]
    def for_host(hostid, select_items: nil)
      raise Invalid, "hostid is required" if hostid.blank?

      params = { hostids: hostid, output: "extend" }
      params[:selectItems] = select_items if select_items
      @client.api_request(method: "hostinterface.get", params: params)
    end

    # 规范化并校验接口定义，不执行远端查询或写入。
    # @return [Array<Hash>]
    def validate(interfaces)
      desired = Array.wrap(interfaces).map { |interface| normalize_definition(interface) }
      validate_definitions!(desired)
      desired
    end

    # 校验 host.create 中全部接口的创建必填合同。
    # @return [Array<Hash>]
    def validate_for_create(interfaces)
      validate(interfaces).each { |attributes| validate_create_definition!(attributes) }
    end

    # 幂等创建或更新一个主机的接口集合。
    # @return [Array<Integer>]
    def reconcile_for_host(hostid:, interfaces:)
      @client.with_upsert_lock("host-interfaces:#{hostid}") do
        plan = plan_for_host(hostid: hostid, interfaces: interfaces)
        apply_plan(hostid: hostid, plan: plan)
      end
    end

    # 删除明确指定的主机接口；关联监控项由 Zabbix 按官方规则处理。
    # @return [Array<Integer>]
    def delete_many(hostid:, interfaceids:)
      ids = Array(interfaceids).filter_map { |value| value.to_s.strip.presence }.uniq
      raise Invalid, "interfaceids are required" if ids.empty?

      owned_ids = for_host(hostid).map { |interface| interface.fetch("interfaceid").to_s }
      foreign_ids = ids - owned_ids
      raise Conflict, "interfaces do not belong to host #{hostid}: #{foreign_ids.join(", ")}" if foreign_ids.any?

      result = @client.api_request(method: "hostinterface.delete", params: ids)
      Array(result.fetch("interfaceids")).map(&:to_i)
    end

    private

      # 预先校验并生成仅供当前对象执行的接口变更计划。
      def plan_for_host(hostid:, interfaces:)
        desired = validate(interfaces)
        existing = for_host(hostid)
        desired.map { |attributes| [attributes, matching_interface(existing, attributes)] }
      end

      # 执行内部生成的接口变更计划，避免调用方伪造跨主机接口 ID。
      def apply_plan(hostid:, plan:)
        plan.map do |attributes, current|
          current ? update_interface(attributes, current) : create_interface(hostid, attributes)
        end
      end

      # 把接口字段递归转换为统一符号键。
      def normalize_definition(interface)
        interface.deep_symbolize_keys
      end

      # 校验新接口的通用字段及 SNMP 条件字段。
      def validate_create_definition!(attributes)
        attributes[:ip] = "" unless attributes.key?(:ip)
        attributes[:dns] = "" unless attributes.key?(:dns)
        interface_identity(attributes)
        validate_snmp_details!(attributes) if attributes[:type].to_i == 2
      end

      # 校验 SNMP 版本和 v1/v2c community 必填合同。
      def validate_snmp_details!(attributes)
        details = attributes[:details]&.deep_symbolize_keys
        raise Invalid, "SNMP interface details are required" unless details

        version = Integer(details[:version])
        raise Invalid, "SNMP interface version must be 1, 2, or 3" unless [1, 2, 3].include?(version)
        if [1, 2].include?(version) && details[:community].blank?
          raise Invalid, "SNMP v1/v2 interface community is required"
        end

        attributes[:details] = details
      rescue ArgumentError, TypeError
        raise Invalid, "SNMP interface version must be 1, 2, or 3"
      end

      # 校验期望接口是否包含重复身份。
      # @return [void]
      # @api private
      def validate_definitions!(interfaces)
        identities = interfaces.map { |interface| interface_identity(interface) }
        duplicate = identities.tally.find { |_identity, count| count > 1 }&.first
        raise Invalid, "duplicate desired interface identity #{duplicate}" if duplicate
      end

      # 按显式 ID 或稳定端点身份匹配已有接口。
      # @return [Hash, nil]
      # @api private
      def matching_interface(existing, attributes)
        if attributes[:interfaceid]
          match = existing.find { |item| item["interfaceid"].to_s == attributes[:interfaceid].to_s }
          raise Invalid, "interfaceid #{attributes[:interfaceid]} does not belong to this host" unless match

          return match
        end

        candidates = existing.select { |item| endpoint_identity(item) == endpoint_identity(attributes) }
        raise Conflict, "interface identity is ambiguous; provide interfaceid" if candidates.length > 1

        candidates.first
      end

      # 生成不依赖数组顺序的接口身份。
      # @return [String]
      # @api private
      def interface_identity(attributes)
        values = attributes.with_indifferent_access
        return "id:#{values[:interfaceid]}" if values[:interfaceid].present?

        endpoint_identity(values)
      end

      # 使用类型、端点和端口匹配接口，不把可变的 main 或远端 ID 作为端点身份。
      def endpoint_identity(attributes)
        values = attributes.with_indifferent_access

        %i[type main useip port].each do |field|
          raise Invalid, "interface #{field} is required" if values[field].blank?
        end
        endpoint_field = values[:useip].to_i == 1 ? :ip : :dns
        raise Invalid, "interface #{endpoint_field} is required" if values[endpoint_field].blank?

        "endpoint:#{values[:type]}:#{values[:useip]}:#{values[endpoint_field]}:#{values[:port]}"
      end

      # 更新已属于目标主机的接口。
      # @return [Integer]
      # @api private
      def update_interface(attributes, current)
        interfaceid = current.fetch("interfaceid")
        @client.api_request(
          method: "hostinterface.update",
          params: attributes.except(:hostid).merge(interfaceid: interfaceid)
        )
        interfaceid.to_i
      end

      # 为目标主机创建缺失接口。
      # @return [Integer]
      # @api private
      def create_interface(hostid, attributes)
        validate_create_definition!(attributes)
        result = @client.api_request(
          method: "hostinterface.create",
          params: attributes.except(:interfaceid).merge(hostid: hostid)
        )
        result.fetch("interfaceids").first.to_i
      end
  end
end
