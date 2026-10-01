# frozen_string_literal: true

class ZabbixManager
  class UserGroups < Resource
    def method_name
      "usergroup"
    end

    def key
      "usrgrpid"
    end

    # 完整替换主机组权限；空数组明确清空，Zabbix 6.2 起保留独立的模板组权限。
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
