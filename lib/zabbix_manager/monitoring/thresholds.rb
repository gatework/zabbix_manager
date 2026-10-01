# frozen_string_literal: true

require "zabbix_manager/monitoring/expressions"

class ZabbixManager
  class Monitoring
    # 先完整验证监控项和阈值，再生成不含远端副作用的触发器定义。
    class Thresholds
      DEFAULT_WINDOW = "5m"
      DEFAULT_PRIORITY = 3
      FUNCTIONS = %w[avg max min last].freeze
      METRICS = { bandwidth: %i[inbound_bps outbound_bps], errors: %i[in_errors out_errors],
                  packet_loss: [:packet_loss] }.freeze
      MANAGED_TAGS = %w[managed_by interface metric zabbix_manager_id].freeze
      CONFIG_KEYS = %i[metrics capacity_bps high_percent recovery_percent high recovery window
                       recovery_window function description priority tags].freeze

      def initialize(client)
        @client = client
      end

      def prepare_items(host, interface, definitions)
        items = Validation.hash!(definitions, "items").to_h do |metric, attributes|
          attributes = Validation.hash!(attributes, "item #{metric}")
          Validation.item_key!(attributes[:key_])
          attributes[:hostid] = host[:hostid]
          attributes[:interfaceid] = interface[:interfaceid] if interface[:interfaceid]
          attributes[:name] = attributes.fetch(:name, "#{interface[:name]} #{metric.to_s.tr('_', ' ')}")
          Validation.text!(attributes[:name], "item #{metric} name")
          [metric, attributes]
        end
        if items.values.map { |item| item[:key_] }.uniq.length != items.length
          raise Invalid, "item key_ values must be unique within an interface"
        end

        items
      end

      def prepare_triggers(host:, interface:, items:, thresholds:)
        Validation.host!(host)
        Validation.hash!(thresholds, "thresholds").to_h do |metric, attributes|
          config = self.class.validate_config!(metric, attributes)
          selected = select_items(metric, config, items)
          high, recovery = self.class.values(metric, config)
          function = config.fetch(:function, "avg")
          window = config.fetch(:window, DEFAULT_WINDOW)
          description = config.fetch(:description, "#{interface[:name]} #{metric.to_s.tr('_', ' ')} high")
          Validation.text!(description, "threshold #{metric} description")
          keys = selected.map { |item| Validation.item_key!(item[:key_]) }
          [metric, {
            hostid: host[:hostid], description: description,
            expression: expression(host[:host], keys, function, window, ">", high, "or"),
            recovery_mode: 1,
            recovery_expression: expression(host[:host], keys, function,
                                            config.fetch(:recovery_window, window), "<=", recovery, "and"),
            priority: Validation.priority!(config.fetch(:priority, DEFAULT_PRIORITY)), manual_close: 1,
            tags: managed_tags(interface[:name], metric, config.fetch(:tags, [])),
            managed_key: managed_key(interface, metric)
          }]
        end
      end

      def self.validate_config!(metric, attributes)
        raise Invalid, "unsupported threshold #{metric}" unless METRICS.key?(metric)

        config = Validation.hash!(attributes, "threshold #{metric}")
        config.assert_valid_keys(*CONFIG_KEYS)
        Validation.window!(config.fetch(:window, DEFAULT_WINDOW))
        Validation.window!(config.fetch(:recovery_window, config.fetch(:window, DEFAULT_WINDOW)))
        Validation.priority!(config.fetch(:priority, DEFAULT_PRIORITY))
        unless FUNCTIONS.include?(config.fetch(:function, "avg"))
          raise Invalid, "function must be one of #{FUNCTIONS.join(', ')}"
        end

        high, recovery = values(metric, config)
        unless high.finite? && recovery.finite? && high.positive? && recovery >= 0 && recovery < high
          raise Invalid, "#{metric} thresholds must be finite with recovery non-negative and lower than high"
        end
        if metric == :packet_loss && high > 100
          raise Invalid, "packet_loss high must be at most 100 percent"
        end

        config
      rescue ArgumentError => error
        raise Invalid, error.message
      end

      def self.values(metric, config)
        if metric == :bandwidth
          capacity = Validation.number!(config[:capacity_bps], "bandwidth capacity_bps")
          high = Validation.number!(config[:high_percent], "bandwidth high_percent")
          recovery = Validation.number!(config[:recovery_percent], "bandwidth recovery_percent")
          unless capacity.positive? && high.between?(0, 100) && recovery.between?(0, 100)
            raise Invalid, "bandwidth capacity must be positive and percentages must be between 0 and 100"
          end

          [capacity * (high / 100), capacity * (recovery / 100)]
        else
          [Validation.number!(config[:high], "#{metric} high"),
           Validation.number!(config[:recovery], "#{metric} recovery")]
        end
      end

      private

      def select_items(metric, config, items)
        names = Validation.array!(config.fetch(:metrics, METRICS.fetch(metric)), "threshold metrics")
        raise Invalid, "threshold #{metric} requires at least one item" if names.empty?

        names.map do |name|
          unless name.is_a?(String) || name.is_a?(Symbol)
            raise Invalid, "threshold metric names must be strings or symbols"
          end

          item = items.fetch(name.to_sym) { raise Invalid, "threshold #{metric} requires item metric #{name}" }
          validate_units!(metric, item)
          item
        end
      end

      def validate_units!(metric, item)
        case metric
        when :bandwidth
          TrafficItems.validate_bps!(item)
        when :errors
          steps = Validation.array!(item.fetch(:preprocessing, []), "error preprocessing")
                            .map { |step| Validation.hash!(step, "error preprocessing step") }
          rate_step = steps.any? { |step| step[:type].to_s == "10" }
          explicit_rate = [item[:key_], item[:name]].join(" ").match?(/(?:\brate\b|[._]rate\b|per[._ -]?second)/i)
          unless rate_step || explicit_rate
            raise Invalid, "error metric #{item[:key_]} must represent a per-second rate"
          end
        when :packet_loss
          raise Invalid, "packet loss metric #{item[:key_]} must use % units" unless item[:units] == "%"
        end
      end

      def expression(host, keys, function, window, operator, threshold, joiner)
        expressions = Expressions.new(@client, host)
        keys.map { |key| expressions.compare(key, function, window, operator, threshold) }.join(" #{joiner} ")
      end

      def managed_tags(interface_name, metric, extra_tags)
        tags = [
          { tag: "managed_by", value: "zabbix_manager" },
          { tag: "interface", value: interface_name },
          { tag: "metric", value: metric.to_s }
        ]
        extra = Validation.array!(extra_tags, "threshold tags").map do |tag|
          tag = Validation.hash!(tag, "threshold tag")
          tag.assert_valid_keys(:tag, :value)
          Validation.text!(tag[:tag], "threshold tag name")
          raise Invalid, "threshold tag #{tag[:tag]} is reserved" if MANAGED_TAGS.include?(tag[:tag])
          raise Invalid, "threshold tag value must be a string" unless tag.fetch(:value, "").is_a?(String)

          { tag: tag[:tag], value: tag.fetch(:value, "") }
        end
        (tags + extra).uniq
      end

      def managed_key(interface, metric)
        identity = interface[:line_id].presence || interface[:interfaceid].presence ||
                   TrafficItems.interface_identity(interface[:name])
        key = "interface:#{identity}:#{metric}"
        raise Invalid, "managed_key is too long" if key.length > Triggers::MAX_MANAGED_KEY_LENGTH

        key
      end
    end
  end
end
