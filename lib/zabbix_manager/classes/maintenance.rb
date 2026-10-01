# frozen_string_literal: true

class ZabbixManager
  # 原生维护期资源；时间段、目标主机和群组由调用方显式定义。
  class Maintenance < Resource
    # 返回维护期对象对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "maintenance"
    end

    # 返回维护期对象用于业务识别的字段名。
    #
    # @return [String]
    def identify
      "name"
    end
  end
end
