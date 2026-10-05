# frozen_string_literal: true

class ZabbixManager
  # 主机宏由 hostid + macro 唯一定位，全局宏由 macro 唯一定位。
  class UserMacros < Resource
    # @return [String] 宏业务标识
    def identify
      "macro"
    end

    # @return [String] API 模块名
    def method_name
      "usermacro"
    end

    # @return [String] 主机宏 ID 字段
    def key
      "hostmacroid"
    end

    # @return [Hash] 主机宏复合身份
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      { macro: attributes.fetch(:macro), hostid: attributes.fetch(:hostid) }
    end

    # @return [Integer, nil] 唯一主机宏 ID
    def get_id(data)
      attributes = identity_filter(data)
      unique_macro_id(get_full_data(attributes), "hostmacroid")
    end

    # @return [Integer, nil] 唯一全局宏 ID
    def get_id_global(data)
      attributes = data.deep_symbolize_keys
      unique_macro_id(get_full_data_global(macro: attributes.fetch(:macro)), "globalmacroid")
    end

    # @return [Array<Hash>] 主机宏查询结果
    def get_full_data(data)
      attributes = data.deep_symbolize_keys
      params = { filter: attributes.except(:hostid) }
      params[:hostids] = attributes[:hostid] if attributes.key?(:hostid)
      get_raw(params)
    end

    # @return [Array<Hash>] 全局宏查询结果
    def get_full_data_global(data)
      get_raw(globalmacro: true, filter: data.deep_symbolize_keys)
    end

    # @return [Integer, nil] 新建主机宏 ID
    def create(data)
      write_macro("create", data, "hostmacroids")
    end

    # @return [Integer, nil] 新建全局宏 ID
    def create_global(data)
      write_macro("createglobal", data, "globalmacroids")
    end

    # @return [Integer, nil] 删除主机宏 ID
    def delete(ids)
      requested = normalized_ids(ids)
      write_macro("delete", requested, "hostmacroids", expected: requested)
    end

    # @return [Integer, nil] 删除全局宏 ID
    def delete_global(ids)
      requested = normalized_ids(ids)
      write_macro("deleteglobal", requested, "globalmacroids", expected: requested)
    end

    # @return [Integer, nil] 更新主机宏 ID
    def update(data)
      write_macro("update", data, "hostmacroids", expected: [data.with_indifferent_access[:hostmacroid]])
    end

    # @return [Integer, nil] 更新全局宏 ID
    def update_global(data)
      write_macro("updateglobal", data, "globalmacroids", expected: [data.with_indifferent_access[:globalmacroid]])
    end

    # @return [Integer, nil] 已存在或新建全局宏 ID
    def get_or_create_global(data)
      get_id_global(data) || create_global(data)
    end

    # @return [Integer, nil] 新建或更新全局宏 ID
    def create_or_update_global(data)
      attributes = data.deep_symbolize_keys
      id = get_id_global(attributes)
      id ? update_global(attributes.merge(globalmacroid: id)) : create_global(attributes)
    end

    private

    def unique_macro_id(result, id_field)
      response_objects(result)
      raise Conflict, "multiple macros match the requested identity" if result.length > 1

      response_identifier(result.first[id_field], id_field) if result.first
    end

    def write_macro(operation, params, id_field, expected: nil)
      normalized_ids(expected) if expected
      result = @client.api_request(method: "usermacro.#{operation}", params: params)
      expected ? response_ids(result, id_field, expected: expected).first : response_id(result, id_field)
    end
  end
end
