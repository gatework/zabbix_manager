# frozen_string_literal: true

class ZabbixManager
  class Server
    # 返回连接对应的 Zabbix API 版本。
    #
    # @return [String] Zabbix API 版本号
    attr_reader :version

    # 使用客户端初始化服务信息，并立即读取 Zabbix API 版本。
    #
    # @param client [ZabbixManager::Client] 已建立配置的 Zabbix 客户端
    # @return [Server] 已初始化的服务信息对象
    def initialize(client)
      @client = client
      @version = @client.api_version
    end
  end
end
