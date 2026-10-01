# frozen_string_literal: true

class ZabbixManager
  # 原生问题查询与事件确认；问题身份使用 eventid，确认动作属于远端写入。
  class Problems < Resource
    # 返回问题对象对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "problem"
    end

    # 使用触发问题的事件 ID 作为对象身份。
    #
    # @return [String]
    def key
      "eventid"
    end

    # 返回事件 ID 集合字段名。
    #
    # @return [String]
    def keys
      "eventids"
    end

    # 获取问题及其确认、标签和抑制信息，并支持附加查询参数。
    #
    # @param data [Hash] 问题过滤条件及附加 API 参数
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Array<Hash>] 匹配的问题完整数据
    def get_full_data(data)
      data = data.deep_symbolize_keys
      params = {
        recent: false,
        sortfield: ["eventid"],
        sortorder: "DESC",
        output: "extend",
        selectAcknowledges: "extend",
        selectTags: "extend",
        selectSuppressionData: "extend"
      }.merge(data.except(:name).compact)
      params[:filter] = { identify.to_sym => data[identify.to_sym] } if data[identify.to_sym].present?

      @client.api_request(
        method: "#{method_name}.get",
        params: params
      )
    end

    # 获取全部问题对象的完整数据。
    #
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Array<Hash>] 匹配的问题对象列表
    def all
      get_full_data({})
    end

    # 批量确认事件，可指定确认动作和附加消息。
    # @param eventids [Array<String, Integer>, String, Integer] 待确认的事件 ID
    # @param action [Integer] Zabbix 确认动作位掩码
    # @param message [String, nil] 可选确认消息
    # @return [Hash] 事件确认结果
    def acknowledge_events(eventids, action: 2, message: nil)
      ids = normalized_ids(eventids)

      result = @client.api_request(
        method: "event.acknowledge",
        params: { eventids: ids, action: action, message: message }.compact
      )
      response_ids(result, expected: ids)
      result
    end
  end
end
