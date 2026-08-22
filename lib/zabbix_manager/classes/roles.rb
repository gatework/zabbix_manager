# frozen_string_literal: true

class ZabbixManager
  class Roles < Basic
    # 返回 Zabbix API 中角色对象的方法名前缀。
    #
    # @return [String] 角色对象的方法名前缀
    def method_name
      "role"
    end

    # 返回角色对象的主键字段名。
    #
    # @return [String] 角色对象的主键字段名
    def key
      "roleid"
    end

    # 返回用于唯一识别角色的业务字段名。
    #
    # @return [String] 角色对象的业务标识字段名
    def identify
      "name"
    end

    # 更新指定角色的权限规则。
    #
    # @param data [Hash] 包含 roleid 和 rules 的角色规则数据
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer] 已更新角色的 ID
    def rules(data)
      attributes = data.deep_symbolize_keys
      raise Invalid, "roleid is required" if attributes[:roleid].blank?
      raise Invalid, "rules is required" if attributes[:rules].blank?

      result = @client.api_request(
        method: "role.update",
        params: {
          roleid: attributes[:roleid],
          rules: attributes[:rules]
        }
      )
      result.fetch("roleids").first.to_i
    end

    # 按角色 ID 获取角色详情及完整规则。
    #
    # @param data [Hash] 包含 id 的查询参数
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Array<Hash>] 匹配的角色详情
    def dump_by_id(data)
      log "[DEBUG] Call dump_by_id with parameters: #{data.inspect}"

      @client.api_request(
        method: "role.get",
        params: {
          output: "extend",
          selectRules: "extend",
          roleids: data[:id]
        }
      )
    end

    # 按角色名称查询所有匹配的角色 ID。
    #
    # @param data [Hash] 包含 name 的角色查询参数
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Array<String>] 匹配的角色 ID 数组
    def get_ids_by_name(data)
      result = @client.api_request(
        method: "role.get",
        params: {
          filter: {
            name: data[:name]
          },
          output: "extend"
        }
      )

      result.filter_map do |rule|
        rule["roleid"]
      end
    end
  end
end
