# frozen_string_literal: true

class ZabbixManager
  class Basic
    # 按标识字段从 Zabbix API 获取对象完整数据。
    #
    # @param data [Hash] 包含对象标识字段及其值
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Hash] 对象完整数据
    def get(data)
      get_full_data(data)
    end

    # 通过 Zabbix API 创建对象。
    #
    # @param data [Hash] 待创建的对象属性
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer] 创建单个对象时返回对象 ID
    # @return [Boolean] 创建多个对象时返回操作结果
    def add(data)
      create(data)
    end

    # 通过 Zabbix API 删除对象。
    #
    # @param data [Hash] 包含对象标识字段及其值
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer] 删除单个对象时返回对象 ID
    # @return [Boolean] 删除多个对象时返回操作结果
    def destroy(data)
      delete(data)
    end

    # 返回子类对应的 Zabbix API 方法名；由具体资源类实现。
    #
    # @return [String, nil] API 方法名
    def method_name; end
  end
end
