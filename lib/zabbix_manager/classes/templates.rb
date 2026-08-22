# frozen_string_literal: true

class ZabbixManager
  class Templates < Basic
    # 返回 Zabbix API 中模板对象的方法名前缀。
    #
    # @return [String] 模板对象的方法名前缀
    def method_name
      "template"
    end

    # 返回用于唯一识别模板的业务字段名。
    #
    # @return [String] 模板对象的业务标识字段名
    def identify
      "host"
    end

    # 删除指定模板并返回首个已删除模板的 ID。
    #
    # @param data [Array] 要删除的 templateid 数组
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已删除模板的 ID，无结果时返回 nil
    def delete(data)
      result = @client.api_request(method: "template.delete", params: [data])
      result.empty? ? nil : result["templateids"][0].to_i
    end

    # 根据查询条件获取模板 ID 列表。
    #
    # @param data [Hash] Zabbix template.get 查询参数
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Array<String>] 模板 ID 数组
    def get_ids_by_host(data)
      @client.api_request(method: "template.get", params: data).map do |tmpl|
        tmpl["templateid"]
      end
    end

    # 批量更新主机与模板的关联关系。
    #
    # @param data [Hash] 包含 hosts_id 和 templates_id 数组
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Boolean] API 是否返回有效结果
    def mass_update(data)
      result = @client.api_request(
        method: "template.massUpdate",
        params: {
          hosts: data[:hosts_id].map { |t| { hostid: t } },
          templates: data[:templates_id].map { |t| { templateid: t } }
        }
      )
      result.empty? ? false : true
    end

    # 批量为主机添加模板关联。
    #
    # @param data [Hash] 包含 hosts_id 和 templates_id 数组
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Boolean] API 是否返回有效结果
    def mass_add(data)
      result = @client.api_request(
        method: "template.massAdd",
        params: {
          hosts: data[:hosts_id].map { |t| { hostid: t } },
          templates: data[:templates_id].map { |t| { templateid: t } }
        }
      )
      result.empty? ? false : true
    end

    # 批量移除主机的模板或主机组关联。
    #
    # @param data [Hash] 包含 hosts_id、templates_id 及可选 group_id
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Boolean] API 是否返回有效结果
    def mass_remove(data)
      result = @client.api_request(
        method: "template.massRemove",
        params: {
          hostids: data[:hosts_id],
          templateids: data[:templates_id],
          groupids: data[:group_id],
          force: 1
        }
      )
      result.empty? ? false : true
    end

    # 按模板技术名称查询，并返回可直接用于主机或模板更新的引用对象。
    #
    # @param data [String, Array<String>] 一个或多个模板技术名称
    # @return [Array<Hash>, nil] templateid 引用数组，未找到时返回 nil
    def get_template_ids(data)
      result = @client.api_request(
        method: "template.get",
        params: {
          output: "extend",
          filter: {
            host: Array(data)
          }
        }
      ).map { |template| { templateid: template.fetch("templateid") } }

      result.presence
    end
  end
end
