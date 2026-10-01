# frozen_string_literal: true

class ZabbixManager
  # 原生值映射资源；所属范围与映射规则由调用方提供。
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

    # 5.4 起值映射属于主机或模板；旧版仍按全局名称定位。
    # @return [Hash] 带版本边界的精确身份条件
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      identity = super(attributes)
      if host_scoped?
        raise Invalid, "hostid is required for a host-scoped value map" unless attributes.key?(:hostid)

        identity[:hostid] = normalized_ids([attributes[:hostid]]).first
      end
      identity
    end

    # 名称查询始终经过完整身份检查，避免跨主机合法重名造成误选。
    # @return [Integer, nil] 唯一值映射 ID
    def get_id(data)
      super(identity_filter(data))
    end

    # hostid 用于身份查询和创建，不能用于移动已有值映射。
    # @return [Integer] 已确认的值映射 ID
    def update(data)
      attributes = data.deep_symbolize_keys
      super(host_scoped? ? attributes.except(:hostid) : attributes)
    end

    private

    def host_scoped?
      Gem::Version.new(@client.api_version) >= Gem::Version.new("5.4")
    end
  end
end
