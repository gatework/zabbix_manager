# frozen_string_literal: true

class ZabbixManager
  # Zabbix 7.0 起提供的原生代理组资源。
  class ProxyGroups < Resource
    # @return [String] 原生 API 方法前缀
    def method_name
      "proxygroup"
    end

    # @return [String] 原生代理组 ID 字段
    def key
      "proxy_groupid"
    end
  end
end
