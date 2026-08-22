# frozen_string_literal: true

class ZabbixManager
  class Users < Basic
    # 返回 Zabbix API 中用户对象的方法名前缀。
    #
    # @return [String] 用户对象的方法名前缀
    def method_name
      "user"
    end

    # 返回用户对象批量结果中的 ID 字段名。
    #
    # @return [String] 用户 ID 复数字段名
    def keys
      "userids"
    end

    # 返回用户对象的主键字段名。
    #
    # @return [String] 用户对象的主键字段名
    def key
      "userid"
    end

    # 返回用于唯一识别用户的业务字段名。
    #
    # @return [String] 用户对象的业务标识字段名
    def identify
      "alias"
    end

    # 按指定动作批量更新用户媒介配置。
    #
    # @param data [Hash] 包含 userids 和 media
    # @param action [String] user API 的动作名
    # @return [Integer, nil] 首个已更新用户的 ID
    def medias_helper(data, action)
      result = @client.api_request(
        method: "user.#{action}",
        params: data[:userids].map do |t|
          {
            userid: t,
            user_medias: data[:media]
          }
        end
      )
      result ? result["userids"][0].to_i : nil
    end

    # 为指定用户添加媒介配置，当前通过 user.update 完成。
    #
    # @param data [Hash] 包含 userids 和 media
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 首个已更新用户的 ID
    def add_medias(data)
      medias_helper(data, "update")
    end

    # 批量替换指定用户的媒介配置。
    #
    # @param data [Hash] 包含 userids 和 media
    # @raise [ApiError] Zabbix API 返回业务错误时抛出
    # @raise [TransportError] Zabbix 服务返回非成功 HTTP 状态时抛出
    # @return [Integer, nil] 首个已更新用户的 ID
    def update_medias(data)
      medias_helper(data, "update")
    end
  end
end
