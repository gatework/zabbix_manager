# frozen_string_literal: true

class ZabbixManager
  # 表示调用方输入或配置无效。
  class Invalid < ArgumentError; end

  # 表示 Zabbix JSON-RPC 返回的业务错误或无效响应。
  class ApiError < StandardError
    attr_reader :response

    # 保存经过脱敏的远端响应，便于调用方诊断。
    # @return [ApiError]
    def initialize(message = nil, response = nil)
      super(message)
      @response = response
    end
  end

  # 表示资源不唯一、身份冲突或无法安全收敛。
  class Conflict < ApiError; end

  # 表示 HTTP 状态或传输层失败。
  class TransportError < StandardError; end

  # 响应无法确认远端操作是否已经完成。
  class ProtocolError < TransportError; end

  # 表示远端可能已完成写入，调用方不得自动重放。
  class ResultUnknown < TransportError; end
end
