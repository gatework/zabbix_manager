# frozen_string_literal: true

class ZabbixManager
  class Basic
    # 使用 ZabbixManager 客户端初始化基础资源对象。
    #
    # @param client [ZabbixManager::Client] API 客户端
    # @return [ZabbixManager::Basic] 基础资源对象
    def initialize(client)
      @client = client
    end

    # 定义资源对应的 API 方法名占位，要求子类覆盖。
    #
    # @raise [ApiError] 基础类不能直接提供方法名时抛出
    # @return [String] API 方法名
    def method_name
      raise Invalid, "Can't call method_name here"
    end

    # 返回资源创建时使用的默认选项，子类可按需覆盖。
    #
    # @return [Hash] 默认选项
    def default_options
      {}
    end

    # 根据单数 ID 字段名生成 API 返回结果中的复数字段名。
    #
    # @return [String] 复数 ID 字段名
    def keys
      "#{key}s"
    end

    # 根据 API 方法名生成对象 ID 字段名。
    #
    # @return [String] 对象 ID 字段名
    def key
      "#{method_name}id"
    end

    # 定义资源业务标识字段占位，要求子类覆盖。
    #
    # @raise [ApiError] 基础类不能直接提供标识字段时抛出
    # @return [String] 业务标识字段名
    def identify
      raise Invalid, "Can't call identify here"
    end
  end
end
