# frozen_string_literal: true

require "zabbix_manager/monitoring/validation"
require "zabbix_manager/monitoring/traffic_items"
require "zabbix_manager/monitoring/thresholds"
require "zabbix_manager/monitoring/line"
require "zabbix_manager/monitoring/line_items"
require "zabbix_manager/monitoring/line_plan"
require "zabbix_manager/monitoring/line_lifecycle"
require "zabbix_manager/monitoring/device"

class ZabbixManager
  # 网络设备、接口和线路监控编排。先验证整批输入，再按稳定身份执行远端操作。
  class Monitoring
    # @param manager [ZabbixManager] 共享认证客户端和资源对象
    def initialize(manager)
      @manager = manager
      @thresholds = Thresholds.new(manager.client)
      @workflow_mutex = Mutex.new
    end

    # 按技术主机名装配设备监控；名称引用在写入前通过 API 解析。
    # 同一实例内串行执行工作流，远端写入没有数据库事务或跨进程原子性。
    # @param device [Hash] 原生主机属性及 groups/templates、snmp、proxy_group、managed 等业务选项
    # @return [Hash] hostid、enabled 和下次更新可传回的 managed 集合归属回执
    # @raise [Invalid, Conflict] 输入无效、引用不唯一或不支持当前服务端版本
    # @raise [ApiError, TransportError] 远端操作失败；超时后应先核查远端状态
    def reconcile_device(device)
      definition = Device.new(device)
      @workflow_mutex.synchronize { definition.reconcile(@manager) }
    end

    # 先校验整批本地定义，再逐台对账；单台失败不掩盖其他设备的结果。
    # @param devices [Array<Hash>] 设备定义，技术主机名必须唯一
    # @param fail_fast [Boolean] true 时首个远端错误向上抛出
    # @return [Array<Hash>] 每台设备的身份、status 和 result，或脱敏 error
    # @raise [Invalid] 本地定义无效，此时整批尚未写入
    def reconcile_devices(devices, fail_fast: false)
      Validation.boolean!(fail_fast, "fail_fast")
      reconcile_device_definitions(validate_devices!(devices), fail_fast: fail_fast)
    end

    # 线路预检在设备写入之前完成；线路发现依赖设备或模板产生的监控项。
    # 模板/LLD 异步产生监控项，设备成功不代表对应线路已就绪。
    # @param devices [Array<Hash>] 设备定义
    # @param lines [Array<Hash>] 单端点线路定义；双端使用独立 line_id
    # @param fail_fast [Boolean] true 时首个远端错误向上抛出
    # @return [Hash] devices、lines 逐项结果和成功/失败/未知数量 summary
    def reconcile_network(devices:, lines:, fail_fast: false)
      Validation.boolean!(fail_fast, "fail_fast")
      line_definitions = validate_lines!(lines)
      device_definitions = validate_devices!(devices)
      results = {
        devices: reconcile_device_definitions(device_definitions, fail_fast: fail_fast),
        lines: reconcile_line_definitions(line_definitions, fail_fast: fail_fast)
      }
      results.merge(summary: batch_summary(results))
    end

    # 只读解析主机和监控项，预览实际触发器属性及按类型引用的依赖。
    # ICMP 是 Zabbix server/proxy 对目标的检查，不能证明专线两端的转发路径。
    # @param attributes [Hash] 单端点 line_id、host、interface_name、capacity_mbps 及可选监控配置
    # @return [Hash] hostid、line_id、itemids、triggers、dependencies 和可选 icmp_item
    # @raise [Invalid, Conflict] 阈值、量纲、项目选择或管理归属无法确定
    # @raise [ApiError, TransportError] 远端发现失败，此方法从不写入
    def plan_line(attributes)
      prepare_line(Line.new(attributes), {})
    end

    # 对账一个端点，确认所需触发器后停用该线路不再需要的受管类型。
    # 同一实例串行执行；多步远端写入不具备事务回滚或跨进程原子性。
    # @param attributes [Hash] 与 plan_line 相同的线路定义
    # @return [Hash] 主机、接口、line_id、按指标分类的 itemids 和 triggerids
    # @raise [Invalid, Conflict] 预检失败，此时没有线路写入
    # @raise [ApiError, TransportError] 远端失败；已确认的步骤保留，传输失败可能已提交
    def reconcile_line(attributes)
      line = Line.new(attributes)
      @workflow_mutex.synchronize { apply_line(prepare_line(line, {})) }
    end

    # 先预检整批本地输入和远端发现，再逐端点执行，保留失败与结果未知的区别。
    # @param lines [Array<Hash>] line_id 唯一的端点定义；双端线路使用两个不同 line_id
    # @param fail_fast [Boolean] 遇到首个远端失败时向上抛出
    # @return [Array<Hash>] 每个端点的 status、result 或脱敏 error
    # @raise [Invalid] 本地定义或解析后的目标重复
    def reconcile_lines(lines, fail_fast: false)
      Validation.boolean!(fail_fast, "fail_fast")
      reconcile_line_definitions(validate_lines!(lines), fail_fast: fail_fast)
    end

    # 查询端点的受管触发器；人工触发器及其他管理方的同名对象不在结果中。
    # @param hostid [Integer, String] 目标主机 ID
    # @param line_id [String, Integer] 端点的稳定身份，或 plan_line 返回的自动身份
    # @return [Array<Hash>] 原生 trigger.get 对象，包括 tags、items、状态及表达式
    # @raise [Invalid, Conflict, ProtocolError] 输入无效或远端管理身份不唯一
    def line_triggers(hostid:, line_id:)
      LineLifecycle.new(@manager, hostid, line_id).owned
    end

    # 停用一个端点的全部受管触发器；不删除触发器或共享 ICMP 监控项。
    # @param hostid [Integer, String] 目标主机 ID
    # @param line_id [String, Integer] 端点的稳定身份
    # @return [Array<Integer>] 已确认停用的触发器 ID；没有受管对象时为空
    # @raise [ApiError, TransportError] 写入失败或结果尚未确认
    def disable_line(hostid:, line_id:)
      lifecycle = LineLifecycle.new(@manager, hostid, line_id)
      @workflow_mutex.synchronize { lifecycle.disable }
    end

    # 按该端点的触发器 ID 在服务端过滤问题，再应用数量上限。
    # Zabbix problem.get 的 recent 范围受服务器问题保留配置影响，不代表完整事件归档。
    # @param hostid [Integer, String] 目标主机 ID
    # @param line_id [String, Integer] 端点的稳定身份
    # @param time_from [Integer, Time] 查询起点（Unix 秒或 Time）
    # @param time_till [Integer, Time] 查询终点，默认为当前时间
    # @param limit [Integer] 最大记录数，1..1000；多读取一条以判定截断
    # @return [Hash] problems、truncated、time_from、time_till 和 limit
    # @raise [Invalid, ProtocolError] 范围无效或响应超出目标线路
    def line_problems(hostid:, line_id:, time_from:, time_till: Time.now, limit: 100)
      LineLifecycle.new(@manager, hostid, line_id).problems(time_from: time_from, time_till: time_till, limit: limit)
    end

    # 接口更新只增改，不自动删除远端对象；所有本地校验在首个写入之前完成。
    # @param attributes [Hash] host、interface、按名称分组的原生 items 和 thresholds
    # @return [Hash] hostid、interface、itemids 和 triggerids
    # @raise [Invalid, Conflict] 输入、量纲或资源归属无效
    # @raise [ApiError, TransportError] 远端失败；已经确认的早期步骤不会被回滚
    def reconcile_interface(attributes)
      input = Validation.hash!(attributes, "interface monitoring")
      input.assert_valid_keys(:host, :interface, :items, :thresholds)
      supplied_host = Validation.hash!(input[:host], "host")
      Validation.host!(supplied_host)
      interface = Validation.hash!(input[:interface], "interface")
      interface.assert_valid_keys(:name, :interfaceid)
      Validation.text!(interface[:name], "interface.name")
      Validation.positive_id!(interface[:interfaceid], "interface.interfaceid") if interface.key?(:interfaceid)
      items = @thresholds.prepare_items(supplied_host, interface, input.fetch(:items, {}))
      triggers = @thresholds.prepare_triggers(
        host: supplied_host, interface: interface, items: items, thresholds: input.fetch(:thresholds, {})
      )
      host = resolve_host(supplied_host, {})
      itemids = items.keys.zip(@manager.items.upsert_many(items.values)).to_h
      triggerids = triggers.transform_values { |trigger| @manager.triggers.upsert_for_host(trigger) }
      { hostid: host[:hostid].to_i, interface: interface[:name], itemids: itemids, triggerids: triggerids }
    end

    private

    def validate_devices!(devices)
      definitions = Validation.array!(devices, "devices").map { |device| Device.new(device) }
      validate_unique!(definitions.map(&:identity), "device host")
      definitions
    end

    def validate_lines!(lines)
      definitions = Validation.array!(lines, "lines").map { |attributes| Line.new(attributes) }
      validate_unique!(definitions.map(&:identity), "line_id or host/interface")
      definitions
    end

    def validate_unique!(identities, name)
      duplicate = identities.tally.find { |_identity, count| count > 1 }
      raise Invalid, "duplicate #{name}" if duplicate
    end

    def reconcile_device_definitions(devices, fail_fast:)
      devices.map do |device|
        identity = device.safe_identity
        result = @workflow_mutex.synchronize { device.reconcile(@manager) }
        { status: :ok, device: identity, result: result }
      rescue ApiError, TransportError, Invalid => error
        raise if fail_fast

        failure_result(:device, identity, error, writing: true)
      end
    end

    # 先完成线路发现，防止两个不同候选主机名解析到同一触发器后互相覆盖。
    def reconcile_line_definitions(lines, fail_fast:)
      cache = {}
      prepared = lines.map do |line|
        { line: line, plan: prepare_line(line, cache) }
      rescue ApiError, TransportError, Invalid => error
        raise if fail_fast

        { line: line, failure: failure_result(:line, line.safe_identity, error) }
      end
      identities = prepared.filter_map do |entry|
        plan = entry[:plan]
        [plan[:hostid], plan[:line_id]] if plan
      end
      validate_unique!(identities, "line target")
      prepared.map do |entry|
        next entry[:failure] if entry[:failure]

        { status: :ok, result: @workflow_mutex.synchronize { apply_line(entry[:plan]) } }
      rescue ApiError, TransportError, Invalid => error
        raise if fail_fast

        failure_result(:line, entry[:line].safe_identity, error, writing: true)
      end
    end

    def prepare_line(line, cache)
      host = resolve_host(line.host_reference, cache)
      source_items = cache[[:items, host[:hostid].to_s]] ||=
        @manager.items.monitored_traffic_candidates(host[:hostid])
      resolver = LineItems.new(@manager.items)
      selected = resolver.resolve(line, source_items, hostid: host[:hostid])
      icmp_item = resolver.icmp_plan(host[:hostid], line.reachability_target) if line.reachability_target
      plan = LinePlan.new(@manager.client, line, host, selected, icmp_item).to_h
      lifecycle = LineLifecycle.new(@manager, plan[:hostid], plan[:line_id])
      lifecycle.validate_ownership!(lifecycle.inventory, plan[:triggers].values.pluck(:managed_key))
      plan
    end

    def apply_line(plan)
      lifecycle = LineLifecycle.new(@manager, plan[:hostid], plan[:line_id])
      existing = lifecycle.inventory
      desired_keys = plan[:triggers].values.pluck(:managed_key)
      lifecycle.validate_ownership!(existing, desired_keys)
      itemids = plan[:itemids].dup
      if plan[:icmp_item]
        itemids[:reachability] = LineItems.new(@manager.items).ensure_icmp(plan[:icmp_item])
      end
      triggerids = {}
      plan[:triggers].each do |kind, attributes|
        dependencies = plan[:dependencies].fetch(kind).map { |dependency| { triggerid: triggerids.fetch(dependency) } }
        triggerids[kind] = @manager.triggers.upsert_for_host(attributes.merge(dependencies: dependencies))
      end
      lifecycle.retire(existing, desired_keys)
      plan.slice(:hostid, :host, :interface, :line_id).merge(itemids: itemids, triggerids: triggerids)
    end

    def resolve_host(reference, cache)
      host = cache[[:host, reference]] ||= @manager.hosts.resolve(reference)
      reference.is_a?(Hash) ? host.merge(hostid: reference[:hostid]) : host
    end

    def failure_result(kind, identity, error, writing: false)
      unknown = error.is_a?(ResultUnknown) || (writing && error.is_a?(TransportError))
      {
        status: unknown ? :unknown : :error,
        kind => identity,
        error: { class: error.class.name, message: LogSanitizer.sanitize(error.message) }
      }
    end

    def batch_summary(results)
      results.transform_values do |entries|
        statuses = entries.map { |entry| entry[:status] }.tally
        { total: entries.length, succeeded: statuses.fetch(:ok, 0),
          failed: statuses.fetch(:error, 0), unknown: statuses.fetch(:unknown, 0) }
      end
    end
  end
end
