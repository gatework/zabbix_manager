# frozen_string_literal: true

class ZabbixManager
  # 用户组成员和主机组权限替换；空数组表示清空，省略字段不参与更新。
  class UserGroups < Resource
    # @return [String] 原生用户组 API 前缀
    def method_name
      "usergroup"
    end

    # @return [String] 用户组 ID 字段
    def key
      "usrgrpid"
    end

    # 完整替换主机组权限；空数组明确清空，Zabbix 6.2 起保留独立的模板组权限。
    # @param user_group_id [Integer, String] 目标用户组 ID
    # @param host_group_ids [Array<Integer, String>] 完整期望主机组集合
    # @param permission [Integer, String] 0 拒绝、2 只读、3 读写
    # @return [Integer] 回执确认的用户组 ID
    def replace_host_group_permissions(user_group_id:, host_group_ids:, permission: 2)
      group_id = normalized_ids([user_group_id]).first
      host_ids = collection_ids(host_group_ids, "host_group_ids", allow_empty: true)
      access = integer_attribute(permission, "permission")
      raise Invalid, "permission must be 0, 2, or 3" unless [0, 2, 3].include?(access)

      rights_field = api_version >= Gem::Version.new("6.2") ? :hostgroup_rights : :rights
      result = @client.api_request(
        method: "usergroup.update",
        params: { usrgrpid: group_id, rights_field => host_ids.map { |id| { id: id, permission: access } } }
      )
      response_id(result, expected: [group_id])
    end

    # 完整替换各用户组成员；空 user_ids 明确移除现有成员。
    # @param user_group_ids [Array<Integer, String>] 待更新用户组 ID
    # @param user_ids [Array<Integer, String>] 每组的完整期望用户集合
    # @return [Array<Integer>] 回执确认的全部用户组 ID
    def replace_users(user_group_ids:, user_ids:)
      group_ids = collection_ids(user_group_ids, "user_group_ids")
      users = collection_ids(user_ids, "user_ids", allow_empty: true)
      membership = api_version >= Gem::Version.new("6.0") ?
                     { users: users.map { |id| { userid: id } } } : { userids: users }
      result = @client.api_request(
        method: "usergroup.update",
        params: group_ids.map { |id| membership.merge(usrgrpid: id) }
      )
      response_ids(result, expected: group_ids)
    end

    private

    def api_version
      Gem::Version.new(@client.api_version)
    end

    def collection_ids(values, name, allow_empty: false)
      raise Invalid, "#{name} must be an Array" unless values.is_a?(Array)

      normalized_ids(values, allow_empty: allow_empty)
    end
  end
end
