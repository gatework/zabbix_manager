# frozen_string_literal: true

class ZabbixManager
  class Proxies < Basic
    # 返回 Zabbix API 中代理对象的方法名前缀。
    #
    # @return [String] 代理对象的方法名前缀
    def method_name
      "proxy"
    end

    # 返回用于唯一识别代理对象的字段名。
    #
    # @return [String] 代理对象的标识字段名
    def identify
      "host"
    end

    # 通过 Zabbix API 删除指定代理，并返回首个已删除代理的 ID。
    #
    # @param data [Array] 要删除的 proxyid 数组
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已删除代理的 ID，无结果时返回 nil
    def delete(data)
      result = @client.api_request(method: "proxy.delete", params: data)
      result.empty? ? nil : result["proxyids"][0].to_i
    end

    # 检查当前凭证是否可读取指定代理。
    #
    # @param data [Array] 要检查的 proxyid 数组
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Boolean] 指定代理是否可读
    def isreadable(data)
      @client.api_request(method: "proxy.isreadable", params: data)
    end

    # 检查当前凭证是否可写入指定代理。
    #
    # @param data [Array] 要检查的 proxyid 数组
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Boolean] 指定代理是否可写
    def iswritable(data)
      @client.api_request(method: "proxy.iswritable", params: data)
    end

    # 按代理名称查询唯一代理 ID，空名称返回 nil，重名时拒绝选择。
    #
    # @param proxy [String] 代理名称
    # @return [String, nil] 唯一代理 ID，未找到时返回 nil
    def get_proxy_id(proxy)
      return nil if proxy.blank?

      # 请求后端接口，只支持单个代理节点
      result = @client.api_request(
        method: "proxy.get",
        params: {
          output: %w[proxyid host],
          filter: {
            host: proxy
          }
        }
      )
      raise Conflict, "proxy lookup is ambiguous for #{proxy}" if result.length > 1

      result.first&.fetch("proxyid", nil)
    end
  end
end
