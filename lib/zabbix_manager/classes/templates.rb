# frozen_string_literal: true

class ZabbixManager
  # 按模板技术名称解析 ID；返回引用供主机或模板关联操作使用。
  class Templates < Resource
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
