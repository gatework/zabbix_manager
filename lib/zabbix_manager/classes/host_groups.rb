# frozen_string_literal: true

class ZabbixManager
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
    # @return [Array<Hash>, nil] 群组 ID 列表，未命中时返回 nil
    def get_hostgroup_ids(data)
      names = normalized_names(data)
      return nil if names.empty?

      groups = @client.api_request(
        method: "hostgroup.get",
        params: {
          output: %w[groupid name],
          filter: { name: names }
        }
      )

      groups.empty? ? nil : groups.map { |group| { groupid: group.fetch("groupid") } }
    end

    # 批量查询并创建缺失的主机群组，避免逐名称重复查询。
    # @param data [Array<String>, String] 待确保存在的群组名称
    # @return [Array<Hash>] 群组 ID 列表
    def get_or_create_host_groups(data)
      names = normalized_names(data)
      existing = @client.api_request(
        method: "hostgroup.get",
        params: { output: %w[groupid name], filter: { name: names } }
      ).index_by { |group| group.fetch("name") }

      names.map do |name|
        group = existing[name]
        next({ groupid: response_identifier(group["groupid"]).to_s }) if group

        result = @client.api_request(method: "hostgroup.create", params: { name: name })
        { groupid: response_id(result).to_s }
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
