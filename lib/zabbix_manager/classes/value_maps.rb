# frozen_string_literal: true

class ZabbixManager
  class ValueMaps < Resource
    # 返回 Zabbix API 中值映射对象的方法名前缀。
    #
    # @return [String] 值映射对象的方法名前缀
    def method_name
      "valuemap"
    end

    # 返回用于唯一识别值映射的业务字段名。
    #
    # @return [String] 值映射对象的业务标识字段名
    def identify
      "name"
    end
  end
end
