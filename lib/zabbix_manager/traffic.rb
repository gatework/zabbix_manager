# frozen_string_literal: true

require "bigdecimal"

class ZabbixManager
  # 通过官方 API 读取有界流量序列；历史样本与小时趋势始终明确区分。
  class Traffic
    DEFAULT_LIMIT = 12_000
    DEFAULT_MAX_POINTS = 720
    DECIMAL = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/

    # @param manager [ZabbixManager] 共享连接及资源对象的管理器
    def initialize(manager)
      @manager = manager
    end

    # 返回每个请求监控项的序列，包括不可见、不支持和无数据的状态。
    # 时段两端均包含；Time 按秒取整。数值保留 Integer 或 BigDecimal 精度。
    # points 包含 clock/ns/count/value/min/max；压缩后时间指向桶内最后一条记录。
    # current_value 为已返回记录中最新值（趋势为小时均值）；截断趋势不保证包含最新小时。
    # @param hostid [Integer, String] 所属主机 ID
    # @param itemids [Array<Integer, String>] 需要查询的监控项 ID
    # @param time_from [Time, Integer] 起始时间或 Unix 秒
    # @param time_till [Time, Integer] 结束时间或 Unix 秒
    # @param source [Symbol] :history 原始样本，或 :trends 小时统计
    # @param limit [Integer] 每项最多保留的 API 记录数，额外查询一条用于识别截断
    # @param max_points [Integer] 每项最多返回的图表点数
    # @return [Hash] 查询范围、来源及包含状态、统计和 points 的 series 数组
    # @raise [Invalid] 标识、时间范围或数量无效
    # @raise [ProtocolError] 响应形状、归属或样本数值无效
    # @raise [ApiError, TransportError] 官方 API 查询失败；不会转换为空序列
    def series(hostid:, itemids:, time_from:, time_till:, source: :history,
               limit: DEFAULT_LIMIT, max_points: DEFAULT_MAX_POINTS)
      hostid = identifier!(hostid, "hostid")
      ids = item_ids!(itemids)
      options = query_options(time_from, time_till, source, limit, max_points)
      items = items_for_host(hostid, ids)
      results = ids.map { |id| item_series(id, items[id], options) }
      { hostid: hostid, **options.slice(:time_from, :time_till, :source), series: results }
    end

    # 精确发现接口入/出方向的 bps 监控项，再读取相同时间范围的序列。
    # @param host [String, Array<String>, Hash] 主机候选名或明确的 hostid + host
    # @param interface_name [String] 接口名称，复用现有方向及单位校验
    # @param time_from [Time, Integer] 起始时间或 Unix 秒
    # @param time_till [Time, Integer] 结束时间或 Unix 秒
    # @param source [Symbol] :history 或 :trends
    # @param limit [Integer] 每项 API 记录上限
    # @param max_points [Integer] 每项图表点上限
    # @return [Hash] series 结果，附带 host、interface_name 和各项 direction
    # @raise [Invalid, Conflict] 接口输入、bps 语义或主机/监控项身份无法确认
    # @raise [ApiError, TransportError] 主机、监控项或采样查询失败
    def for_interface(host:, interface_name:, time_from:, time_till:, source: :history,
                      limit: DEFAULT_LIMIT, max_points: DEFAULT_MAX_POINTS)
      Monitoring::Validation.text!(interface_name, "interface_name")
      query_options(time_from, time_till, source, limit, max_points)
      resolved = @manager.hosts.resolve(host)
      candidates = @manager.items.monitored_traffic_candidates(resolved.fetch(:hostid))
      response_rows!(candidates, "item.get")
      traffic = Monitoring::TrafficItems.new(candidates).for_interface(interface_name)
      directions = traffic.to_h { |direction, item| [item.fetch(:itemid).to_s, direction] }
      result = series(hostid: resolved.fetch(:hostid), itemids: directions.keys,
                      time_from: time_from, time_till: time_till, source: source, limit: limit, max_points: max_points)
      result[:series].each do |item|
        if item[:status] != :unavailable && item[:units] != "bps"
          raise Conflict, "interface traffic units changed after bps discovery"
        end

        item[:direction] = directions.fetch(item[:itemid])
      end
      result.merge(host: resolved.fetch(:host), interface_name: interface_name)
    end

    private

    def identifier!(value, name)
      Monitoring::Validation.positive_id!(value, name).to_s
    end

    def item_ids!(values)
      raise Invalid, "itemids must be a nonempty array" unless values.is_a?(Array) && values.any?

      values.map { |value| identifier!(value, "itemid") }.uniq
    end

    def query_options(time_from, time_till, source, limit, max_points)
      time_from = epoch!(time_from, "time_from")
      time_till = epoch!(time_till, "time_till")
      raise Invalid, "time_till must not precede time_from" if time_till < time_from
      raise Invalid, "source must be :history or :trends" unless %i[history trends].include?(source)

      { time_from: time_from, time_till: time_till, source: source,
        limit: positive_integer!(limit, "limit"), max_points: positive_integer!(max_points, "max_points") }
    end

    def epoch!(value, name)
      value = value.to_i if value.is_a?(Time)
      raise Invalid, "#{name} must be Time or nonnegative Unix seconds" unless value.is_a?(Integer) && value >= 0

      value
    end

    def positive_integer!(value, name)
      raise Invalid, "#{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?

      value
    end

    # 显式主机过滤和响应归属检查保证外部 itemid 不能越过查询边界。
    def items_for_host(hostid, ids)
      rows = @manager.query(method: "item.get", params: {
                              hostids: [hostid], itemids: ids, monitored: true,
                              output: %w[itemid hostid name units value_type]
                            })
      response_rows!(rows, "item.get").each_with_object({}) do |item, result|
        id = response_integer!(item["itemid"], "itemid", positive: true).to_s
        owner = response_integer!(item["hostid"], "hostid", positive: true).to_s
        unless ids.include?(id) && owner == hostid && !result.key?(id)
          raise ProtocolError, "item.get returned unexpected or duplicate item ownership"
        end
        unless item["name"].is_a?(String) && item["units"].is_a?(String)
          raise ProtocolError, "item.get returned invalid name or units"
        end

        result[id] = { itemid: id, name: item["name"], units: item["units"],
                       value_type: response_integer!(item["value_type"], "value_type") }
      end
    end

    def item_series(id, metadata, options)
      result = { itemid: id, name: nil, units: nil, value_type: nil, status: :unavailable,
                 truncated: false, record_count: 0, sample_count: 0,
                 current_value: nil, peak_value: nil, points: [] }
      return result unless metadata

      result.merge!(metadata)
      return result.merge(status: :unsupported) unless [0, 3].include?(metadata[:value_type])

      points = read_points(metadata, options)
      truncated = points.length > options[:limit]
      points = points.sort_by { |point| [point[:clock], point[:ns]] }.last(options[:limit])
      result.merge(status: points.empty? ? :empty : :ok, truncated: truncated,
                   record_count: points.length, sample_count: points.sum { |point| point[:count] },
                   current_value: points.last&.fetch(:value), peak_value: points.map { |point| point[:max] }.max,
                   points: reduce_points(points, options[:max_points]))
    end

    def read_points(item, options)
      history = options[:source] == :history
      method = history ? "history.get" : "trend.get"
      params = options.slice(:time_from, :time_till).merge(itemids: [item[:itemid]], limit: options[:limit] + 1)
      if history
        params.merge!(history: item[:value_type], output: %w[itemid clock ns value],
                      sortfield: %w[clock ns], sortorder: "DESC")
      else
        # trend.get 没有排序参数；截断的趋势集合不承诺覆盖整段或包含最新小时。
        params[:output] = %w[itemid clock num value_min value_avg value_max]
      end
      rows = response_rows!(@manager.query(method: method, params: params), method)
      raise ProtocolError, "#{method} exceeded the requested record limit" if rows.length > params[:limit]

      points = rows.map { |row| parse_point(row, item, options) }
      identities = points.map { |point| [point[:clock], point[:ns]] }
      raise ProtocolError, "#{method} returned duplicate sample timestamps" unless identities.uniq == identities

      points
    end

    def parse_point(row, item, options)
      id = response_integer!(row["itemid"], "itemid", positive: true).to_s
      clock = response_integer!(row["clock"], "clock")
      unless id == item[:itemid] && clock.between?(options[:time_from], options[:time_till])
        raise ProtocolError, "traffic sample is outside the requested item or time range"
      end

      if options[:source] == :history
        ns = response_integer!(row["ns"], "ns")
        raise ProtocolError, "history.get returned invalid nanoseconds" unless ns < 1_000_000_000

        value = item[:value_type] == 3 ? response_integer!(row["value"], "value") : decimal!(row["value"])
        { clock: clock, ns: ns, count: 1, value: value, min: value, max: value }
      else
        count = response_integer!(row["num"], "num", positive: true)
        minimum, average, maximum = %w[value_min value_avg value_max].map { |field| decimal!(row[field]) }
        unless minimum <= average && average <= maximum && (item[:value_type] != 3 || minimum >= 0)
          raise ProtocolError, "trend.get returned inconsistent numeric statistics"
        end

        { clock: clock, ns: 0, count: count, value: average, min: minimum, max: maximum }
      end
    end

    def response_rows!(rows, method)
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
        raise ProtocolError, "#{method} must return an array of objects"
      end

      rows
    end

    def response_integer!(value, field, positive: false)
      unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A\d+\z/))
        raise ProtocolError, "traffic response #{field} must be an integer"
      end

      integer = value.to_i
      if integer.negative? || (positive && integer.zero?)
        raise ProtocolError, "traffic response #{field} is outside its valid range"
      end

      integer
    end

    def decimal!(value)
      unless (value.is_a?(String) || value.is_a?(Numeric)) && DECIMAL.match?(value.to_s)
        raise ProtocolError, "traffic response value must be a finite decimal"
      end

      number = BigDecimal(value.to_s)
      raise ProtocolError, "traffic response value must be finite" unless number.finite?

      number
    end

    # 合并只影响展示密度；保留样本权重和极值，clock/ns 标示桶内最后一条记录。
    def reduce_points(points, max_points)
      return points if points.length <= max_points

      size = (points.length.to_f / max_points).ceil
      points.each_slice(size).map do |bucket|
        count = bucket.sum { |point| point[:count] }
        total = bucket.sum { |point| BigDecimal(point[:value].to_s) * point[:count] }
        { clock: bucket.last[:clock], ns: bucket.last[:ns], count: count, value: total / count,
          min: bucket.map { |point| point[:min] }.min, max: bucket.map { |point| point[:max] }.max }
      end
    end
  end
end
