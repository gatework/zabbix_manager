# frozen_string_literal: true

class ZabbixManager
  # 主机群组名称解析与按需创建；批量创建按顺序执行，不是远端事务。
  class HostGroups < Resource
    # 返回主机群组对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "hostgroup"
    end

    # 返回主机群组的 Zabbix ID 字段名。
    #
    # @return [String]
    def key
      "groupid"
    end

    # 批量解析主机群组名称并返回对应的群组 ID。
    # @param data [Array<String>, String] 待查询的群组名称
    # @raise [ProtocolError] 远端群组身份或 ID 无效
    # @raise [Conflict] 远端群组名称不唯一
    # @return [Array<Hash>, nil] 群组 ID 列表，未命中时返回 nil
    def get_hostgroup_ids(data)
      names = normalized_names(data)
      return nil if names.empty?

      groups = groups_by_name(names)
      groups.empty? ? nil : groups.values.map { |id| { groupid: id } }
    end

    # 批量查询并创建缺失的主机群组，避免逐名称重复查询。
    # @param data [Array<String>, String] 待确保存在的群组名称
    # @raise [ProtocolError] 远端群组身份或 ID 无效
    # @raise [Conflict] 远端群组名称不唯一
    # @return [Array<Hash>] 群组 ID 列表
    def get_or_create_host_groups(data)
      names = normalized_names(data)
      return [] if names.empty?

      existing = groups_by_name(names)

      names.map do |name|
        id = existing[name]
        next({ groupid: id }) if id

        result = @client.api_request(method: "hostgroup.create", params: { name: name })
        { groupid: response_id(result).to_s }
      end
    end

    # 全部查询结果先核对身份和 ID，损坏或重名响应不能触发部分创建。
    private def groups_by_name(names)
      rows = response_objects(@client.api_request(
                                method: "hostgroup.get",
                                params: { output: %w[groupid name], filter: { name: names } }
                              ))
      requested = names.to_h { |name| [name, true] }
      ids = {}
      rows.each_with_object({}) do |group, result|
        name = group["name"]
        unless name.is_a?(String) && requested.key?(name)
          raise ProtocolError, "hostgroup.get returned a group outside the requested names"
        end

        id = response_identifier(group["groupid"]).to_s
        raise Conflict, "multiple host groups share the same name" if result.key?(name)
        raise ProtocolError, "hostgroup.get returned duplicate group IDs" if ids.key?(id)

        ids[id] = true
        result[name] = id
      end
    end

    # 清理、去空并去重主机群组名称。
    # @param data [Array<String>, String] 原始群组名称
    # @return [Array<String>] 规范化后的群组名称
    private def normalized_names(data)
      Array(data).filter_map { |name| name.to_s.strip.presence }.uniq
    end
  end
end
