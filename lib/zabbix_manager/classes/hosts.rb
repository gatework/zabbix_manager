# frozen_string_literal: true

class ZabbixManager
  class Hosts < Basic
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
      log "[DEBUG] Call dump_by_id with parameters: #{data.inspect}"
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

    # 从指定主机批量解除模板关联。
    def unlink_templates(data)
      result = @client.api_request(
        method: "host.massRemove",
        params: {
          hostids: data[:hosts_id],
          templateids: data[:templates_id]
        }
      )
      !result.empty?
    end

    # 使用显式群组和接口创建主机，不注入隐藏凭据。
    def create(data)
      attributes = default_options.merge(data.deep_symbolize_keys)
      validate_create_attributes!(attributes)
      result = @client.api_request(method: "host.create", params: attributes)
      first_id(result, "hostids")
    end

    # 规范化并校验设备定义，不执行远端查询或写入。
    # 已存在设备允许只更新部分字段，新设备的群组和接口由 create 再次严格校验。
    # @return [Hash]
    def validate(data)
      attributes = data.deep_symbolize_keys
      raise Invalid, "host is required" if attributes[:host].blank?

      hostinterfaces.validate(attributes[:interfaces]) if attributes.key?(:interfaces)
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
      hostinterfaces.validate(interfaces)
      update_attributes = attributes.merge(hostid: hostid)
      @client.api_request(method: "host.update", params: update_attributes)
      hostinterfaces.reconcile_for_host(hostid: hostid, interfaces: interfaces) if interfaces.any?
      hostid.to_i
    end

    # 查询指定主机的全部接口。
    def interfaces_for(hostid)
      hostinterfaces.for_host(hostid)
    end

    # 返回主机的第一个接口 ID；高频业务应优先使用 hostinterfaces。
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
      find_host_by_filter(hostid: hostid)
    end

    # 批量启用或停用主机。
    # @return [Array<Integer>]
    def set_status(hostids, enabled:)
      ids = Array(hostids).filter_map { |value| value.to_s.strip.presence }.uniq
      raise Invalid, "hostids are required" if ids.empty?

      params = ids.map { |hostid| { hostid: hostid, status: enabled ? 0 : 1 } }
      result = @client.api_request(method: "host.update", params: params)
      Array(result.fetch("hostids")).map(&:to_i)
    end

    # 把可见名称对应的主机更新为稳定技术标识。
    def update_host_to_serial(data)
      attributes = data.deep_symbolize_keys
      hostid = get_hostid_by_name(attributes[:name])
      return nil unless hostid

      attributes.delete(:templates)
      @client.api_request(method: "host.update", params: attributes.merge(hostid: hostid))
      hostid.to_i
    end

    private

      # 校验创建主机所需的技术名、群组和接口。
      def validate_create_attributes!(attributes)
        raise Invalid, "host is required" if attributes[:host].blank?
        raise Invalid, "groups are required when creating a host" if Array.wrap(attributes[:groups]).empty?
        raise Invalid, "interfaces are required when creating a host" if Array.wrap(attributes[:interfaces]).empty?

        attributes[:interfaces] = hostinterfaces.validate_for_create(attributes[:interfaces])
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
        raise Conflict, "host lookup is ambiguous for #{filter.inspect}" if result.length > 1

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
        raise Conflict, "host lookup is ambiguous for #{filter.inspect}" if result.length > 1

        result.first&.fetch("hostid", nil)
      end

      # 从 Zabbix 创建响应中提取首个整数 ID。
      def first_id(result, key_name)
        value = result.fetch(key_name).first
        value && value.to_i
      end

      # 延迟构建接口模块并复用当前客户端。
      # @return [HostInterfaces]
      # @api private
      def hostinterfaces
        @hostinterfaces ||= HostInterfaces.new(@client)
      end
  end
end
