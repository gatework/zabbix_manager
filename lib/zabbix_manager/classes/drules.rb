# frozen_string_literal: true

class ZabbixManager
  class Drules < Basic
    # 返回网络发现规则对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "drule"
    end

    # 返回网络发现规则用于业务识别的字段名。
    #
    # @return [String]
    def identify
      "name"
    end

    # 返回创建网络发现规则时使用的默认周期和启用状态。
    #
    # @return [Hash] 网络发现规则默认属性
    def default_options
      {
        delay: "1h",
        status: 0
      }
    end
  end
end
