# frozen_string_literal: true

require "ipaddr"

class ZabbixManager
  class Monitoring
    # 线路清单使用一套明确字段；外部文件列名应由导入方转换。
    # @api private
    class Line
      FIELDS = %i[line_id host host_candidates interface_name capacity_mbps high_water recovery_water
                  problem_window recovery_window severity device isp description low_traffic status speed
                  reachability_target tags comments event_name opdata].freeze
      METADATA_FIELDS = %i[comments event_name opdata].freeze
      attr_reader :host_reference, :interface_name, :threshold, :low_traffic, :status, :speed,
                  :reachability_target, :metadata

      # 保存调用方定义的独立快照；等待锁和远端发现期间不重新读取可变输入。
      # 仅解析本地定义，不访问服务器；status/speed 为开关或显式 itemid 选择器。
      # @param attributes [Hash] 规范化后的单端点清单字段
      # @raise [Invalid] 字段、阈值或目标格式不合法
      def initialize(attributes)
        @attributes = Validation.hash!(attributes, "line").deep_dup
        @attributes.assert_valid_keys(*FIELDS)
        @interface_name = Validation.text!(@attributes[:interface_name], "line interface_name")
        validate_identity!
        @host_reference = build_host_reference
        @threshold = build_threshold
        Thresholds.validate_config!(:bandwidth, @threshold)
        @low_traffic = build_low_traffic if @attributes.key?(:low_traffic)
        @status = item_selection(:status)
        @speed = item_selection(:speed)
        @reachability_target = build_reachability_target if @attributes.key?(:reachability_target)
        @metadata = @attributes.slice(*METADATA_FIELDS)
        @metadata.each do |key, value|
          raise Invalid, "line #{key} must be a string" unless value.is_a?(String)
        end
      rescue ArgumentError => error
        raise Invalid, error.message
      end

      def identity
        @attributes[:line_id].presence ||
          [host_identity, TrafficItems.interface_identity(interface_name)]
      end

      def interface(hostid:)
        { name: interface_name, line_id: resolved_id(hostid) }
      end

      # 显式 line_id 优先；缺省身份由已解析 hostid 和规范接口名组成。
      # @return [String] 用于受管标签的端点身份
      def resolved_id(hostid)
        @attributes[:line_id].presence || "#{hostid}:#{TrafficItems.interface_identity(interface_name)}"
      end

      def safe_identity
        @attributes.slice(:line_id, :device).merge(interface: interface_name).compact
      end

      private

      def host_identity
        host_reference.is_a?(Hash) ? host_reference[:hostid].to_s : host_reference.sort
      end

      def validate_identity!
        line_id = @attributes[:line_id]
        unless line_id.nil? || line_id.is_a?(String) || line_id.is_a?(Integer)
          raise Invalid, "line_id must be a string or integer"
        end

        @attributes[:line_id] = line_id.to_s if line_id
        %i[device isp description].each do |name|
          next unless @attributes.key?(name)

          Validation.text!(@attributes[name], "line #{name}")
        end
      end

      def build_host_reference
        if @attributes.key?(:host) && @attributes.key?(:host_candidates)
          raise Invalid, "line must supply either host or host_candidates"
        end

        host = @attributes[:host]
        if host.is_a?(Hash)
          Validation.host!(host)
          return host.slice(:hostid, :host)
        end

        candidates = @attributes.key?(:host_candidates) ?
                       Validation.array!(@attributes[:host_candidates], "host_candidates") : [host]
        candidates = candidates.map { |value| Validation.text!(value, "line host candidate").strip }.uniq
        raise Invalid, "line host candidate is required" if candidates.empty?

        candidates
      end

      def build_threshold
        capacity = Validation.number!(@attributes[:capacity_mbps], "line capacity_mbps")
        raise Invalid, "line capacity_mbps must be positive" unless capacity.positive?

        high = water_ratio(@attributes.fetch(:high_water, 0.9), "high_water")
        recovery = water_ratio(@attributes.fetch(:recovery_water, 0.8), "recovery_water")
        raise Invalid, "recovery_water must be lower than high_water" unless recovery < high

        {
          capacity_bps: capacity * 1_000_000,
          high_percent: high * 100, recovery_percent: recovery * 100,
          window: @attributes.fetch(:problem_window, Thresholds::DEFAULT_WINDOW),
          recovery_window: @attributes.fetch(:recovery_window, "15m"),
          priority: @attributes.fetch(:severity, Thresholds::DEFAULT_PRIORITY),
          description: ["专线流量超阈值", @attributes[:isp], @attributes[:description],
                        @attributes[:device], interface_name].compact.join(" | "),
          tags: line_tags
        }
      end

      def line_tags
        extra = Validation.array!(@attributes.fetch(:tags, []), "line tags").map do |tag|
          tag = Validation.hash!(tag, "line tag")
          tag.assert_valid_keys(:tag, :value)
          Validation.text!(tag[:tag], "line tag name")
          if (Thresholds::MANAGED_TAGS + ["line_id"]).include?(tag[:tag])
            raise Invalid, "line tag #{tag[:tag]} is reserved"
          end
          raise Invalid, "line tag value must be a string" unless tag.fetch(:value, "").is_a?(String)

          { tag: tag[:tag], value: tag.fetch(:value, "") }
        end
        [{ tag: "category", value: "line_bandwidth" }] +
          @attributes.slice(:isp, :description, :device).map { |name, value| { tag: name.to_s, value: value } } + extra
      end

      def build_low_traffic
        config = Validation.hash!(@attributes[:low_traffic], "low_traffic")
        config.assert_valid_keys(:below_bps, :recovery_bps, :window, :recovery_window)
        below = Validation.number!(config.fetch(:below_bps, 50), "low_traffic below_bps")
        recovery = Validation.number!(config.fetch(:recovery_bps, 1000), "low_traffic recovery_bps")
        unless below.positive? && recovery > below
          raise Invalid, "low_traffic recovery_bps must be greater than positive below_bps"
        end

        window = Validation.window!(config.fetch(:window, "5m"))
        { below_bps: below, recovery_bps: recovery, window: window,
          recovery_window: Validation.window!(config.fetch(:recovery_window, window)) }
      end

      def item_selection(name)
        value = @attributes.fetch(name, false)
        return value if value == true || value == false

        selection = Validation.hash!(value, name.to_s)
        selection.assert_valid_keys(:itemid)
        Validation.positive_id!(selection[:itemid], "#{name} itemid")
        selection
      end

      def build_reachability_target
        value = Validation.text!(@attributes[:reachability_target], "reachability_target")
        raise Invalid, "reachability_target must be an IP address without a prefix" if value.include?("/")

        IPAddr.new(value).to_s
      rescue IPAddr::InvalidAddressError
        raise Invalid, "reachability_target must be an IPv4 or IPv6 address"
      end

      def water_ratio(value, name)
        ratio = Validation.number!(value, name)
        raise Invalid, "#{name} must be greater than 0 and at most 1" unless ratio.positive? && ratio <= 1

        ratio
      end
    end
  end
end
