# frozen_string_literal: true

class ZabbixManager
  # 主机身份解析、状态对账与模板关联；技术名称和显示名称分别处理。
  class Hosts < Resource
    # 返回主机对应的 Zabbix API 模块名。
    def method_name
      "host"
    end

    # 使用技术主机名作为通用 CRUD 标识。
    def identify
      "host"
    end

    # 返回创建主机时的克制默认值。
    def default_options
      {
        status: 0,
        inventory_mode: 1
      }
    end

    # 按主机 ID 查询完整主机及接口、群组和模板。
    def dump_by_id(data)
      @client.api_request(
        method: "host.get",
        params: {
          filter: { key.to_sym => data[key.to_sym] },
          output: "extend",
          selectGroups: "extend",
          selectInterfaces: "extend",
          selectParentTemplates: ["templateid", "host", "name"]
        }
      )
    end

    # 向指定主机追加模板关联，保留现有模板。
    # @return [Array<Integer>] 已更新主机 ID
    def link_templates(host_ids:, template_ids:)
      write_templates("massadd", host_ids, template_ids)
    end

    # 完整替换指定主机的模板关联，空模板集合明确清除全部关联。
    # @return [Array<Integer>] 已更新主机 ID
    def replace_templates(host_ids:, template_ids:)
      write_templates("massupdate", host_ids, template_ids, allow_empty: true)
    end

    # 从指定主机解除选定模板的关联，保留模板生成的实体。
    # @return [Array<Integer>] 已更新主机 ID
    def unlink_templates(host_ids:, template_ids:)
      ids = normalized_ids(host_ids)
      templates = normalized_ids(template_ids)
      result = @client.api_request(method: "host.massremove", params: { hostids: ids, templateids: templates })
      response_ids(result, expected: ids)
    end

    # 使用显式群组和接口创建主机，不注入隐藏凭据。
    def create(data)
      attributes = default_options.merge(data.deep_symbolize_keys)
      validate_create_attributes!(attributes)
      result = @client.api_request(method: "host.create", params: attributes)
      response_id(result)
    end

    # 规范化并校验设备定义，不执行远端查询或写入。
    # 已存在设备允许只更新部分字段，新设备的群组和接口由 create 再次严格校验。
    # @return [Hash]
    def validate(data)
      attributes = data.deep_symbolize_keys
      raise Invalid, "host is required" if attributes[:host].blank?

      host_interfaces.validate(attributes[:interfaces]) if attributes.key?(:interfaces)
      attributes
    end

    # 幂等同步主机元数据和显式接口，调用方保持业务字段权威。
    def reconcile(data)
      attributes = validate(data)
      host = attributes.fetch(:host)

      hostid = get_id(host: host)
      unless hostid
        outcome, hostid = @client.with_upsert_lock("host-create:#{host}") do
          current_id = get_id(host: host)
          current_id ? [:existing, current_id] : [:created, create(attributes)]
        end
        return hostid.to_i if outcome == :created
      end

      update_existing(hostid, attributes)
    end

    # 更新主机元数据，并把接口同步委托给带主机锁的接口模块。
    # @return [Integer]
    # @api private
    private def update_existing(hostid, attributes)
      attributes = attributes.dup

      interfaces = Array.wrap(attributes.delete(:interfaces))
      host_interfaces.validate(interfaces)
      update_attributes = attributes.merge(hostid: hostid)
      host_interfaces.reconcile_for_host(hostid: hostid, interfaces: interfaces) if interfaces.any?
      result = @client.api_request(method: "host.update", params: update_attributes)
      response_id(result, expected: [hostid])
    end

    # 查询指定主机的全部接口。
    def interfaces_for(hostid)
      host_interfaces.for_host(hostid)
    end

    # 返回主机的第一个接口 ID；高频业务应优先使用 host_interfaces。
    def get_interface_id(hostid)
      interfaces_for(hostid).first&.fetch("interfaceid", nil)
    end

    # 按技术主机名查询主机 ID。
    def get_host_id(name)
      find_host_id(host: name)
    end

    # 按可见名称查询主机 ID。
    def get_hostid_by_name(name)
      find_host_id(name: name)
    end

    # 用技术名、可见名或接口 IP/DNS 解析唯一主机。
    def find_by_candidates(candidates)
      matches = Array(candidates).filter_map { |candidate| candidate.to_s.strip.presence }.uniq.flat_map do |candidate|
        hosts = [find_host_by_filter(host: candidate), find_host_by_filter(name: candidate)].compact
        interface = find_interface_by_endpoint(candidate)
        hosts << find_host_by_filter(hostid: interface["hostid"]) if interface
        hosts
      end
      matches.uniq! { |host| host.fetch("hostid") }
      if matches.length > 1
        raise Conflict, "host candidates resolve to multiple hosts; provide an explicit host object"
      end

      matches.first
    end

    # 按主机 ID 查询唯一主机，并返回表达式需要的技术名称。
    # @return [Hash, nil]
    def find_by_id(hostid)
      positive_id_attribute(hostid, "hostid")
      find_host_by_filter(hostid: hostid)
    end

    # 解析供流量查询和监控表达式使用的唯一主机；只执行读取。
    # 显式 ID 与技术名必须同时匹配，候选名称不能分别指向不同主机。
    # @param reference [String, Array<String>, Hash] 名称/IP/DNS 候选，或同时包含 hostid 和 host 的 Hash
    # @return [Hash] 符号键主机属性，包含 hostid 和技术名 host
    # @raise [Invalid] 本地主机引用无效
    # @raise [ApiError] 主机不存在或当前 API 用户不可见
    # @raise [Conflict] 候选不唯一，或 ID 与技术名不匹配
    # @raise [ProtocolError] API 返回无效的主机身份
    def resolve(reference)
      if reference.is_a?(Hash)
        expected = Monitoring::Validation.hash!(reference, "host")
        Monitoring::Validation.host!(expected)
        found = find_by_id(expected[:hostid])
      else
        candidates = Array.wrap(reference).map do |candidate|
          Monitoring::Validation.text!(candidate, "host candidate").strip
        end
        raise Invalid, "host candidates are required" if candidates.empty?

        found = find_by_candidates(candidates.uniq)
      end
      raise ApiError, "Zabbix host was not found for the supplied reference" unless found

      resolved = resolved_host(found)
      if expected && (resolved[:hostid].to_s != expected[:hostid].to_s || resolved[:host] != expected[:host])
        raise Conflict, "hostid and technical host name do not refer to the same Zabbix host"
      end

      resolved
    end

    # 批量启用或停用主机。
    # @return [Array<Integer>]
    def set_status(hostids, enabled:)
      validate_boolean!(enabled, "enabled")
      ids = normalized_ids(hostids)

      params = ids.map { |hostid| { hostid: hostid, status: enabled ? 0 : 1 } }
      result = @client.api_request(method: "host.update", params: params)
      response_ids(result, expected: ids)
    end

    private

    # 远端身份损坏是协议错误，不能当作调用方输入错误或不存在处理。
    def resolved_host(found)
      resolved = Monitoring::Validation.hash!(found, "Zabbix host")
      Monitoring::Validation.host!(resolved)
      resolved
    rescue Invalid
      raise ProtocolError, "invalid host response: hostid and technical host are required", cause: nil
    end

    def write_templates(operation, host_ids, template_ids, allow_empty: false)
      ids = normalized_ids(host_ids)
      templates = normalized_ids(template_ids, allow_empty: allow_empty)
      result = @client.api_request(
        method: "host.#{operation}",
        params: {
          hosts: ids.map { |id| { hostid: id } },
          templates: templates.map { |id| { templateid: id } }
        }
      )
      response_ids(result, expected: ids)
    end

    # 校验创建主机所需的技术名、群组和接口。
    def validate_create_attributes!(attributes)
      raise Invalid, "host is required" if attributes[:host].blank?
      raise Invalid, "groups are required when creating a host" if Array.wrap(attributes[:groups]).empty?
      raise Invalid, "interfaces are required when creating a host" if Array.wrap(attributes[:interfaces]).empty?

      attributes[:interfaces] = host_interfaces.validate_for_create(attributes[:interfaces])
    end

    # 使用精确过滤查询唯一主机。
    def find_host_by_filter(filter)
      result = @client.api_request(
        method: "host.get",
        params: {
          output: %w[hostid host name status],
          filter: filter,
          selectInterfaces: %w[interfaceid ip dns]
        }
      )
      response_objects(result)
      raise Conflict, "host lookup is ambiguous for #{filter.inspect}" if result.length > 1

      response_identifier(result.first["hostid"]) if result.first
      result.first
    end

    # 按 IP 和 DNS 端点查询唯一主机接口。
    def find_interface_by_endpoint(candidate)
      matches = []
      %i[ip dns].each do |field|
        result = @client.api_request(
          method: "hostinterface.get",
          params: { filter: { field => candidate }, output: ["hostid"] }
        )
        response_objects(result).each { |interface| response_identifier(interface["hostid"], "hostid") }
        matches.concat(result)
      end
      matches.uniq! { |interface| interface.fetch("hostid") }
      raise Conflict, "interface endpoint #{candidate} belongs to multiple hosts" if matches.length > 1

      matches.first
    end

    # 只查询唯一主机 ID。
    def find_host_id(filter)
      result = @client.api_request(
        method: "host.get",
        params: {
          output: ["hostid"],
          filter: filter
        }
      )
      response_objects(result)
      raise Conflict, "host lookup is ambiguous for #{filter.inspect}" if result.length > 1

      response_identifier(result.first["hostid"]).to_s if result.first
    end

    # 延迟构建接口模块并复用当前客户端。
    # @return [HostInterfaces]
    # @api private
    def host_interfaces
      @host_interfaces ||= HostInterfaces.new(@client)
    end
  end
end
