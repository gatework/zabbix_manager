# frozen_string_literal: true

class ZabbixManager
  # 封装高频使用的 Zabbix 主机接口查询与幂等更新。
  class HostInterfaces < Resource
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

    # 只读取并校验接口归属和创建必填字段，供多资源编排在首个写入前预检。
    # @param hostid [Integer, String] 目标主机 ID
    # @param interfaces [Array<Hash>] 期望接口定义
    # @return [Array<Hash>] 已验证的接口属性；执行时仍需重新核实远端状态
    def validate_for_host(hostid:, interfaces:)
      plan_for_host(hostid: hostid, interfaces: interfaces).map(&:first)
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
      ids = normalized_ids(interfaceids)

      owned_ids = for_host(hostid).map { |interface| interface.fetch("interfaceid").to_s }
      foreign_ids = ids - owned_ids
      raise Conflict, "interfaces do not belong to host #{hostid}: #{foreign_ids.join(", ")}" if foreign_ids.any?

      result = @client.api_request(method: "hostinterface.delete", params: ids)
      response_ids(result, expected: ids)
    end

    private

    # 预先校验并生成仅供当前对象执行的接口变更计划。
    def plan_for_host(hostid:, interfaces:)
      desired = validate(interfaces)
      existing = for_host(hostid)
      plans = desired.map do |attributes|
        current = matching_interface(existing, attributes)
        response_identifier(current["interfaceid"]) if current
        validate_create_definition!(attributes) unless current
        [attributes, current]
      end
      targets = plans.filter_map { |_attributes, current| current && response_identifier(current["interfaceid"]) }
      raise Invalid, "duplicate resolved interface target" unless targets.uniq == targets

      plans
    end

    # 执行内部生成的接口变更计划，避免调用方伪造跨主机接口 ID。
    def apply_plan(hostid:, plan:)
      plan.map do |attributes, current|
        current ? update_interface(attributes, current) : create_interface(hostid, attributes)
      end
    end

    # 把接口字段递归转换为统一符号键。
    def normalize_definition(interface)
      raise Invalid, "interface must be a hash" unless interface.is_a?(Hash)

      attributes = interface.deep_symbolize_keys
      if attributes.key?(:type)
        type = integer_attribute(attributes[:type], "interface type")
        raise Invalid, "interface type must be 1, 2, 3, or 4" unless [1, 2, 3, 4].include?(type)
      end
      %i[main useip].each do |field|
        next unless attributes.key?(field)

        unless [0, 1].include?(integer_attribute(attributes[field], "interface #{field}"))
          raise Invalid, "interface #{field} must be 0 or 1"
        end
      end
      %i[ip dns].each do |field|
        if attributes.key?(field) && !attributes[field].is_a?(String)
          raise Invalid, "interface #{field} must be a string"
        end
      end
      validate_port!(attributes[:port]) if attributes.key?(:port)
      details = attributes[:details]
      if attributes.key?(:details) && !details.is_a?(Hash)
        raise Invalid, "interface details must be a hash"
      end

      validate_supplied_snmp_details!(details) if details
      attributes
    end

    def validate_supplied_snmp_details!(details)
      validate_snmp_version!(details[:version]) if details.key?(:version)
      %i[community securityname authpassphrase privpassphrase contextname].each do |field|
        if details.key?(field) && !details[field].is_a?(String)
          raise Invalid, "SNMP #{field} must be a string"
        end
      end
      { bulk: [0, 1], securitylevel: [0, 1, 2] }.each do |field, allowed|
        next unless details.key?(field)

        unless allowed.include?(integer_attribute(details[field], "SNMP #{field}"))
          raise Invalid, "SNMP #{field} is invalid"
        end
      end
    end

    def validate_port!(value)
      text = value.to_s
      numeric = (value.is_a?(String) || value.is_a?(Integer)) && text.match?(/\A[1-9]\d*\z/)
      macro = value.is_a?(String) && text.match?(/\A\{\$[^{}\r\n]+\}\z/)
      return if macro || (numeric && value.to_i <= 65_535)

      raise Invalid, "interface port must be between 1 and 65535 or a user macro"
    end

    # 校验新接口的通用字段及 SNMP 条件字段。
    def validate_create_definition!(attributes)
      raise Invalid, "new interfaces cannot reference an existing interfaceid" if attributes.key?(:interfaceid)

      attributes[:ip] = "" unless attributes.key?(:ip)
      attributes[:dns] = "" unless attributes.key?(:dns)
      endpoint_identity(attributes)
      validate_snmp_details!(attributes) if attributes[:type].to_i == 2
    end

    # 校验 SNMP 版本和 v1/v2c community 必填合同。
    def validate_snmp_details!(attributes)
      details = attributes[:details]&.deep_symbolize_keys
      raise Invalid, "SNMP interface details are required" unless details

      version = validate_snmp_version!(details[:version])
      if [1, 2].include?(version) && details[:community].blank?
        raise Invalid, "SNMP v1/v2 interface community is required"
      end

      attributes[:details] = details
    end

    def validate_snmp_version!(value)
      version = integer_attribute(value, "SNMP interface version")
      raise Invalid, "SNMP interface version must be 1, 2, or 3" unless [1, 2, 3].include?(version)

      version
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
      result = @client.api_request(
        method: "hostinterface.update",
        params: attributes.except(:hostid).merge(interfaceid: interfaceid)
      )
      response_id(result, expected: [interfaceid])
    end

    # 为目标主机创建缺失接口。
    # @return [Integer]
    # @api private
    def create_interface(hostid, attributes)
      result = @client.api_request(
        method: "hostinterface.create",
        params: attributes.except(:interfaceid).merge(hostid: hostid)
      )
      response_id(result)
    end
  end
end
