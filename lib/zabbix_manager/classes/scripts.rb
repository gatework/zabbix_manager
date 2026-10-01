# frozen_string_literal: true

class ZabbixManager
  class Scripts < Resource
    # 返回 Zabbix API 中脚本对象的方法名前缀。
    #
    # @return [String] 脚本对象的方法名前缀
    def method_name
      "script"
    end

    # 在指定主机上执行 Zabbix 脚本。
    #
    # 示例：
    #   execute({ scriptid: '12', hostid: '32 })
    #
    # @param data [Hash] 包含 scriptid 和 hostid 的执行参数
    # @return [Hash] Zabbix API 返回的脚本执行结果
    def execute(data)
      @client.api_request(
        method: "script.execute",
        params: {
          scriptid: data[:scriptid],
          hostid: data[:hostid]
        }
      )
    end

    # 查询指定主机可用的脚本。
    #
    # @param data [Hash] Zabbix scripts.getscriptsbyhosts 查询参数
    # @return [Array<Hash>] 主机可用脚本列表
    def getscriptsbyhost(data)
      @client.api_request(method: "script.getscriptsbyhosts", params: data)
    end
  end
end
