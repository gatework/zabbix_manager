# frozen_string_literal: true

class ZabbixManager
  # 旧版聚合图形的网格创建入口；目标服务器须提供 screen API。
  class Screens < Resource
    # 以下资源类型取自 frontends/php/include/defines.inc.php。
    # SCREEN_RESOURCE_GRAPH => 0,
    # SCREEN_RESOURCE_SIMPLE_GRAPH => 1,
    # SCREEN_RESOURCE_MAP => 2,
    # SCREEN_RESOURCE_PLAIN_TEXT => 3,
    # SCREEN_RESOURCE_HOSTS_INFO => 4,
    # SCREEN_RESOURCE_TRIGGERS_INFO => 5,
    # SCREEN_RESOURCE_SERVER_INFO => 6,
    # SCREEN_RESOURCE_CLOCK => 7,
    # SCREEN_RESOURCE_SCREEN => 8,
    # SCREEN_RESOURCE_TRIGGERS_OVERVIEW => 9,
    # SCREEN_RESOURCE_DATA_OVERVIEW => 10,
    # SCREEN_RESOURCE_URL => 11,
    # SCREEN_RESOURCE_ACTIONS => 12,
    # SCREEN_RESOURCE_EVENTS => 13,
    # SCREEN_RESOURCE_HOSTGROUP_TRIGGERS => 14,
    # SCREEN_RESOURCE_SYSTEM_STATUS => 15,
    # SCREEN_RESOURCE_HOST_TRIGGERS => 16

    # 返回 Zabbix API 中聚合图形对象的方法名前缀。
    #
    # @return [String] 聚合图形对象的方法名前缀
    def method_name
      "screen"
    end

    # 按名称获取聚合图形，不存在时按图形 ID 网格化创建。
    #
    # @param data [Hash] 包含 screen_name、graphids 及可选布局参数
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer] 聚合图形 ID
    def get_or_create_for_host(data)
      screen_name = data[:screen_name]
      graphids = Array(data[:graphids])
      raise Invalid, "screen_name is required" if screen_name.blank?
      raise Invalid, "graphids must contain at least one graph" if graphids.empty?

      hsize = positive_hsize(data.fetch(:hsize, 3))

      valign = data[:valign] || 2
      halign = data[:halign] || 2
      rowspan = data[:rowspan] || 1
      colspan = data[:colspan] || 1
      height = data[:height] || 320
      width = data[:width] || 200
      vsize = data[:vsize] || graphids.length.fdiv(hsize).ceil
      screenid = get_id(name: screen_name)

      unless screenid
        screenitems = graphids.each_with_index.map do |graphid, index|
          {
            resourcetype: 0,
            resourceid: graphid,
            x: index % hsize,
            y: index / hsize,
            valign: valign,
            halign: halign,
            rowspan: rowspan,
            colspan: colspan,
            height: height,
            width: width
          }
        end

        screenid = create(
          name: screen_name,
          hsize: hsize,
          vsize: vsize,
          screenitems: screenitems
        )
      end
      screenid
    end

    private

    # 将横向格数转换为正整数，非法值直接拒绝。
    #
    # @param value [Object] 待校验的横向格数
    # @return [Integer] 正整数横向格数
    def positive_hsize(value)
      size = integer_attribute(value, "hsize")
      raise Invalid, "hsize must be a positive integer" unless size.positive?

      size
    end
  end
end
