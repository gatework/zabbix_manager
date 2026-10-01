# frozen_string_literal: true

class ZabbixManager
  class Actions < Resource
    # 返回操作对象对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "action"
    end

    # 获取操作及其执行、恢复、确认操作和过滤条件的完整数据。
    #
    # @param data [Hash] 包含识别字段及其值的查询条件
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Hash] 匹配的操作完整数据
    def get_full_data(data)
      @client.api_request(
        method: "#{method_name}.get",
        params: {
          filter: {
            identify.to_sym => data[identify.to_sym]
          },
          output: "extend",
          selectOperations: "extend",
          selectRecoveryOperations: "extend",
          selectAcknowledgeOperations: "extend",
          selectFilter: "extend"
        }
      )
    end
  end
end
