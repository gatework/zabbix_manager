# frozen_string_literal: true

class ZabbixManager
  class Applications < Resource
    # 返回应用集对象对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "application"
    end

    # 生成由应用集名称和所属主机构成的稳定查询条件。
    # @param data [Hash] 包含 name 和 hostid 的应用集属性
    # @return [Hash] 应用集唯一查询条件
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      { name: attributes.fetch(:name), hostid: attributes.fetch(:hostid) }
    end
  end
end
