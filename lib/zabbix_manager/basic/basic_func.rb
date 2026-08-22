# frozen_string_literal: true

class ZabbixManager
  class Basic
    # 将调试信息交给客户端结构化日志，并移除可能包含请求参数的片段。
    #
    # @param message [String] 待记录的调试信息
    # @return [void]
    def log(message)
      return unless @client.options[:debug]

      raw_message = message.to_s
      safe_message = if raw_message.start_with?("[DEBUG]")
                       raw_message[/\A\[DEBUG\]\s+Call\s+[a-z_]+/i] || "[DEBUG] domain operation"
                     else
                       raw_message
                     end
      @client.log(:debug, "domain.operation", message: safe_message)
    end

    # 比较实际哈希是否包含期望哈希中的全部键值。
    #
    # @param first_hash [Hash] 实际数据
    # @param second_hash [Hash] 期望数据
    # @return [Boolean] 是否匹配
    def hash_equals?(first_hash, second_hash)
      actual = normalize_hash(first_hash)
      expected = normalize_hash(second_hash)
      actual.slice(*expected.keys) == expected
    end

    # 将哈希值递归规范为字符串，并忽略 hostid。
    #
    # @param hash [Hash] 待规范化的哈希
    # @return [Hash] 规范化后的副本
    def normalize_hash(hash)
      hash.deep_symbolize_keys.except(:hostid).deep_transform_values(&:to_s)
    end

    # 从 API 结果中解析单个对象 ID，或透传布尔结果。
    #
    # @param data [Hash, Boolean] API 返回结果
    # @return [Integer, Boolean, nil] 对象 ID、布尔结果或空值
    def parse_keys(data)
      case data
      when Hash
        data.empty? ? nil : data[keys][0].to_i
      when TrueClass
        true
      when FalseClass
        false
      end
    end
  end
end
