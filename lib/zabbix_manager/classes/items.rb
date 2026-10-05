# frozen_string_literal: true

class ZabbixManager
  # 监控项查询与写入；通用 CRUD 使用名称，专用 upsert 使用 hostid + key_。
  class Items < Resource
    DEFAULT_OPTIONS = {
      delay: "1m",
      history: "1h",
      status: 0,
      value_type: 3
    }.freeze
    ITEM_TYPES = [0, 2, 3, 5, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22].freeze
    REQUIRED_INTERFACE_TYPES = [0, 12, 16, 17, 20].freeze
    REQUIRED_PARAMS_TYPES = [11, 13, 14, 15, 21, 22].freeze

    # 返回监控项对应的 Zabbix API 模块名。
    #
    # @return [String]
    def method_name
      "item"
    end

    # 返回创建监控项时的克制默认值。
    #
    # @return [Hash]
    def default_options
      DEFAULT_OPTIONS.dup
    end

    # 使用主机和名称组成通用 CRUD 的查询边界。
    #
    # @param data [Hash] 包含 name 和 hostid 的监控项属性
    # @raise [ApiError] Zabbix API 明确返回业务错误
    # @raise [TransportError] HTTP 或网络请求失败，可能无法确认远端结果
    # @return [Hash] 名称和所属主机组成的精确过滤条件
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      { name: attributes.fetch(:name), hostid: attributes.fetch(:hostid) }
    end

    # 查询主机监控项，可按稳定 key 集合过滤并选择关联对象。
    # @return [Array<Hash>]
    def for_host(hostid, keys: nil, output: "extend", select_preprocessing: nil, select_tags: nil)
      positive_id_attribute(hostid, "hostid")

      params = { hostids: hostid, output: output }
      params[:filter] = { key_: keys } if keys.present?
      params[:selectPreprocessing] = select_preprocessing if select_preprocessing
      params[:selectTags] = select_tags if select_tags
      response_objects(@client.api_request(method: "item.get", params: params))
    end

    # 按主机和稳定 key 查询唯一监控项。
    # @return [Hash, nil]
    def find_by_key(hostid:, key:)
      result = for_host(hostid, keys: key, output: "extend", select_preprocessing: "extend")
      index_items(result, hostid, [key])[key]
    end

    # 按 hostid + key_ 幂等创建或更新监控项。
    # @return [Integer]
    def upsert_by_key(data)
      apply_item(*plan_item(validate_item!(data)))
    end

    # 先校验整批数据，再按稳定 key 逐项幂等写入。
    # @yieldparam effective [Array<Hash>] 合并已有配置或创建默认值后的有效属性；块失败时不写入
    # @return [Array<Integer>]
    def upsert_many(collection)
      items = Array(collection).map { |data| validate_item!(data) }
      identities = items.map { |item| [positive_id_attribute(item[:hostid], "hostid").to_s, item[:key_]] }
      duplicate = identities.tally.find { |_identity, count| count > 1 }&.first
      raise Invalid, "duplicate hostid + key_ identity #{duplicate.join(":")}" if duplicate

      existing = batch_items(items)
      plans = items.map do |item|
        identity = [positive_id_attribute(item[:hostid], "hostid").to_s, item[:key_]]
        plan_item(item, existing[identity])
      end
      if block_given?
        effective = plans.map do |attributes, current|
          if current && !%w[type value_type].all? { |field| current.key?(field) }
            raise ProtocolError, "item.get must include type and value_type for effective configuration validation"
          end

          current ? current.deep_symbolize_keys.merge(attributes).deep_dup : attributes.deep_dup
        end
        yield effective
      end
      plans.map { |attributes, current| apply_item(attributes, current) }
    end

    # 批量启用或停用监控项。
    # @return [Array<Integer>]
    def set_status(hostid:, itemids:, enabled:)
      validate_boolean!(enabled, "enabled")
      ids = normalized_ids(itemids)
      verify_host_ownership!(hostid, ids)
      result = @client.api_request(
        method: "item.update",
        params: ids.map { |itemid| { itemid: itemid, status: enabled ? 0 : 1 } }
      )
      response_ids(result, expected: ids)
    end

    # 批量删除明确指定的监控项。
    # @return [Array<Integer>]
    def delete_many(hostid:, itemids:)
      ids = normalized_ids(itemids)
      verify_host_ownership!(hostid, ids)
      result = @client.api_request(method: "item.delete", params: ids)
      response_ids(result, expected: ids)
    end

    # 返回主机中可能表示接口流量的已启用监控项。
    # 方向和接口精确匹配由 Monitoring 业务层负责。
    # @return [Array<Hash>]
    def monitored_traffic_candidates(hostid)
      positive_id_attribute(hostid, "hostid")
      @client.api_request(
        method: "item.get",
        params: {
          hostids: [hostid],
          monitored: true,
          output: %w[itemid hostid name key_ type snmp_oid value_type status units],
          selectPreprocessing: "extend",
          sortfield: "name",
          sortorder: "ASC"
        }
      )
    end

    # 按主机接口幂等创建或更新 DNS 解析监控项，并返回监控项 ID。
    # DNS 名称会进入 item key，因此拒绝可能改变 key 参数结构的分隔符。
    # @return [Integer]
    def upsert_dns_item(hostid:, interfaceid:, dns_name:)
      name = dns_name.to_s.strip
      raise Invalid, "dns_name is required" if name.blank?
      raise Invalid, "dns_name contains unsupported item key delimiters" if name.match?(/[\[\],]/)

      upsert_by_key(
        hostid: hostid,
        interfaceid: interfaceid,
        name: "【DNS域名解析监控】#{name}",
        key_: "net.dns.record[,#{name},A,2,2]",
        type: 0,
        value_type: 1,
        delay: "1m",
        history: "90d",
        timeout: "3s"
      )
    end

    private

    # 每个主机只读取一次期望 key 集合，全部发现和校验完成后才开始写入。
    def batch_items(items)
      groups = items.group_by { |item| positive_id_attribute(item[:hostid], "hostid").to_s }
      ids = {}
      groups.each_with_object({}) do |(owner, definitions), result|
        hostid = definitions.first[:hostid]
        keys = definitions.map { |item| item[:key_] }
        rows = for_host(hostid, keys: keys, select_preprocessing: "extend")
        index_items(rows, hostid, keys).each do |key, row|
          id = response_identifier(row["itemid"])
          raise ProtocolError, "item.get returned duplicate item IDs across hosts" if ids.key?(id)

          ids[id] = true
          result[[owner, key]] = row
        end
      end
    end

    # 不信任服务端过滤器：返回项必须位于所请求的主机和 key 集合中。
    def index_items(rows, hostid, keys)
      owner = positive_id_attribute(hostid, "hostid")
      requested = keys.to_h { |key| [key, true] }
      ids = {}
      response_objects(rows).each_with_object({}) do |row, result|
        id = response_identifier(row["itemid"])
        unless response_identifier(row["hostid"], "hostid") == owner && requested.key?(row["key_"])
          raise ProtocolError, "item.get returned an item outside the requested host and keys"
        end
        raise Conflict, "multiple items use the same key on host #{hostid}" if result.key?(row["key_"])
        raise ProtocolError, "item.get returned duplicate item IDs" if ids.key?(id)

        ids[id] = true
        result[row["key_"]] = row
      end
    end

    # 创建必填字段必须在整批写入开始前校验。
    def plan_item(attributes, current = find_by_key(hostid: attributes[:hostid], key: attributes[:key_]))
      validate_item_type!(attributes[:type]) if attributes.key?(:type)
      response_identifier(current["itemid"]) if current
      unless current
        attributes = default_options.merge(attributes)
        validate_create_item!(attributes)
      end
      [attributes, current]
    end

    def apply_item(attributes, current)
      if current
        itemid = current.fetch("itemid")
        result = @client.api_request(method: "item.update", params: attributes.except(:hostid).merge(itemid: itemid))
        response_id(result, expected: [itemid])
      else
        result = @client.api_request(method: "item.create", params: attributes)
        response_id(result)
      end
    end

    # 规范化并校验幂等写入所需字段。
    # @return [Hash]
    # @api private
    def validate_item!(data)
      raise Invalid, "item must be a hash" unless data.is_a?(Hash)

      attributes = data.deep_symbolize_keys.deep_dup
      positive_id_attribute(attributes[:hostid], "hostid")
      %i[key_ name].each do |field|
        unless attributes[field].is_a?(String) && attributes[field].present?
          raise Invalid, "#{field} must be a non-empty string"
        end
      end

      attributes
    end

    # 校验 item.create 的通用必填字段和 SNMP 条件字段。
    def validate_create_item!(attributes)
      raise Invalid, "type is required when creating an item" if attributes[:type].blank?
      raise Invalid, "value_type is required when creating an item" if attributes[:value_type].blank?

      type = validate_item_type!(attributes[:type])

      if REQUIRED_INTERFACE_TYPES.include?(type) && attributes[:interfaceid].blank?
        raise Invalid, "interfaceid is required for item type #{type}"
      end
      if REQUIRED_PARAMS_TYPES.include?(type) && attributes[:params].blank?
        raise Invalid, "params is required for item type #{type}"
      end

      raise Invalid,
            "master_itemid is required for a dependent item" if type == 18 && attributes[:master_itemid].blank?
      raise Invalid, "url is required for an HTTP item" if type == 19 && attributes[:url].blank?
      return unless type == 20

      raise Invalid, "snmp_oid is required for an SNMP item" if attributes[:snmp_oid].blank?
    end

    def validate_item_type!(value)
      type = integer_attribute(value, "type")
      raise Invalid, "unsupported item type #{type}" unless ITEM_TYPES.include?(type)

      type
    end

    # 回查监控项归属，阻止共享高权限令牌跨主机修改。
    def verify_host_ownership!(hostid, ids)
      positive_id_attribute(hostid, "hostid")

      result = @client.api_request(
        method: "item.get", params: { hostids: hostid, itemids: ids, output: ["itemid"] }
      )
      owned_ids = response_objects(result).map { |item| response_identifier(item["itemid"]).to_s }
      foreign_ids = ids - owned_ids
      raise Conflict, "items do not belong to host #{hostid}: #{foreign_ids.join(", ")}" if foreign_ids.any?
    end
  end
end
