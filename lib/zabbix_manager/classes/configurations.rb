# frozen_string_literal: true

class ZabbixManager
  # 原生配置导入/导出入口；导入可能修改多个远端对象，不提供本地回滚。
  class Configurations < Resource
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
    # @return [String] 服务端按指定格式序列化的配置内容
    def export(data)
      @client.api_request(method: "configuration.export", params: data)
    end

    # 通过 Zabbix API 导入配置数据。
    #
    # @param data [Hash] 配置导入参数及内容
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Boolean] 服务端确认的导入结果
    def import(data)
      @client.api_request(method: "configuration.import", params: data)
    end
  end
end
