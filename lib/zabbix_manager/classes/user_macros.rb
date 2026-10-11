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
      { macro: attributes.fetch(:macro), hostid: normalized_id_attribute(attributes.fetch(:hostid), "hostid") }
    end

    # @raise [ProtocolError] 远端宏名称、归属或 ID 无效
    # @raise [Conflict] 宏身份不唯一
    # @return [Integer, nil] 唯一主机宏 ID
    def get_id(data)
      attributes = identity_filter(data)
      unique_macro_id(get_full_data(attributes), "hostmacroid", attributes)
    end

    # @raise [ProtocolError] 远端宏名称或 ID 无效
    # @raise [Conflict] 宏身份不唯一
    # @return [Integer, nil] 唯一全局宏 ID
    def get_id_global(data)
      attributes = data.deep_symbolize_keys
      identity = { macro: attributes.fetch(:macro) }
      unique_macro_id(get_full_data_global(identity), "globalmacroid", identity)
    end

    # @return [Array<Hash>] 主机宏查询结果
    def get_full_data(data)
      attributes = data.deep_symbolize_keys
      params = { filter: attributes.except(:hostid) }
      if attributes.key?(:hostid)
        params[:hostids] = normalized_id_attribute(attributes[:hostid], "hostid")
      end
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
      update_macro("update", data, "hostmacroid")
    end

    # @return [Integer, nil] 更新全局宏 ID
    def update_global(data)
      update_macro("updateglobal", data, "globalmacroid")
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

    def update_macro(operation, data, id_field)
      attributes = data.deep_symbolize_keys
      id = attributes[id_field.to_sym] = normalized_id_attribute(attributes[id_field.to_sym], id_field)
      write_macro(operation, attributes, "#{id_field}s", expected: [id])
    end

    # 名称过滤器和 hostids 只是远端查询条件，不能代替本地身份核对。
    def unique_macro_id(result, id_field, identity)
      response_objects(result).each do |macro|
        response_identifier(macro[id_field], id_field)
        unless macro["macro"].is_a?(String) && macro["macro"] == identity[:macro]
          raise ProtocolError, "usermacro.get returned an unexpected macro identity"
        end
        next unless identity.key?(:hostid)

        unless response_identifier(macro["hostid"], "hostid") == identity[:hostid].to_i
          raise ProtocolError, "usermacro.get returned a macro outside the requested host"
        end
      end
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
