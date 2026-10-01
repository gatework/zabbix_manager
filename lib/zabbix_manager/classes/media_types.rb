# frozen_string_literal: true

class ZabbixManager
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
