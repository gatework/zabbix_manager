# frozen_string_literal: true

class ZabbixManager
  class Configurations < Basic
    # 标记配置接口使用数组形式处理 API 返回值。
    # @return [Boolean] 始终返回 true
    def array_flag
      true
    end

    # 返回配置对象对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "configuration"
    end

    # 返回配置对象用于业务识别的字段名。
    #
    # @return [String]
    def identify
      "host"
    end

    # 通过 Zabbix API 导出配置数据。
    #
    # @param data [Hash] 配置导出参数
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Hash] 配置导出结果
    def export(data)
      @client.api_request(method: "configuration.export", params: data)
    end

    # 通过 Zabbix API 导入配置数据。
    #
    # @param data [Hash] 配置导入参数及内容
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Hash] 配置导入结果
    def import(data)
      @client.api_request(method: "configuration.import", params: data)
    end
  end
end
