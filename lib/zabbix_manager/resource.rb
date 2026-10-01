# frozen_string_literal: true

class ZabbixManager
  # 共享资源身份、精确查询和单对象写入行为。
  # 子类声明 API 前缀、身份和回执字段；原生透传仍由调用方负责授权及版本适配。
  # 回执校验只确认响应中的 ID，不提供事务、跨进程排他或失败后的自动重放。
  class Resource
    # @param client [ZabbixManager::Client] 共享客户端
    def initialize(client)
      @client = client
    end

    # @return [String] Zabbix API 模块名
    def method_name
      raise Invalid, "resource API method is not defined"
    end

    # @return [String] 业务标识字段
    def identify
      "name"
    end

    # @return [String] 对象 ID 字段
    def key
      "#{method_name}id"
    end

    # @return [String] 写入响应的 ID 集合字段
    def keys
      "#{key}s"
    end

    # @return [Hash] 创建默认属性
    def default_options
      {}
    end

    # 合并创建默认属性，不修改调用方输入。
    # @param data [Hash] 对应资源的原生 API 属性
    # @return [Integer] 创建对象的 ID
    # @raise [ProtocolError] 响应没有确认唯一的有效 ID
    def create(data)
      response_id(create_raw([default_options.merge(data.deep_symbolize_keys)]))
    end

    # 删除明确指定的对象 ID。
    # 此操作不可撤销；批量回执必须确认所有请求 ID。
    # @param ids [Integer, String, Array<Integer, String>] 一个或多个正整数 ID
    # @return [Integer] 首个删除对象的 ID
    def delete(ids)
      requested = normalized_ids(ids)
      response_ids(delete_raw(requested), expected: requested).first
    end

    # 按稳定业务身份创建或更新一个对象。
    # 通用 CRUD 不提供跨进程原子性；监控业务使用对应的 reconcile/upsert 方法。
    # @param data [Hash] 包含 identify 字段的原生属性
    # @return [Integer]
    def create_or_update(data)
      attributes = data.deep_symbolize_keys
      id = get_id(**identity_filter(attributes))
      id ? update(attributes.merge(key.to_sym => id)) : create(attributes)
    end

    # 仅在请求属性有变化时更新；无条件写入使用 update_raw。
    # @param data [Hash] 包含资源 ID 的原生属性，省略字段不参与比较
    # @return [Integer]
    # @raise [ProtocolError] 写入回执未确认请求 ID
    def update(data)
      attributes = data.deep_symbolize_keys
      id = attributes[key.to_sym]
      raise Invalid, "#{key} is required" if id.blank?

      normalized_ids([id])

      current = dump_by_id(key.to_sym => id).find { |item| item.fetch(key).to_s == id.to_s }
      return id.to_i if current && attributes_match?(current, attributes)

      response_id(update_raw([attributes]), expected: [id])
    end

    # 按业务标识查询完整对象。
    # @param data [Hash] 包含 identify 指定的业务标识
    # @return [Array<Hash>]
    def get_full_data(data)
      get_raw(filter: identity_filter(data), output: "extend")
    end

    # 按对象 ID 查询完整对象。
    # @param data [Hash] 包含 key 指定的 ID 字段
    # @return [Array<Hash>]
    def dump_by_id(data)
      attributes = data.deep_symbolize_keys
      id = attributes[key.to_sym]
      raise Invalid, "#{key} is required" if id.blank?

      get_raw(filter: { key.to_sym => id }, output: "extend")
    end

    # @return [Hash] 业务标识到原生字符串 ID 的映射
    # @raise [Conflict] 多个资源具有相同业务标识
    def all
      get_raw(output: "extend").each_with_object({}) do |item, result|
        name = item.fetch(identify)
        raise Conflict, "multiple #{method_name} objects share the same identity" if result.key?(name)

        result[name] = item.fetch(key)
      end
    end

    # 精确查找唯一资源，空结果返回 nil，多个结果拒绝任意选择。
    # @param data [Hash] 包含 identify 字段的精确过滤条件
    # @return [Integer, nil]
    def get_id(data)
      attributes = data.deep_symbolize_keys
      name = attributes[identify.to_sym]
      raise Invalid, "#{identify} not supplied in call to get_id" if name.nil?

      matches = get_raw(filter: attributes, output: [key, identify]).select do |item|
        item[identify].to_s == name.to_s
      end
      raise Conflict, "multiple #{method_name} objects match the requested identity" if matches.length > 1

      response_identifier(matches.first[key]) if matches.first
    end

    # 查找或创建单个对象，不隐含更新已有对象。
    # @param data [Hash] 创建属性及 identify 指定的业务标识
    # @return [Integer] 已存在或新创建对象的 ID
    def get_or_create(data)
      get_id(**identity_filter(data)) || create(data)
    end

    # @return [Hash] 精确查询条件，复合身份由资源类覆盖
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      { identify.to_sym => attributes.fetch(identify.to_sym) }
    end

    # @param data [Hash] 原生 *.get 参数；调用方负责授权和资源边界
    # @return [Object] 原始查询响应
    def get_raw(data)
      @client.api_request(method: "#{method_name}.get", params: data)
    end

    # @param data [Hash, Array<Hash>] 原生 *.create 参数，不执行高层业务校验
    # @return [Object] 原始创建响应，调用方负责核对回执
    def create_raw(data)
      @client.api_request(method: "#{method_name}.create", params: data)
    end

    # @param data [Hash, Array<Hash>] 原生 *.update 参数，不执行高层业务校验
    # @return [Object] 原始更新响应，调用方负责核对回执
    def update_raw(data)
      @client.api_request(method: "#{method_name}.update", params: data)
    end

    # @param data [Array<Integer, String>] 原生 *.delete ID 集合
    # @return [Object] 原始删除响应，调用方负责核对回执
    def delete_raw(data)
      @client.api_request(method: "#{method_name}.delete", params: data)
    end

    private

    def validate_boolean!(value, name)
      raise Invalid, "#{name} must be true or false" unless value == true || value == false
    end

    def integer_attribute(value, name)
      unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A[+-]?\d+\z/))
        raise Invalid, "#{name} must be an integer"
      end

      value.is_a?(Integer) ? value : Integer(value, 10)
    end

    def normalized_ids(values, allow_empty: false)
      ids = Array.wrap(values).map do |value|
        id = integer_attribute(value, keys)
        raise Invalid, "#{keys} must be positive integers" unless id.positive?

        id.to_s
      end.uniq
      raise Invalid, "#{keys} are required" if ids.empty? && !allow_empty

      ids
    end

    # API 数字字符串可与整数比较，nil 和布尔值保留各自语义。
    def normalized_attributes(attributes)
      attributes.deep_symbolize_keys.deep_transform_values do |value|
        value.is_a?(Numeric) ? value.to_s : value
      end
    end

    def attributes_match?(current, desired)
      actual = normalized_attributes(current)
      expected = normalized_attributes(desired)
      actual.slice(*expected.keys) == expected
    end

    def response_identifier(value, id_field = key)
      unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A[0-9]+\z/))
        raise ProtocolError, "invalid #{method_name} response: #{id_field} must be a positive integer"
      end

      id = value.to_i
      raise ProtocolError, "invalid #{method_name} response: #{id_field} must be positive" unless id.positive?

      id
    end

    def response_ids(result, id_field = keys, expected: nil)
      values = result[id_field] if result.is_a?(Hash)
      unless values.is_a?(Array) && values.any?
        raise ProtocolError, "invalid #{method_name} response: #{id_field} must be a nonempty array"
      end

      ids = values.map { |value| response_identifier(value, id_field) }
      if ids.uniq != ids || (expected && ids.sort != expected.map { |id| response_identifier(id) }.sort)
        raise ProtocolError, "invalid #{method_name} response: #{id_field} do not confirm the requested objects"
      end

      ids
    end

    def response_id(result, id_field = keys, expected: nil)
      ids = response_ids(result, id_field, expected: expected)
      raise ProtocolError, "invalid #{method_name} response: expected one #{key}" unless ids.one?

      ids.first
    end
  end
end
