# frozen_string_literal: true

class ZabbixManager
  # 触发器与依赖对账；受管身份使用标签，创建结果不明时只回读、不重放。
  class Triggers < Resource
    DEFAULT_UNCERTAIN_WRITE_DELAYS = [0, 0.25, 1, 2].freeze
    MAX_MANAGED_KEY_LENGTH = 200
    # 返回触发器对应的 Zabbix API 模块名。
    #
    # @return [String]
    def method_name
      "trigger"
    end

    # 使用描述作为通用 CRUD 的业务标识。
    #
    # @return [String]
    def identify
      "description"
    end

    # 按触发器 ID 查询完整对象及关联项和函数。
    #
    # @param data [Hash] 包含目标触发器 ID 字段及其值
    # @raise [ApiError] Zabbix API 明确返回业务错误
    # @raise [TransportError] HTTP 或网络请求失败，可能无法确认远端结果
    # @return [Array<Hash>] 匹配的触发器及其关联对象
    def dump_by_id(data)
      @client.api_request(
        method: "trigger.get",
        params: {
          filter: {
            key.to_sym => data[key.to_sym]
          },
          output: "extend",
          selectItems: "extend",
          selectFunctions: "extend"
        }
      )
    end

    # 查询主机触发器，并按需返回监控项、函数、依赖和标签。
    # @return [Array<Hash>]
    def for_host(hostid, output: "extend", select_items: nil, select_functions: nil,
                 select_dependencies: nil, select_tags: nil, filter: nil)
      raise Invalid, "hostid is required" if hostid.blank?

      params = { hostids: hostid, output: output }
      params[:selectItems] = select_items if select_items
      params[:selectFunctions] = select_functions if select_functions
      params[:selectDependencies] = select_dependencies if select_dependencies
      params[:selectTags] = select_tags if select_tags
      params[:filter] = filter if filter.present?
      @client.api_request(method: "trigger.get", params: params)
    end

    # 按主机、描述和可选标签查询唯一触发器。
    # @return [Hash, nil]
    def find_for_host(hostid:, description:, tags: nil)
      params = {
        hostids: hostid,
        filter: { description: description },
        output: ["triggerid", "description"],
        selectTags: "extend"
      }
      params[:tags] = tags if tags.present?
      result = @client.api_request(
        method: "trigger.get",
        params: params
      )
      raise Conflict, "multiple triggers match #{description} on host #{hostid}" if result.length > 1

      result.first
    end

    # 按管理标签查询唯一触发器。
    # 展开表达式并读取依赖，供不确定写入后的完整期望状态核对。
    # @param hostid [Integer, String] 触发器所属主机
    # @param managed_key [String] 稳定、非秘密的受管身份
    # @return [Hash, nil]
    def find_managed_for_host(hostid:, managed_key:)
      result = @client.api_request(
        method: "trigger.get",
        params: {
          hostids: hostid,
          tags: [{ tag: "zabbix_manager_id", value: managed_key, operator: 1 }],
          output: "extend",
          expandExpression: true,
          selectDependencies: ["triggerid"],
          selectTags: "extend"
        }
      )
      raise Conflict, "multiple triggers use managed key #{managed_key}" if result.length > 1

      result.first
    end

    # 按触发器 ID 查询唯一对象，并可返回当前依赖集合。
    # @return [Hash, nil]
    def find_by_id(triggerid, select_dependencies: nil)
      id = normalized_ids([triggerid]).first
      params = { triggerids: id, output: "extend" }
      params[:selectDependencies] = select_dependencies if select_dependencies
      result = @client.api_request(method: "trigger.get", params: params)
      raise Conflict, "multiple triggers use triggerid #{id}" if result.length > 1

      result.first
    end

    # 按稳定管理键串行创建或更新主机触发器。
    # 可通过 Client 的 upsert_lock 接入跨进程锁。
    # @return [Integer]
    def upsert_for_host(data)
      attributes = data.deep_symbolize_keys
      lock_key = "trigger:#{attributes[:hostid]}:#{attributes[:managed_key] || attributes[:description]}"
      @client.with_upsert_lock(lock_key) { perform_upsert_for_host(attributes) }
    end

    # 批量启用或停用触发器。
    # @return [Array<Integer>]
    def set_status(hostid:, triggerids:, enabled:)
      validate_boolean!(enabled, "enabled")
      ids = normalized_ids(triggerids)
      verify_host_ownership!(hostid, ids)
      result = @client.api_request(
        method: "trigger.update",
        params: ids.map { |triggerid| { triggerid: triggerid, status: enabled ? 0 : 1 } }
      )
      response_ids(result, expected: ids)
    end

    # 批量删除明确指定的触发器。
    # @return [Array<Integer>]
    def delete_many(hostid:, triggerids:)
      ids = normalized_ids(triggerids)
      verify_host_ownership!(hostid, ids)
      result = @client.api_request(method: "trigger.delete", params: ids)
      response_ids(result, expected: ids)
    end

    # 使用 trigger.update 完整替换一个触发器的依赖集合。
    # 传入空集合可清除依赖，返回被更新的触发器 ID。
    # @return [Integer]
    def replace_dependencies(hostid:, triggerid:, depends_on:, allow_cross_host_dependencies: false)
      validate_boolean!(allow_cross_host_dependencies, "allow_cross_host_dependencies")
      id = normalized_ids([triggerid]).first
      dependency_ids = normalized_ids(depends_on, allow_empty: true)
      dependencies = dependency_ids.map { |value| { triggerid: value } }
      raise Invalid, "trigger cannot depend on itself" if dependencies.any? { |item| item[:triggerid] == id }

      verify_host_ownership!(hostid, [id])
      verify_host_ownership!(hostid, dependency_ids) if dependency_ids.any? && !allow_cross_host_dependencies
      @client.with_upsert_lock("trigger-dependencies:#{id}") { update_dependencies(id, dependencies) }
    end

    # 在保留现有依赖的前提下，为触发器追加一个或多个依赖。
    # 读改写过程按触发器 ID 加锁，跨进程可通过 Client 的 upsert_lock 协调。
    # @return [Integer]
    def add_dependencies(hostid:, triggerid:, depends_on:, allow_cross_host_dependencies: false)
      validate_boolean!(allow_cross_host_dependencies, "allow_cross_host_dependencies")
      id = normalized_ids([triggerid]).first
      additions = normalized_ids(depends_on)
      raise Invalid, "trigger cannot depend on itself" if additions.include?(id)

      verify_host_ownership!(hostid, [id])

      @client.with_upsert_lock("trigger-dependencies:#{id}") do
        current = find_by_id(id, select_dependencies: ["triggerid"])
        raise ApiError, "Zabbix trigger #{id} was not found" unless current

        existing = Array(current["dependencies"]).filter_map { |dependency| dependency["triggerid"] }
        dependency_ids = (existing + additions).uniq
        unless allow_cross_host_dependencies
          verify_host_ownership!(hostid, dependency_ids)
        end
        dependencies = dependency_ids.map { |value| { triggerid: value } }
        update_dependencies(id, dependencies)
      end
    end

    # 执行已加锁的触发器幂等写入。
    # @return [Integer]
    # @api private
    private def perform_upsert_for_host(data)
      attributes = data.deep_symbolize_keys
      hostid = attributes.delete(:hostid)
      managed_key = attributes.delete(:managed_key)&.to_s
      raise Invalid, "hostid is required" if hostid.blank?
      raise Invalid, "description is required" if attributes[:description].blank?
      raise Invalid, "expression is required" if attributes[:expression].blank?

      if managed_key.present?
        raise Invalid, "managed_key is too long" if managed_key.length > MAX_MANAGED_KEY_LENGTH

        attributes[:tags] = Array(attributes[:tags]).reject do |tag|
          tag[:tag].to_s == "zabbix_manager_id" || tag["tag"].to_s == "zabbix_manager_id"
        end
        attributes[:tags] << { tag: "zabbix_manager_id", value: managed_key }
        current = find_managed_for_host(hostid: hostid, managed_key: managed_key)
      else
        ownership_tags = Array(attributes[:tags]).select do |tag|
          tag[:tag].to_s == "managed_by" || tag["tag"].to_s == "managed_by"
        end
        current = find_for_host(hostid: hostid, description: attributes[:description], tags: ownership_tags)
      end
      if current
        triggerid = current["triggerid"]
        response_identifier(triggerid)
        attributes[:tags] = merge_tags(current["tags"], attributes[:tags]) if attributes[:tags]
        result = @client.api_request(method: "trigger.update", params: attributes.merge(triggerid: triggerid))
        response_id(result, expected: [triggerid])
      else
        create_managed_trigger(hostid, managed_key, attributes)
      end
    end

    # 创建触发器；响应丢失时按管理键回读并核对期望状态。
    # @return [Integer]
    # @api private
    private def create_managed_trigger(hostid, managed_key, attributes)
      result = @client.api_request(method: "trigger.create", params: attributes)
      response_id(result)
    rescue TransportError => original_error
      if managed_key.present?
        current = recover_created_trigger(hostid: hostid, managed_key: managed_key, attributes: attributes)
      end
      return response_identifier(current["triggerid"]) if current

      raise ResultUnknown,
            "trigger create result is unknown; inspect managed key #{managed_key.inspect} before retrying: " \
            "#{original_error.message}"
    end

    # 对结果不确定的创建执行短暂退避回读，不重放写请求。
    # @return [Hash, nil]
    # @api private
    private def recover_created_trigger(hostid:, managed_key:, attributes:)
      delays = @client.options.fetch(:uncertain_write_delays, DEFAULT_UNCERTAIN_WRITE_DELAYS)
      delays.each do |delay|
        sleep(delay) if delay.positive?
        current = find_managed_for_host(hostid: hostid, managed_key: managed_key)
        if current && recovered_trigger_matches?(current, attributes)
          response_identifier(current["triggerid"])
          return current
        end
      rescue ApiError, TransportError
        next
      end
      nil
    end

    private def recovered_trigger_matches?(current, attributes)
      desired_tags = Array(attributes[:tags]).map(&:deep_symbolize_keys)
      actual_tags = Array(current["tags"]).map(&:deep_symbolize_keys)
      attributes_match?(current, attributes.except(:tags)) && (desired_tags - actual_tags).empty?
    end

    # 合并受管标签，同时保留调用方未覆盖的运维标签。
    # @return [Array<Hash>]
    # @api private
    private def merge_tags(existing_tags, desired_tags)
      desired = Array(desired_tags).map(&:deep_symbolize_keys)
      desired_names = desired.map { |tag| tag.fetch(:tag).to_s }
      retained = Array(existing_tags).map(&:deep_symbolize_keys).reject do |tag|
        desired_names.include?(tag[:tag].to_s)
      end
      retained + desired
    end

    # 回查触发器归属，阻止共享高权限令牌跨主机修改。
    private def verify_host_ownership!(hostid, ids)
      raise Invalid, "hostid is required" if hostid.blank?

      result = @client.api_request(
        method: "trigger.get", params: { hostids: hostid, triggerids: ids, output: ["triggerid"] }
      )
      owned_ids = result.map { |trigger| trigger.fetch("triggerid").to_s }
      foreign_ids = ids - owned_ids
      raise Conflict, "triggers do not belong to host #{hostid}: #{foreign_ids.join(", ")}" if foreign_ids.any?
    end

    # 使用官方 trigger.update 完整写入依赖集合。
    private def update_dependencies(triggerid, dependencies)
      result = @client.api_request(
        method: "trigger.update", params: { triggerid: triggerid, dependencies: dependencies }
      )
      response_id(result, expected: [triggerid])
    end
  end
end
