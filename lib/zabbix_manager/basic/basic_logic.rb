# frozen_string_literal: true

class ZabbixManager
  class Basic
    # 合并默认选项后通过 Zabbix API 创建对象。
    #
    # @param data [Hash] 待创建的对象属性
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer] 创建单个对象时返回对象 ID
    # @return [Boolean] 创建多个对象时返回操作结果
    def create(data)
      log "[DEBUG] Call create with parameters: #{data.inspect}"

      # 判断是否绑定默认选项并重新生成配置
      data_with_default = default_options.empty? ? data : default_options.merge(data)
      data_create       = [data_with_default]

      # 调用实例方法
      result = @client.api_request(method: "#{method_name}.create", params: data_create)
      # 判断是否执行成功并返回结果
      parse_keys result
    end

    # 通过 Zabbix API 删除对象。
    #
    # @param data [Hash] 包含待删除对象的 ID 字段和值
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer] 删除单个对象时返回对象 ID
    # @return [Boolean] 删除多个对象时返回操作结果
    def delete(data)
      log "[DEBUG] Call delete with parameters: #{data.inspect}"

      data_delete = [data]
      result      = @client.api_request(method: "#{method_name}.delete", params: data_delete)
      parse_keys result
    end

    # 按业务标识查找对象，存在则更新，否则创建。
    #
    # @param data [Hash] 包含对象业务标识及待写入属性
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer] 创建或更新后的对象 ID
    # @return [Boolean] 批量操作时返回操作结果
    def create_or_update(data)
      log "[DEBUG] Call create_or_update with parameters: #{data.inspect}"

      id = get_id(**identity_filter(data))
      id ? update(data.merge(key.to_sym => id)) : create(data)
    end

    # 在属性发生变化或强制更新时通过 Zabbix API 更新对象。
    #
    # @param data [Hash] 包含对象 ID 及待更新属性
    # @param force [Boolean] 属性一致时是否仍强制更新
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer] 更新后的对象 ID
    # @return [Boolean] 批量操作时返回操作结果
    def update(data, force = false)
      log "[DEBUG] Call update with parameters: #{data.inspect}"
      dump = {}
      dump_by_id(key.to_sym => data[key.to_sym]).each do |item|
        dump = item.deep_symbolize_keys if item[key].to_i == data[key.to_sym].to_i
      end
      if hash_equals?(dump, data) && !force
        log "[DEBUG] Equal keys #{dump} and #{data}, skip update"
        data[key.to_sym].to_i
      else
        data_update = [data]
        result      = @client.api_request(method: "#{method_name}.update", params: data_update)
        parse_keys result
      end
    end

    # 按业务标识从 Zabbix API 获取对象扩展数据。
    #
    # @param data [Hash] 包含对象业务标识字段及其值
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Hash] 对象扩展数据
    def get_full_data(data)
      log "[DEBUG] Call get_full_data with parameters: #{data.inspect}"

      @client.api_request(
        method: "#{method_name}.get",
        params: {
          filter: {
            identify.to_sym => data[identify.to_sym]
          },
          output: "extend"
        }
      )
    end

    # 将调用方参数直接传给对应的 Zabbix get 方法。
    #
    # @param data [Hash] 原始查询参数
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Hash] API 返回数据
    def get_raw(data)
      log "[DEBUG] Call get_raw with parameters: #{data.inspect}"

      @client.api_request(
        method: "#{method_name}.get",
        params: data
      )
    end

    # 按对象 ID 字段从 Zabbix API 获取扩展数据。
    #
    # @param data [Hash] 包含对象 ID 字段及其值
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Hash] 对象扩展数据
    def dump_by_id(data)
      log "[DEBUG] Call dump_by_id with parameters: #{data.inspect}"

      @client.api_request(
        method: "#{method_name}.get",
        params: {
          filter: {
            key.to_sym => data[key.to_sym]
          },
          output: "extend"
        }
      )
    end

    # 获取当前资源的全部对象，并返回业务标识到 ID 的映射。
    #
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Hash] 业务标识到对象 ID 的映射
    def all
      result = {}
      @client.api_request(
        method: "#{method_name}.get",
        params: { output: "extend" }
      ).each do |item|
        result[item[identify]] = item[key]
      end
      result
    end

    # 按业务标识精确查询对象 ID，并拒绝歧义结果。
    #
    # @param data [Hash] 业务标识过滤条件
    # @raise [ApiError] API 调用失败、缺少标识字段或结果不唯一时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer, nil] Zabbix 对象 ID，未找到时返回空值
    def get_id(data)
      log "[DEBUG] Call get_id with parameters: #{data.inspect}"

      data = data.deep_symbolize_keys
      # 缺少业务标识字段时立即终止查询
      name = data[identify.to_sym]
      raise Invalid, "#{identify} not supplied in call to get_id" if name.nil?

      result = @client.api_request(
        method: "#{method_name}.get",
        params: {
          filter: data,
          output: [key, identify]
        }
      )
      matches = result.select { |item| item[identify].to_s == name.to_s }
      raise Conflict, "multiple #{method_name} objects match #{identify}=#{name}" if matches.length > 1

      matches.first&.fetch(key, nil)&.to_i
    end

    # 按业务标识获取对象，不存在时创建。
    #
    # @param data [Hash] 包含对象业务标识及待创建属性
    # @raise [ApiError] Zabbix API 调用失败时抛出
    # @raise [TransportError] Zabbix 服务端返回非 200 状态时抛出
    # @return [Integer] Zabbix 对象 ID
    def get_or_create(data)
      log "[DEBUG] Call get_or_create with parameters: #{data.inspect}"

      unless (id = get_id(**identity_filter(data)))
        id = create(data)
      end
      id
    end

    # 提取通用获取或写入操作使用的远端业务标识。
    #
    # @param data [Hash] 对象属性
    # @return [Hash] 业务标识过滤条件
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      { identify.to_sym => attributes.fetch(identify.to_sym) }
    end

    # 使用原始参数直接创建 Zabbix 对象。
    #
    # @param data [Hash, Array] 原始创建参数
    # @return [Object] API 返回结果
    def create_raw(data)
      log "[DEBUG] Call create_raw with parameters: #{data.inspect}"
      # 请求创建数据
      @client.api_request(
        method: "#{method_name}.create",
        params: data
      )
    end

    # 使用原始参数直接更新 Zabbix 对象。
    #
    # @param data [Hash, Array] 原始更新参数
    # @return [Object] API 返回结果
    def update_raw(data)
      log "[DEBUG] Call update_raw with parameters: #{data.inspect}"
      # 请求创建数据
      @client.api_request(
        method: "#{method_name}.update",
        params: data
      )
    end

    # 使用原始参数直接删除 Zabbix 对象。
    #
    # @param data [Hash, Array] 原始删除参数
    # @return [Object] API 返回结果
    def delete_raw(data)
      log "[DEBUG] Call delete_raw with parameters: #{data.inspect}"
      # 请求创建数据
      @client.api_request(
        method: "#{method_name}.delete",
        params: data
      )
    end
  end
end
