# frozen_string_literal: true

class ZabbixManager
  class HttpTests < Resource
    # 返回 Web 场景对象对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "httptest"
    end

    # 返回创建 Web 场景时使用的默认步骤列表。
    #
    # @return [Hash] Web 场景默认属性
    def default_options
      {
        steps: []
      }
    end

    # 生成由 Web 场景名称和所属主机构成的稳定查询条件。
    #
    # @param data [Hash] 包含 name 和 hostid 的 Web 场景属性
    # @raise [KeyError] 缺少 name 或 hostid 时抛出
    # @return [Hash] Web 场景唯一查询条件
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      { name: attributes.fetch(:name), hostid: attributes.fetch(:hostid) }
    end
  end
end
