# frozen_string_literal: true

class ZabbixManager
  class Usergroups < Basic
    # 返回 Zabbix API 中用户组对象的方法名前缀。
    #
    # @return [String] 用户组对象的方法名前缀
    def method_name
      "usergroup"
    end

    # 返回用户组对象的主键字段名。
    #
    # @return [String] 用户组对象的主键字段名
    def key
      "usrgrpid"
    end

    # 返回用于唯一识别用户组的业务字段名。
    #
    # @return [String] 用户组对象的业务标识字段名
    def identify
      "name"
    end

    # 更新用户组对主机组的访问权限。
    #
    # @param data [Hash] 包含 usrgrpid、hostgroupids 及可选 permission
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已更新用户组的 ID
    def permissions(data)
      permission = data[:permission] || 2
      result = @client.api_request(
        method: "usergroup.update",
        params: {
          usrgrpid: data[:usrgrpid],
          rights: data[:hostgroupids].map { |t| { permission: permission, id: t } }
        }
      )
      result ? result["usrgrpids"][0].to_i : nil
    end

    # 将用户加入用户组；兼容旧调用并委托给 update_users。
    #
    # @deprecated Zabbix 已移除 massAdd，请使用 update_users。
    # @param data [Hash] 包含 userids 和 usrgrpids
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已更新用户组的 ID
    def add_user(data)
      update_users(data)
    end

    # 批量替换指定用户组中的用户列表。
    #
    # @param data [Hash] 包含 userids 和 usrgrpids
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 首个已更新用户组的 ID
    def update_users(data)
      user_groups = data[:usrgrpids].map do |t|
        {
          usrgrpid: t,
          userids: data[:userids]
        }
      end
      result = @client.api_request(
        method: "usergroup.update",
        params: user_groups
      )
      result ? result["usrgrpids"][0].to_i : nil
    end
  end
end
