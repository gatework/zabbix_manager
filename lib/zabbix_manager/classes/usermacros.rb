# frozen_string_literal: true

class ZabbixManager
  class Usermacros < Basic
    # 返回用于唯一识别用户宏的业务字段名。
    #
    # @return [String] 用户宏的业务标识字段名
    def identify
      "macro"
    end

    # 返回 Zabbix API 中用户宏对象的方法名前缀。
    #
    # @return [String] 用户宏对象的方法名前缀
    def method_name
      "usermacro"
    end

    # 按宏名称及主机条件查询主机宏 ID。
    #
    # @param data [Hash] 包含 macro 及可选主机过滤条件
    # @raise [ApiError] Zabbix API 调用失败或缺少标识字段时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 主机宏 ID，未找到时返回 nil
    def get_id(data)
      log "[DEBUG] Call get_id with parameters: #{data.inspect}"

      # 兼容字符串键输入。
      data = data.deep_symbolize_keys if data.key?(identify)
      # 标识字段缺失时拒绝继续查询。
      name = data[identify.to_sym]
      raise Invalid, "#{identify} not supplied in call to get_id" if name.nil?

      result = request(data, "usermacro.get", "hostmacroid")

      !result.empty? && result[0].key?("hostmacroid") ? result[0]["hostmacroid"].to_i : nil
    end

    # 按宏名称查询全局宏 ID。
    #
    # @param data [Hash] 包含 macro 的全局宏过滤条件
    # @raise [ApiError] Zabbix API 调用失败或缺少标识字段时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 全局宏 ID，未找到时返回 nil
    def get_id_global(data)
      log "[DEBUG] Call get_id_global with parameters: #{data.inspect}"

      # 兼容字符串键输入。
      data = data.deep_symbolize_keys if data.key?(identify)
      # 标识字段缺失时拒绝继续查询。
      name = data[identify.to_sym]
      raise Invalid, "#{identify} not supplied in call to get_id_global" if name.nil?

      result = request(data, "usermacro.get", "globalmacroid")

      !result.empty? && result[0].key?("globalmacroid") ? result[0]["globalmacroid"].to_i : nil
    end

    # 获取匹配主机宏的完整数据。
    #
    # @param data [Hash] 主机宏过滤条件
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Array<Hash>] 匹配的主机宏数据
    def get_full_data(data)
      log "[DEBUG] Call get_full_data with parameters: #{data.inspect}"

      request(data, "usermacro.get", "hostmacroid")
    end

    # 获取匹配全局宏的完整数据。
    #
    # @param data [Hash] 全局宏过滤条件
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Array<Hash>] 匹配的全局宏数据
    def get_full_data_global(data)
      log "[DEBUG] Call get_full_data_global with parameters: #{data.inspect}"

      request(data, "usermacro.get", "globalmacroid")
    end

    # 创建主机宏并返回首个新建宏的 ID。
    #
    # @param data [Hash] 包含 hostid、macro 和 value
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 新建主机宏的 ID
    def create(data)
      request(data, "usermacro.create", "hostmacroids")
    end

    # 创建全局宏并返回首个新建宏的 ID。
    #
    # @param data [Hash] 包含 macro 和 value
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 新建全局宏的 ID
    def create_global(data)
      request(data, "usermacro.createglobal", "globalmacroids")
    end

    # 删除指定主机宏并返回首个已删除宏的 ID。
    #
    # @param data [Hash, Integer, String] 要删除的 hostmacroid
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已删除主机宏的 ID
    def delete(data)
      data_delete = [data]
      request(data_delete, "usermacro.delete", "hostmacroids")
    end

    # 删除指定全局宏并返回首个已删除宏的 ID。
    #
    # @param data [Hash, Integer, String] 要删除的 globalmacroid
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已删除全局宏的 ID
    def delete_global(data)
      data_delete = [data]
      request(data_delete, "usermacro.deleteglobal", "globalmacroids")
    end

    # 更新主机宏并返回首个已更新宏的 ID。
    #
    # @param data [Hash] 包含 hostmacroid 及待更新字段
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已更新主机宏的 ID
    def update(data)
      request(data, "usermacro.update", "hostmacroids")
    end

    # 更新全局宏并返回首个已更新宏的 ID。
    #
    # @param data [Hash] 包含 globalmacroid 及待更新字段
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 已更新全局宏的 ID
    def update_global(data)
      request(data, "usermacro.updateglobal", "globalmacroids")
    end

    # 按主机和宏名获取主机宏，不存在时创建。
    #
    # @param data [Hash] 包含 macro、hostid 及创建所需字段
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer] 主机宏 ID
    def get_or_create(data)
      log "[DEBUG] Call get_or_create with parameters: #{data.inspect}"

      unless (id = get_id(macro: data[:macro], hostid: data[:hostid]))
        id = create(data)
      end
      id
    end

    # 按宏名获取全局宏，不存在时创建。
    #
    # @param data [Hash] 包含 macro 及创建所需字段
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer] 全局宏 ID
    def get_or_create_global(data)
      log "[DEBUG] Call get_or_create_global with parameters: #{data.inspect}"

      unless (id = get_id_global(macro: data[:macro], hostid: data[:hostid]))
        id = create_global(data)
      end
      id
    end

    # 按主机和宏名创建或更新主机宏。
    #
    # @param data [Hash] 包含 macro、hostid 及宏属性
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer] 主机宏 ID
    def create_or_update(data)
      hostmacroid = get_id(macro: data[:macro], hostid: data[:hostid])
      hostmacroid ? update(data.merge(hostmacroid: hostmacroid)) : create(data)
    end

    # 按宏名创建或更新全局宏。
    #
    # @param data [Hash] 包含 macro 及宏属性
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer] 全局宏 ID
    def create_or_update_global(data)
      globalmacroid = get_id_global(macro: data[:macro], hostid: data[:hostid])
      globalmacroid ? update_global(data.merge(globalmacroid: globalmacroid)) : create_global(data)
    end

    private

      # 统一处理主机宏与全局宏请求，并按不同响应键提取结果。
      #
      # @param data [Hash, Array] Zabbix API 请求参数
      # @param method [String] 要调用的 Zabbix API 方法
      # @param result_key [String] 用于解析主机宏或全局宏结果的字段名
      # @raise [ApiError] Zabbix API 返回业务错误时抛出
      # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
      # @return [Array<Hash>, Integer, nil] 查询结果或变更后的宏 ID
      def request(data, method, result_key)
        # Zabbix 查询与变更接口使用不同的响应格式。
        if method.include?(".get")
          if result_key.include?("global")
            @client.api_request(method: method, params: { globalmacro: true, filter: data })
          else
            @client.api_request(method: method, params: { filter: data })
          end
        else
          result = @client.api_request(method: method, params: data)

          result.key?(result_key) && !result[result_key].empty? ? result[result_key][0].to_i : nil
        end
      end
  end
end
