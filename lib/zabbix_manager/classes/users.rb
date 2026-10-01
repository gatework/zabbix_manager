# frozen_string_literal: true

class ZabbixManager
  class Users < Resource
    # @return [String] API 模块名
    def method_name
      "user"
    end

    # @return [String] 用户名字段
    def identify
      Gem::Version.new(@client.api_version) >= Gem::Version.new("5.4") ? "username" : "alias"
    end

    # 替换指定用户的完整媒介配置。
    # @param data [Hash] 包含 userids 和 media
    # @return [Integer, nil] 首个更新用户的 ID
    def update_medias(data)
      attributes = data.deep_symbolize_keys
      ids = normalized_ids(attributes.fetch(:userids))
      media_field = Gem::Version.new(@client.api_version) >= Gem::Version.new("5.4") ? :medias : :user_medias
      result = @client.api_request(
        method: "user.update",
        params: attributes.fetch(:userids).map do |userid|
          { userid: userid, media_field => attributes.fetch(:media) }
        end
      )
      response_ids(result, expected: ids).first
    end
  end
end
