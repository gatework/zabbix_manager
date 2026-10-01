# frozen_string_literal: true

class ZabbixManager
  # 原生通知媒介资源；仅提供最小默认值，不推断端点、凭据或版本字段。
  class MediaTypes < Resource
    # 返回媒介类型对象对应的 Zabbix API 方法前缀。
    # @return [String] API 方法前缀
    def method_name
      "mediatype"
    end

    # 返回媒介类型的最小默认属性；端点和凭据等版本相关字段由调用方显式提供。
    # @return [Hash] 媒介类型默认属性
    def default_options
      { type: 0 }
    end
  end
end
