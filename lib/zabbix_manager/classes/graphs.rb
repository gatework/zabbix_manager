# frozen_string_literal: true

class ZabbixManager
  # 图形以 hostid + name 查询；写入所有者由 gitems 中的监控项确定。
  class Graphs < Resource
    # 返回图形对象对应的 Zabbix API 方法前缀。
    #
    # @return [String]
    def method_name
      "graph"
    end

    # 按名称搜索并获取图形的完整数据。
    #
    # @param data [Hash] 包含图形识别字段及其值的查询条件
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Array<Hash>] 匹配的图形完整数据
    def get_full_data(data)
      @client.api_request(
        method: "#{method_name}.get",
        params: {
          search: {
            identify.to_sym => data[identify.to_sym]
          },
          output: "extend"
        }
      )
    end

    # 获取指定主机的图形 ID，并可按名称片段进一步过滤。
    #
    # @param data [Hash] 包含 host，且可包含 filter 的查询条件
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Array] 匹配的图形 ID 列表
    def get_ids_by_host(data)
      result = @client.api_request(
        method: "graph.get",
        params: {
          filter: {
            host: data[:host]
          },
          output: "extend"
        }
      )

      result.filter_map do |graph|
        num = graph["graphid"]
        name = graph["name"]
        filter = data[:filter]

        num if filter.nil? || name.include?(filter.to_s)
      end
    end

    # 获取指定图形包含的图形监控项。
    #
    # @param data [Hash, String, Integer] 图形 ID
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务端返回非成功 HTTP 状态时抛出
    # @return [Array<Hash>] 图形监控项数据
    def get_items(data)
      @client.api_request(
        method: "graphitem.get",
        params: {
          graphids: [data],
          output: "extend"
        }
      )
    end

    # 生成由图形名称和所属主机或模板构成的稳定查询条件。
    # graph.templateid 是继承源图形 ID，不是所属模板 ID。
    # @param data [Hash] 包含 name 和 hostid 的图形属性
    # @return [Hash] 图形唯一查询条件
    def identity_filter(data)
      attributes = data.deep_symbolize_keys
      { name: attributes.fetch(:name), hostid: attributes.fetch(:hostid) }
    end

    # 图形所有者由 gitems 确定，hostid 仅用于调用方的身份查询。
    # @return [Integer, nil]
    def create(data)
      super(data.deep_symbolize_keys.except(:hostid))
    end

    # @return [Integer, nil] 更新的图形 ID
    def update(data)
      super(data.deep_symbolize_keys.except(:hostid))
    end
  end
end
