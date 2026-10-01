# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/hash/deep_transform_values"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/array/wrap"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "zabbix_manager/version"
require "zabbix_manager/classes/errors"
require "zabbix_manager/log_sanitizer"
require "zabbix_manager/http_transport"
require "zabbix_manager/configuration"
require "zabbix_manager/client"

require "zabbix_manager/resource"

require "zabbix_manager/classes/actions"
require "zabbix_manager/classes/applications"
require "zabbix_manager/classes/configurations"
require "zabbix_manager/classes/events"
require "zabbix_manager/classes/graphs"
require "zabbix_manager/classes/host_groups"
require "zabbix_manager/classes/host_interfaces"
require "zabbix_manager/classes/hosts"
require "zabbix_manager/classes/http_tests"
require "zabbix_manager/classes/items"
require "zabbix_manager/classes/maintenance"
require "zabbix_manager/classes/media_types"
require "zabbix_manager/classes/proxies"
require "zabbix_manager/classes/proxy_groups"
require "zabbix_manager/classes/problems"
require "zabbix_manager/classes/roles"
require "zabbix_manager/classes/screens"
require "zabbix_manager/classes/scripts"
require "zabbix_manager/classes/server"
require "zabbix_manager/classes/templates"
require "zabbix_manager/classes/triggers"
require "zabbix_manager/classes/user_groups"
require "zabbix_manager/classes/user_macros"
require "zabbix_manager/classes/users"
require "zabbix_manager/classes/value_maps"
require "zabbix_manager/classes/discovery_rules"
require "zabbix_manager/monitoring"
require "zabbix_manager/traffic"

class ZabbixManager
  # @return [ZabbixManager::Client]
  attr_reader :client

  # 使用显式配置创建管理器，并立即查询 API 版本、完成认证。
  #
  # @param options [Hash]
  # @return [ZabbixManager]
  # @raise [Invalid, ApiError, TransportError] 配置、认证或连接失败
  def self.connect(**options)
    new(**options)
  end

  # Build a manager using only the documented connection environment variables.
  # Explicit options override the environment, including explicit nil values.
  # @param env [#[]] a mapping containing the four documented ZABBIX_* variables
  # @param options [Hash] explicit connection settings
  # @return [ZabbixManager] an authenticated manager owned by the caller
  def self.from_env(env: ENV, **options)
    new(**Configuration.from_env(env, options))
  end

  # 直接执行调用方指定的 Zabbix API 方法。
  #
  # @param method [String]
  # @param params [Hash, Array]
  # @return [Object]
  # @raise [ApiError] 服务端明确拒绝请求
  # @raise [TransportError, ProtocolError] 未获得可确认结果；写请求不可盲目重试
  def query(method:, params: {})
    @client.api_request(method: method, params: params)
  end

  # 注销用户名会话并关闭连接。
  # @return [Boolean]
  def logout
    @client.logout
  end

  # 关闭持久 HTTP 连接但不改变远端凭据。
  # @return [true] 下次请求可按需重新连接
  def close
    @client.close
  end

  # 初始化管理器并创建唯一共享客户端。
  #
  # @param options [Hash]
  # @raise [Invalid, ApiError, TransportError] 配置、认证或连接失败
  def initialize(**options)
    @client = Client.new(**options)
    @resources = {}
  end

  # Each resource shares this manager's authenticated client.
  RESOURCES = {
    actions: Actions, applications: Applications, configurations: Configurations,
    events: Events, graphs: Graphs, host_groups: HostGroups, host_interfaces: HostInterfaces,
    hosts: Hosts, http_tests: HttpTests, items: Items, maintenance: Maintenance,
    media_types: MediaTypes, problems: Problems, proxies: Proxies, proxy_groups: ProxyGroups, roles: Roles,
    screens: Screens, scripts: Scripts, server: Server, templates: Templates,
    triggers: Triggers, user_groups: UserGroups, user_macros: UserMacros, users: Users,
    value_maps: ValueMaps, discovery_rules: DiscoveryRules
  }.freeze
  private_constant :RESOURCES

  RESOURCES.each do |name, resource_class|
    define_method(name) { @resources[name] ||= resource_class.new(@client) }
  end

  # 返回仅使用 Zabbix 原生 API 的设备、接口和线路监控编排入口。
  # @return [ZabbixManager::Monitoring] 同一 manager 复用同一业务实例
  def monitoring
    @monitoring ||= Monitoring.new(self)
  end

  # 查询数值监控项的历史或趋势序列，不访问数据库、不补造缺失观测。
  # @return [ZabbixManager::Traffic] 同一 manager 复用同一查询实例
  def traffic
    @traffic ||= Traffic.new(self)
  end
end
