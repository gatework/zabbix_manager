# frozen_string_literal: true

class ZabbixManager
  class Triggers < Basic
    DEFAULT_UNCERTAIN_WRITE_DELAYS = [0, 0.25, 1, 2].freeze
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
    # @param data [Hash] Should include desired object's key and value
    # @raise [ApiError] Error returned when there is a problem with the Zabbix API call.
    # @raise [TransportError] Error raised when HTTP status from Zabbix Server response is not a 200 OK.
    # @return [Hash]
    def dump_by_id(data)
      log "[DEBUG] Call dump_by_id with parameters: #{data.inspect}"

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
    # @return [Hash, nil]
    def find_managed_for_host(hostid:, managed_key:)
      result = @client.api_request(
        method: "trigger.get",
        params: {
          hostids: hostid,
          tags: [{ tag: "zabbix_manager_id", value: managed_key, operator: 1 }],
          output: ["triggerid", "description"],
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
      ids = normalized_ids(triggerids)
      verify_host_ownership!(hostid, ids)
      result = @client.api_request(
        method: "trigger.update",
        params: ids.map { |triggerid| { triggerid: triggerid, status: enabled ? 0 : 1 } }
      )
      Array(result.fetch("triggerids")).map(&:to_i)
    end

    # 批量删除明确指定的触发器。
    # @return [Array<Integer>]
    def delete_many(hostid:, triggerids:)
      ids = normalized_ids(triggerids)
      verify_host_ownership!(hostid, ids)
      result = @client.api_request(method: "trigger.delete", params: ids)
      Array(result.fetch("triggerids")).map(&:to_i)
    end

    # 使用 trigger.update 完整替换一个触发器的依赖集合。
    # 传入空集合可清除依赖，返回被更新的触发器 ID。
    # @return [Integer]
    def replace_dependencies(hostid:, triggerid:, depends_on:, allow_cross_host_dependencies: false)
      id = normalized_ids([triggerid]).first
      dependency_ids = normalized_ids(depends_on, allow_empty: true)
      dependencies = dependency_ids.map { |value| { triggerid: value } }
      raise Invalid, "trigger cannot depend on itself" if dependencies.any? { |item| item[:triggerid] == id }

      verify_host_ownership!(hostid, [id])
      verify_host_ownership!(hostid, dependency_ids) if dependency_ids.any? && !allow_cross_host_dependencies
      update_dependencies(id, dependencies)
    end

    # 在保留现有依赖的前提下，为触发器追加一个或多个依赖。
    # 读改写过程按触发器 ID 加锁，跨进程可通过 Client 的 upsert_lock 协调。
    # @return [Integer]
    def add_dependencies(hostid:, triggerid:, depends_on:, allow_cross_host_dependencies: false)
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
      legacy_identity_tags = attributes.delete(:legacy_identity_tags)
      raise Invalid, "hostid is required" if hostid.blank?
      raise Invalid, "description is required" if attributes[:description].blank?
      raise Invalid, "expression is required" if attributes[:expression].blank?

      if managed_key.present?
        raise Invalid, "managed_key is too long" if managed_key.length > 200

        attributes[:tags] = Array(attributes[:tags]).reject do |tag|
          tag[:tag].to_s == "zabbix_manager_id" || tag["tag"].to_s == "zabbix_manager_id"
        end
        attributes[:tags] << { tag: "zabbix_manager_id", value: managed_key }
        current = find_managed_for_host(hostid: hostid, managed_key: managed_key)
        if current.nil? && legacy_identity_tags.present?
          current = find_for_host(
            hostid: hostid,
            description: attributes[:description],
            tags: legacy_identity_tags
          )
        end
      else
        ownership_tags = Array(attributes[:tags]).select do |tag|
          tag[:tag].to_s == "managed_by" || tag["tag"].to_s == "managed_by"
        end
        current = find_for_host(hostid: hostid, description: attributes[:description], tags: ownership_tags)
      end
      if current
        triggerid = current.fetch("triggerid")
        attributes[:tags] = merge_tags(current["tags"], attributes[:tags]) if attributes[:tags]
        @client.api_request(method: "trigger.update", params: attributes.merge(triggerid: triggerid))
        triggerid.to_i
      else
        create_managed_trigger(hostid, managed_key, attributes)
      end
    end

    # 创建触发器；若响应丢失或并发冲突则按管理键回读收敛。
    # @return [Integer]
    # @api private
    private def create_managed_trigger(hostid, managed_key, attributes)
      result = @client.api_request(method: "trigger.create", params: attributes)
      result.fetch("triggerids").first.to_i
    rescue TransportError => original_error
      current = recover_created_trigger(hostid: hostid, managed_key: managed_key) if managed_key.present?
      return current.fetch("triggerid").to_i if current

      raise ResultUnknown,
            "trigger create result is unknown; inspect managed key #{managed_key.inspect} before retrying: " \
            "#{original_error.message}"
    rescue ApiError => original_error
      current = recover_created_trigger(hostid: hostid, managed_key: managed_key) if managed_key.present?
      return current.fetch("triggerid").to_i if current

      raise original_error
    end

    # 对结果不确定的创建执行短暂退避回读，不重放写请求。
    # @return [Hash, nil]
    # @api private
    private def recover_created_trigger(hostid:, managed_key:)
      delays = @client.options.fetch(:uncertain_write_delays, DEFAULT_UNCERTAIN_WRITE_DELAYS)
      delays.each do |delay|
        sleep(delay) if delay.positive?
        current = find_managed_for_host(hostid: hostid, managed_key: managed_key)
        return current if current
      rescue ApiError, TransportError
        next
      end
      nil
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

    # 统一触发器 ID 并拒绝空集合。
    # @return [Array<String>]
    # @api private
    private def normalized_ids(values, allow_empty: false)
      ids = Array(values).filter_map { |value| value.to_s.strip.presence }.uniq
      raise Invalid, "triggerids are required" if ids.empty? && !allow_empty

      ids
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
      result.fetch("triggerids").first.to_i
    end
  end
end
