# frozen_string_literal: true

class ZabbixManager
  # 封装网络设备、接口和线路监控的高频幂等业务流程。
  class Monitoring
    DEFAULT_WINDOW = "5m"
    DEFAULT_PRIORITY = 3
    SUPPORTED_FUNCTIONS = %w[avg max min last].freeze
    EXPRESSION_ITEM_KEY = /\A[A-Za-z0-9_.-]+(?:\[[A-Za-z0-9_.:,\/\-\s{}\#\$"']*\])?\z/.freeze

    # 使用同一个 Manager 复用 API 会话和资源模块。
    # @return [Monitoring] 监控业务对象
    # @api public
    def initialize(manager)
      @manager = manager
    end

    # 创建或更新受监控的网络设备。
    # @return [Integer] Zabbix 主机 ID
    # @api public
    def reconcile_device(data)
      @manager.hosts.reconcile(data)
    end

    # 先校验整批设备，再按技术主机名逐台幂等创建或更新。
    # 默认保留逐台结果；fail_fast 为 true 时遇到首个运行期错误即停止。
    # @return [Array<Hash>]
    def reconcile_devices(collection, fail_fast: false)
      devices = Array(collection).map { |device| @manager.hosts.validate(device) }
      validate_device_batch!(devices)
      devices.map do |device|
        hostid = reconcile_device(device)
        { status: :ok, device: safe_device_identity(device), hostid: hostid }
      rescue ApiError, TransportError, ArgumentError => e
        raise if fail_fast

        failure_result(:device, safe_device_identity(device), e)
      end
    end

    # 分设备和线路两个阶段执行一次网络监控批次，并返回稳定的汇总结果。
    # 线路依赖模板或自动发现产生的流量项；尚未生成时会记录为线路失败，后续可安全重跑。
    # @return [Hash]
    def reconcile_network(devices:, lines:, fail_fast: false)
      validate_line_collection!(lines)
      device_results = reconcile_devices(devices, fail_fast: fail_fast)
      line_results = reconcile_lines(lines, fail_fast: fail_fast)
      results = { devices: device_results, lines: line_results }
      results.merge(summary: batch_summary(results))
    end

    # 使用 Zabbix 已发现的流量项创建或更新线路阈值触发器。
    # 兼容 add_line_monitors.rb 的历史字段名。
    # @return [Hash] 主机、接口、监控项和触发器结果
    # @api public
    def reconcile_line(data = nil, **attributes)
      reconcile_line_with_cache(data || attributes, nil)
    end

    # 批量同步线路并复用主机和监控项查询缓存。
    # 默认逐条记录成功或失败；fail_fast 为 true 时立即抛出错误。
    # @return [Array<Hash>] 每条线路的状态和结果
    # @api public
    def reconcile_lines(collection, fail_fast: false)
      lines = validate_line_collection!(collection)
      cache = { items: {}, hosts: {} }
      lines.map do |line|
        { status: :ok, result: reconcile_line_with_cache(line, cache) }
      rescue ApiError, TransportError, ArgumentError => e
        raise if fail_fast

        failure_result(:line, safe_line_identity(line), e)
      end
    end

    # 创建或更新一个设备接口的监控项和阈值触发器。
    #
    # 必需输入：
    #   host: { hostid: 10101, host: "router-01" }
    #   interface: { name: "GigabitEthernet1/0/1", interfaceid: 12 }
    #   items: { inbound_bps: { key_: "...", name: "...", type: 4, value_type: 3 }, ... }
    #
    # 阈值支持 bandwidth、errors 和 packet_loss，只增改不自动删除远端对象。
    # @return [Hash] 监控项和触发器 ID
    # @api public
    def reconcile_interface(data)
      input = data.deep_symbolize_keys
      host = resolve_explicit_host(input.fetch(:host))
      interface = input.fetch(:interface)
      validate_interface!(interface)

      prepared_items, item_keys = prepare_items(host, interface, input.fetch(:items, {}))
      thresholds = input.fetch(:thresholds, {})
      validate_threshold_items!(thresholds, prepared_items)
      prepared_triggers = prepare_thresholds(
        host: host,
        interface: interface,
        item_keys: item_keys,
        thresholds: thresholds
      )
      itemids = reconcile_items(prepared_items)
      triggerids = reconcile_thresholds(prepared_triggers)

      {
        hostid: host[:hostid].to_i,
        interface: interface[:name],
        itemids: itemids,
        triggerids: triggerids
      }
    end

    private

      # 解析单条线路、发现流量项并同步阈值触发器。
      def reconcile_line_with_cache(data, cache)
        input = data.deep_symbolize_keys
        host = resolve_line_host(input, cache: cache)
        interface_name = input[:interface_name] || input[:iface] || input[:iface1]
        raise Invalid, "line interface_name is required" if interface_name.blank?

        traffic = find_line_traffic_items(host.fetch(:hostid), interface_name, cache: cache)
        capacity_mbps = numeric!(input[:capacity_mbps] || input[:capacity], "line capacity_mbps")
        raise Invalid, "line capacity_mbps must be positive" unless capacity_mbps.positive?

        high_water = water_ratio!(input.fetch(:high_water, 0.90), "high_water")
        recovery_water = water_ratio!(input.fetch(:recovery_water, 0.80), "recovery_water")
        line_identity = input[:line_id].presence || input[:id].presence ||
                        "#{host.fetch(:hostid)}:#{canonical_interface_identity(interface_name)}"
        interface = { name: interface_name, line_id: line_identity }
        item_keys = {
          inbound_bps: traffic.fetch(:inbound).fetch("key_"),
          outbound_bps: traffic.fetch(:outbound).fetch("key_")
        }
        prepared = line_thresholds(input, host, interface, item_keys, capacity_mbps, high_water, recovery_water)
        triggerid = reconcile_thresholds(prepared).fetch(:bandwidth)

        {
          hostid: host.fetch(:hostid).to_i,
          host: host.fetch(:host),
          interface: interface_name,
          itemids: { inbound: traffic[:inbound]["itemid"].to_i, outbound: traffic[:outbound]["itemid"].to_i },
          triggerid: triggerid
        }
      end

      # 根据线路字段组装带宽阈值和历史迁移标签。
      def line_thresholds(input, host, interface, item_keys, capacity_mbps, high_water, recovery_water)
        prepared = prepare_thresholds(
          host: host,
          interface: interface,
          item_keys: item_keys,
          thresholds: {
            bandwidth: {
              capacity_bps: capacity_mbps * 1_000_000,
              high_percent: high_water * 100,
              recovery_percent: recovery_water * 100,
              window: input.fetch(:problem_window, DEFAULT_WINDOW),
              recovery_window: input.fetch(:recovery_window, "15m"),
              priority: input.fetch(:severity, DEFAULT_PRIORITY),
              description: line_trigger_description(input, interface[:name]),
              tags: line_tags(input, interface[:name])
            }
          }
        )
        prepared[:bandwidth][:legacy_identity_tags] = [
          { tag: "category", value: "line_bandwidth", operator: 1 }
        ]
        prepared[:bandwidth][:comments] = line_comments(input, capacity_mbps, high_water, recovery_water)
        prepared
      end

      # 补齐监控项的主机、接口和名称，并检查 key 唯一性。
      def prepare_items(host, interface, items)
        prepared = items.each_with_object({}) do |(metric, raw_attributes), result|
          attributes = raw_attributes.deep_symbolize_keys
          attributes[:hostid] = host[:hostid]
          attributes[:interfaceid] ||= interface[:interfaceid] if interface[:interfaceid]
          attributes[:name] ||= "#{interface[:name]} #{metric.to_s.tr("_", " ")}"
          raise Invalid, "item #{metric} key_ is required" if attributes[:key_].blank?
          unless attributes[:key_].to_s.match?(EXPRESSION_ITEM_KEY)
            raise Invalid, "item #{metric} key_ contains unsupported expression characters"
          end

          result[metric.to_sym] = attributes
        end
        keys = prepared.transform_values { |attributes| attributes.fetch(:key_) }
        if keys.values.uniq.length != keys.length
          raise Invalid, "item key_ values must be unique within an interface"
        end

        [prepared, keys]
      end

      # 把业务阈值转换为 Zabbix 问题和恢复表达式。
      def prepare_thresholds(host:, interface:, item_keys:, thresholds:)
        thresholds.each_with_object({}) do |(metric, raw_config), result|
          config = raw_config.deep_symbolize_keys
          keys = threshold_item_keys(metric, config, item_keys)
          high, recovery = threshold_values(metric, config)
          validate_threshold!(metric, high, recovery)
          window = validate_window!(config.fetch(:window, DEFAULT_WINDOW))
          recovery_window = validate_window!(config.fetch(:recovery_window, window))
          function = validate_function!(config.fetch(:function, "avg"))
          description = config[:description] || "#{interface[:name]} #{metric.to_s.tr("_", " ")} high"
          raise Invalid, "threshold #{metric} description is required" if description.blank?

          priority = validate_priority!(config.fetch(:priority, DEFAULT_PRIORITY))

          result[metric.to_sym] = {
            hostid: host[:hostid],
            description: description,
            expression: combine_expressions(host[:host], keys, function, window, ">", high, "or"),
            recovery_mode: 1,
            recovery_expression: combine_expressions(
              host[:host], keys, function, recovery_window, "<", recovery, "and"
            ),
            priority: priority,
            manual_close: 1,
            tags: managed_tags(interface[:name], metric, config[:tags])
          }
          result[metric.to_sym][:managed_key] = managed_key(interface, metric)
        end
      end

      # 在远端写入前校验各指标的单位和速率语义。
      def validate_threshold_items!(thresholds, items)
        thresholds.each do |metric, raw_config|
          config = raw_config.deep_symbolize_keys
          names = Array(config[:metrics] || default_metrics(metric)).map(&:to_sym)
          selected = names.map do |name|
            items.fetch(name) { raise Invalid, "threshold #{metric} requires item metric #{name}" }
          end
          case metric.to_sym
          when :bandwidth
            selected.each { |item| validate_bps_item!(item) }
          when :errors
            selected.each { |item| validate_error_rate_item!(item) }
          when :packet_loss
            selected.each { |item| validate_packet_loss_item!(item) }
          end
        end
      end

      # 确认误码指标表示每秒速率而不是累计计数器。
      def validate_error_rate_item!(item)
        values = item.with_indifferent_access
        preprocessing = Array(values[:preprocessing])
        rate_step = preprocessing.any? { |step| (step["type"] || step[:type]).to_i == 10 }
        explicit_rate = [values[:key_], values[:name]].join(" ").match?(/rate|per[._ -]?second/i)
        return if rate_step || explicit_rate

        raise Invalid, "error metric #{values[:key_]} must represent a per-second rate"
      end

      # 确认丢包指标使用百分比单位。
      def validate_packet_loss_item!(item)
        values = item.with_indifferent_access
        return if values[:units].to_s == "%"

        raise Invalid, "packet loss metric #{values[:key_]} must use % units"
      end

      # 按稳定 key 写入已准备好的监控项。
      def reconcile_items(prepared_items)
        prepared_items.transform_values { |attributes| @manager.items.upsert_by_key(attributes) }
      end

      # 按稳定管理标签写入已准备好的触发器。
      def reconcile_thresholds(prepared_triggers)
        prepared_triggers.transform_values { |attributes| @manager.triggers.upsert_for_host(attributes) }
      end

      # 在批量写入前拒绝重复线路 ID。
      def validate_line_batch!(lines)
        identities = lines.filter_map { |line| line[:line_id].presence || line[:id].presence }.map(&:to_s)
        duplicate = identities.tally.find { |_identity, count| count > 1 }&.first
        raise Invalid, "duplicate line_id #{duplicate}" if duplicate
      end

      # 规范化并完整预检线路集合，保证校验阶段不执行远端写入。
      def validate_line_collection!(collection)
        lines = Array(collection).map(&:deep_symbolize_keys)
        validate_line_batch!(lines)
        lines.each { |line| validate_line_definition!(line) }
        lines
      end

      # 在任何远端写入前校验线路必填字段和阈值格式。
      def validate_line_definition!(line)
        validate_line_host_reference!(line)
        interface_name = line[:interface_name] || line[:iface] || line[:iface1]
        raise Invalid, "line interface_name is required" if interface_name.blank?

        capacity = numeric!(line[:capacity_mbps] || line[:capacity], "line capacity_mbps")
        raise Invalid, "line capacity_mbps must be positive" unless capacity.positive?

        high_water = water_ratio!(line.fetch(:high_water, 0.90), "high_water")
        recovery_water = water_ratio!(line.fetch(:recovery_water, 0.80), "recovery_water")
        raise Invalid, "recovery_water must be lower than high_water" unless recovery_water < high_water

        validate_window!(line.fetch(:problem_window, DEFAULT_WINDOW))
        validate_window!(line.fetch(:recovery_window, "15m"))
        validate_priority!(line.fetch(:severity, DEFAULT_PRIORITY))
      end

      # 校验线路提供显式主机对象或至少一个可解析的设备候选值。
      def validate_line_host_reference!(line)
        supplied = line[:host]
        if supplied.respond_to?(:deep_symbolize_keys)
          validate_host!(supplied.deep_symbolize_keys)
          return
        end

        candidates = Array(line[:host_candidates])
        candidates.concat([supplied, line[:device], line[:device1], line[:ip], line[:ipaddr1], line[:serial]])
        candidates = candidates.filter_map { |value| value.to_s.strip.presence }
        candidates.delete("IP地址")
        raise Invalid, "line host candidate is required" if candidates.empty?
      end

      # 在任何远端写入前拒绝同一技术主机名的重复设备定义。
      def validate_device_batch!(devices)
        identities = devices.map { |device| device.fetch(:host).to_s }
        duplicate = identities.tally.find { |_identity, count| count > 1 }&.first
        raise Invalid, "duplicate device host #{duplicate}" if duplicate
      end

      # 只返回可安全记录的设备身份字段。
      def safe_device_identity(device)
        { host: device[:host], name: device[:name] }.compact
      end

      # 构造设备或线路的脱敏失败结果。
      def failure_result(kind, identity, error)
        {
          status: :error,
          kind => identity,
          error: { class: error.class.name, message: LogSanitizer.sanitize(error.message) }
        }
      end

      # 汇总批次两个阶段的成功与失败数量。
      def batch_summary(results)
        results.each_with_object({}) do |(kind, entries), summary|
          summary[kind] = {
            total: entries.length,
            succeeded: entries.count { |entry| entry[:status] == :ok },
            failed: entries.count { |entry| entry[:status] == :error }
          }
        end
      end

      # 只返回可安全记录的线路身份字段。
      def safe_line_identity(line)
        {
          line_id: line[:line_id].presence || line[:id].presence,
          device: line[:device] || line[:device1],
          interface: line[:interface_name] || line[:iface] || line[:iface1]
        }.compact
      end

      # 解析一个阈值引用的监控项 key 集合。
      def threshold_item_keys(metric, config, item_keys)
        metric_names = Array(config[:metrics] || default_metrics(metric))
        keys = metric_names.map do |name|
          item_keys.fetch(name.to_sym) do
            raise Invalid, "threshold #{metric} requires item metric #{name}"
          end
        end
        raise Invalid, "threshold #{metric} requires at least one item" if keys.empty?

        keys
      end

      # 返回常用指标默认依赖的监控项名称。
      def default_metrics(metric)
        case metric.to_sym
        when :bandwidth then %i[inbound_bps outbound_bps]
        when :errors then %i[in_errors out_errors]
        when :packet_loss then [:packet_loss]
        else [metric.to_sym]
        end
      end

      # 计算带宽百分比或普通指标的高低阈值。
      def threshold_values(metric, config)
        if metric.to_sym == :bandwidth
          capacity = numeric!(config[:capacity_bps], "bandwidth capacity_bps")
          high_percent = numeric!(config[:high_percent], "bandwidth high_percent")
          recovery_percent = numeric!(config[:recovery_percent], "bandwidth recovery_percent")
          unless capacity.positive? && high_percent.between?(0, 100) && recovery_percent.between?(0, 100)
            raise Invalid, "bandwidth capacity must be positive and percentages must be between 0 and 100"
          end

          [capacity * high_percent / 100.0, capacity * recovery_percent / 100.0]
        else
          [numeric!(config[:high], "#{metric} high"), numeric!(config[:recovery], "#{metric} recovery")]
        end
      end

      # 校验恢复阈值低于问题阈值，形成滞回区间。
      def validate_threshold!(metric, high, recovery)
        return if high.positive? && recovery >= 0 && recovery < high

        raise Invalid, "#{metric} recovery threshold must be non-negative and lower than high threshold"
      end

      # 组合多个方向的触发器表达式。
      def combine_expressions(host, keys, function, window, operator, threshold, joiner)
        keys.map do |key|
          function_call = expression_function(host, key, function, window)
          "#{function_call}#{operator}#{format_number(threshold)}"
        end.join(" #{joiner} ")
      end

      # 按 Zabbix 版本生成新式或旧式函数表达式。
      def expression_function(host, key, function, window)
        if modern_trigger_expression?
          source = "/#{host}/#{key}"
          function == "last" ? "last(#{source})" : "#{function}(#{source},#{window})"
        else
          parameter = function == "last" ? "" : window
          "{#{host}:#{key}.#{function}(#{parameter})}"
        end
      end

      # 判断服务端是否支持 Zabbix 5.4 起的新表达式语法。
      def modern_trigger_expression?
        version = @manager.client.api_version.to_s.split(".").first(2).map(&:to_i)
        (version <=> [5, 4]) >= 0
      end

      # 合并系统管理标签和调用方扩展标签。
      def managed_tags(interface_name, metric, extra_tags)
        tags = [
          { tag: "managed_by", value: "zabbix_manager" },
          { tag: "interface", value: interface_name.to_s },
          { tag: "metric", value: metric.to_s }
        ]
        tags.concat(Array(extra_tags).map do |tag|
          unless tag.respond_to?(:deep_symbolize_keys)
            raise Invalid, "threshold tags must contain a non-empty tag name"
          end

          normalized = tag.deep_symbolize_keys
          raise Invalid, "threshold tags must contain a non-empty tag name" if normalized[:tag].blank?

          normalized
        end)
      end

      # 生成不受描述和数组顺序影响的触发器管理键。
      def managed_key(interface, metric)
        identity = interface[:line_id].presence || interface[:interfaceid].presence ||
                   canonical_interface_identity(interface[:name])
        "interface:#{identity}:#{metric}"
      end

      # 从显式主机或历史线路字段中解析唯一主机。
      def resolve_line_host(input, cache: nil)
        supplied = input[:host]
        if supplied.respond_to?(:deep_symbolize_keys)
          return resolve_explicit_host(supplied)
        end

        candidates = Array(input[:host_candidates])
        candidates.concat([supplied, input[:device], input[:device1], input[:ip], input[:ipaddr1], input[:serial]])
        candidates = candidates.filter_map { |value| value.to_s.strip.presence }
        candidates.delete("IP地址")
        raise Invalid, "line host candidate is required" if candidates.empty?

        cache_key = candidates.join("\0")
        found = if cache
                  cache.fetch(:hosts)[cache_key] ||= @manager.hosts.find_by_candidates(candidates)
                else
                  @manager.hosts.find_by_candidates(candidates)
                end
        raise ApiError, "Zabbix host not found for #{candidates.join(", ")}" unless found

        found.deep_symbolize_keys
      end

      # 查询并精确选择接口的入向和出向流量项。
      def find_line_traffic_items(hostid, interface_name, cache: nil)
        aliases = interface_aliases(interface_name)
        source_items = if cache
                         cache.fetch(:items)[hostid.to_s] ||= @manager.items.monitored_traffic_candidates(hostid)
                       else
                         @manager.items.monitored_traffic_candidates(hostid)
                       end
        candidates = source_items.select do |item|
          traffic_item?(item) && interface_item?(item, aliases)
        end
        selected = {
          inbound: unique_direction_item!(candidates, :inbound, interface_name),
          outbound: unique_direction_item!(candidates, :outbound, interface_name)
        }
        selected.each_value { |item| validate_bps_item!(item) }
        selected
      end

      # 把接口名称转换为统一身份集合。
      def interface_aliases(interface_name)
        [canonical_interface_identity(interface_name)]
      end

      # 统一全称、缩写和分隔符，生成稳定接口身份。
      def canonical_interface_identity(value)
        value.to_s.downcase.gsub(/\s+|[-_]/, "")
             .sub(/^tengigabitethernet/, "te")
             .sub(/^gigabitethernet/, "gi")
             .sub(/^ethernet/, "eth")
      end

      # 判断监控项字段是否包含目标接口的精确 token。
      def interface_item?(item, aliases)
        fields = [item["name"], item["key_"], item["snmp_oid"]].compact.map(&:to_s)
        discovered = fields.flat_map { |field| interface_tokens(field) }.map do |name|
          canonical_interface_identity(name)
        end
        aliases.any? { |name| discovered.include?(name) }
      end

      # 从名称、key 和 OID 文本中抽取完整接口 token。
      def interface_tokens(value)
        prefix = "(?:Ten-?GigabitEthernet|GigabitEthernet|Ethernet|Te|Gi|Eth)"
        pattern = /(?:#{prefix})?\d+(?:\/\d+)+(?:[.:]\d+)*(?![A-Za-z0-9\/._-]|:\d)/i
        value.to_s.scan(pattern)
      end

      # 排除误码、丢包和状态项，只保留可能的流量项。
      def traffic_item?(item)
        oid = item["snmp_oid"].to_s
        blob = [item["key_"], item["name"]].join(" ").downcase
        return false if blob.match?(/error|discard|drop|packet|status|utilization|percentage|percent/)

        oid.match?(/1\.3\.6\.1\.2\.1\.31\.1\.1\.1\.(6|10)(\.|$)/) ||
          blob.match?(/net\.if\.(in|out)(?:\[[^,\]]+\]|\b)|ifhc(in|out)octets|inbound|outbound/)
      end

      # 确保一个方向只匹配一个监控项。
      def unique_direction_item!(candidates, direction, interface_name)
        matches = candidates.select { |item| direction_item?(item, direction) }
        if matches.length != 1
          raise Conflict, "expected one #{direction} traffic item for #{interface_name}, found #{matches.length}"
        end

        matches.first
      end

      # 根据 OID、key 和名称判断监控项方向。
      def direction_item?(item, direction)
        oid = item["snmp_oid"].to_s
        blob = [item["key_"], item["name"]].join(" ").downcase
        if direction == :inbound
          oid.match?(/1\.3\.6\.1\.2\.1\.31\.1\.1\.1\.6(\.|$)/) || blob.match?(/net\.if\.in|ifhcin|inbound/)
        else
          oid.match?(/1\.3\.6\.1\.2\.1\.31\.1\.1\.1\.10(\.|$)/) || blob.match?(/net\.if\.out|ifhcout|outbound/)
        end
      end

      # 校验流量项单位及原始八位组预处理链。
      def validate_bps_item!(item)
        values = item.with_indifferent_access
        unless values[:units].to_s.casecmp("bps").zero?
          raise Invalid, "traffic item #{values[:itemid] || values[:key_]} must use bps units"
        end
        return unless raw_octet_counter?(values)

        preprocessing = Array(values[:preprocessing])
        change_per_second = preprocessing.any? { |step| (step["type"] || step[:type]).to_i == 10 }
        bits_multiplier = preprocessing.any? do |step|
          type = step["type"] || step[:type]
          params = step["params"] || step[:params]
          type.to_i == 1 && numeric!(params, "traffic preprocessing multiplier") == 8
        end
        return if change_per_second && bits_multiplier

        identity = values[:itemid] || values[:key_]
        raise Invalid, "raw octet item #{identity} requires change-per-second and multiplier 8 preprocessing"
      end

      # 判断监控项是否直接读取 HC Octets 累计计数器。
      def raw_octet_counter?(item)
        values = item.with_indifferent_access
        oid = values[:snmp_oid].to_s
        key = values[:key_].to_s.downcase
        oid.match?(/1\.3\.6\.1\.2\.1\.31\.1\.1\.1\.(6|10)(\.|$)/) || key.match?(/ifhc(in|out)octets/)
      end

      # 把百分数或小数形式的水位转换为 0 到 1 的比例。
      def water_ratio!(value, name)
        ratio = numeric!(value, name)
        ratio /= 100.0 if ratio > 1
        raise Invalid, "#{name} must be greater than 0 and at most 1" unless ratio.positive? && ratio <= 1

        ratio
      end

      # 组合线路触发器的可读描述。
      def line_trigger_description(input, interface_name)
        ["专线流量超阈值", input[:isp], input[:description], input[:device] || input[:device1], interface_name]
          .compact.map(&:to_s).reject(&:blank?).join(" | ")
      end

      # 从脱敏的线路业务字段生成触发器标签。
      def line_tags(input, interface_name)
        {
          category: "line_bandwidth",
          isp: input[:isp],
          description: input[:description],
          device: input[:device] || input[:device1],
          iface: interface_name
        }.filter_map { |tag, value| { tag: tag.to_s, value: value.to_s } if value.present? }
      end

      # 生成线路阈值参数说明，便于 Zabbix 页面审计。
      def line_comments(input, capacity_mbps, high_water, recovery_water)
        "Managed line bandwidth monitor: ISP=#{input[:isp]}, description=#{input[:description]}, " \
          "capacity_mbps=#{format_number(capacity_mbps)}, high_water=#{high_water}, recovery_water=#{recovery_water}"
      end

      # 校验主机对象包含 ID 和技术名。
      def validate_host!(host)
        raise Invalid, "host.hostid is required" if host[:hostid].blank?
        raise Invalid, "host.host is required" if host[:host].blank?
        raise Invalid, "host.host cannot contain /" if host[:host].to_s.include?("/")
      end

      # 回读主机并核对 hostid 与技术名属于同一对象。
      def resolve_explicit_host(raw_host)
        supplied = raw_host.deep_symbolize_keys
        validate_host!(supplied)
        remote = @manager.hosts.find_by_id(supplied[:hostid])
        raise ApiError, "Zabbix host #{supplied[:hostid]} was not found" unless remote

        resolved = remote.deep_symbolize_keys
        if resolved[:host].to_s != supplied[:host].to_s
          raise Conflict, "hostid and technical host name do not refer to the same Zabbix host"
        end

        resolved[:hostid] = supplied[:hostid]
        resolved
      end

      # 校验接口对象包含可显示名称。
      def validate_interface!(interface)
        raise Invalid, "interface.name is required" if interface[:name].blank?
      end

      # 校验 Zabbix 时间窗口格式。
      def validate_window!(window)
        value = window.to_s
        raise Invalid, "window must use a Zabbix duration such as 5m or 1h" unless value.match?(/\A\d+[smhdw]\z/)

        value
      end

      # 限制触发器函数为受支持的安全集合。
      def validate_function!(function)
        value = function.to_s
        unless SUPPORTED_FUNCTIONS.include?(value)
          raise Invalid, "function must be one of #{SUPPORTED_FUNCTIONS.join(", ")}"
        end

        value
      end

      # 校验 Zabbix 严重级别范围。
      def validate_priority!(priority)
        value = Integer(priority)
        raise Invalid unless value.between?(0, 5)

        value
      rescue ArgumentError, TypeError
        raise Invalid, "priority must be an integer between 0 and 5"
      end

      # 把业务输入转换为浮点数并统一错误消息。
      def numeric!(value, name)
        Float(value)
      rescue ArgumentError, TypeError
        raise Invalid, "#{name} must be numeric"
      end

      # 用稳定精度格式化表达式中的数值。
      def format_number(number)
        number.to_i == number ? number.to_i.to_s : number.round(6).to_s
      end
  end
end
