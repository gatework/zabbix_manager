# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/hash/deep_transform_values"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/array/wrap"
require "active_support/core_ext/object/blank"
require "zabbix_manager/version"
require "zabbix_manager/classes/errors"
require "zabbix_manager/log_sanitizer"
require "zabbix_manager/http_transport"
require "zabbix_manager/client"

require "zabbix_manager/basic/basic_alias"
require "zabbix_manager/basic/basic_func"
require "zabbix_manager/basic/basic_init"
require "zabbix_manager/basic/basic_logic"

require "zabbix_manager/classes/actions"
require "zabbix_manager/classes/applications"
require "zabbix_manager/classes/configurations"
require "zabbix_manager/classes/events"
require "zabbix_manager/classes/graphs"
require "zabbix_manager/classes/hostgroups"
require "zabbix_manager/classes/hostinterfaces"
require "zabbix_manager/classes/hosts"
require "zabbix_manager/classes/httptests"
require "zabbix_manager/classes/items"
require "zabbix_manager/classes/maintenance"
require "zabbix_manager/classes/mediatypes"
require "zabbix_manager/classes/proxies"
require "zabbix_manager/classes/problems"
require "zabbix_manager/classes/roles"
require "zabbix_manager/classes/screens"
require "zabbix_manager/classes/scripts"
require "zabbix_manager/classes/server"
require "zabbix_manager/classes/templates"
require "zabbix_manager/classes/triggers"
require "zabbix_manager/classes/usergroups"
require "zabbix_manager/classes/usermacros"
require "zabbix_manager/classes/users"
require "zabbix_manager/classes/valuemaps"
require "zabbix_manager/classes/drules"
require "zabbix_manager/monitoring"

class ZabbixManager
  # @return [ZabbixManager::Client]
  attr_reader :client

  # 使用页面或服务配置创建管理器实例。
  #
  # @param options [Hash]
  # @return [ZabbixManager]
  def self.connect(options = {})
    new(options)
  end

  # 返回进程内默认管理器实例。
  # @return [ZabbixManager]
  def self.current
    @current ||= ZabbixManager.new
  end

  # 直接执行调用方指定的 Zabbix API 方法。
  #
  # @param data [Hash]
  # @return [Hash]
  def query(data)
    @client.api_request(method: data[:method], params: data[:params])
  end

  # 注销用户名会话并关闭连接。
  # @return [Boolean]
  def logout
    @client.logout
  end

  # 关闭持久 HTTP 连接但不改变远端凭据。
  def close
    @client.close
  end

  # 初始化管理器并创建唯一共享客户端。
  #
  # @param options [Hash]
  # @return [ZabbixManager::Client]
  def initialize(options = {})
    @client = Client.new(options)
  end

  # 返回动作模块并复用同一客户端。
  # @return [ZabbixManager::Actions]
  def actions
    @actions ||= Actions.new(@client)
  end

  # 返回应用模块并复用同一客户端。
  # @return [ZabbixManager::Applications]
  def applications
    @applications ||= Applications.new(@client)
  end

  # 返回配置导入导出模块并复用同一客户端。
  # @return [ZabbixManager::Configurations]
  def configurations
    @configurations ||= Configurations.new(@client)
  end

  # 返回事件模块并复用同一客户端。
  # @return [ZabbixManager::Events]
  def events
    @events ||= Events.new(@client)
  end

  # 返回图形模块并复用同一客户端。
  # @return [ZabbixManager::Graphs]
  def graphs
    @graphs ||= Graphs.new(@client)
  end

  # 返回主机群组模块并复用同一客户端。
  # @return [ZabbixManager::HostGroups]
  def hostgroups
    @hostgroups ||= HostGroups.new(@client)
  end

  # 返回主机接口 API 模块，并复用同一客户端会话。
  # @return [ZabbixManager::HostInterfaces]
  def hostinterfaces
    @hostinterfaces ||= HostInterfaces.new(@client)
  end

  # 返回主机模块并复用同一客户端。
  # @return [ZabbixManager::Hosts]
  def hosts
    @hosts ||= Hosts.new(@client)
  end

  # 返回 Web 场景模块并复用同一客户端。
  # @return [ZabbixManager::HttpTests]
  def httptests
    @httptests ||= HttpTests.new(@client)
  end

  # 返回监控项模块并复用同一客户端。
  # @return [ZabbixManager::Items]
  def items
    @items ||= Items.new(@client)
  end

  # 返回维护模块并复用同一客户端。
  # @return [ZabbixManager::Maintenance]
  def maintenance
    @maintenance ||= Maintenance.new(@client)
  end

  # 返回媒介类型模块并复用同一客户端。
  # @return [ZabbixManager::Mediatypes]
  def mediatypes
    @mediatypes ||= Mediatypes.new(@client)
  end

  # 返回问题模块并复用同一客户端。
  # @return [ZabbixManager::Problems]
  def problems
    @problems ||= Problems.new(@client)
  end

  # 返回代理模块并复用同一客户端。
  # @return [ZabbixManager::Proxies]
  def proxies
    @proxies ||= Proxies.new(@client)
  end

  # 返回角色模块并复用同一客户端。
  # @return [ZabbixManager::Roles]
  def roles
    @roles ||= Roles.new(@client)
  end

  # 返回聚合图模块并复用同一客户端。
  # @return [ZabbixManager::Screens]
  def screens
    @screens ||= Screens.new(@client)
  end

  # 返回脚本模块并复用同一客户端。
  # @return [ZabbixManager::Scripts]
  def scripts
    @scripts ||= Scripts.new(@client)
  end

  # 返回服务端信息模块并复用同一客户端。
  # @return [ZabbixManager::Server]
  def server
    @server ||= Server.new(@client)
  end

  # 返回模板模块并复用同一客户端。
  # @return [ZabbixManager::Templates]
  def templates
    @templates ||= Templates.new(@client)
  end

  # 返回触发器模块并复用同一客户端。
  # @return [ZabbixManager::Triggers]
  def triggers
    @triggers ||= Triggers.new(@client)
  end

  # 返回用户群组模块并复用同一客户端。
  # @return [ZabbixManager::Usergroups]
  def usergroups
    @usergroups ||= Usergroups.new(@client)
  end

  # 返回用户宏模块并复用同一客户端。
  # @return [ZabbixManager::Usermacros]
  def usermacros
    @usermacros ||= Usermacros.new(@client)
  end

  # 返回用户模块并复用同一客户端。
  # @return [ZabbixManager::Users]
  def users
    @users ||= Users.new(@client)
  end

  # 返回值映射模块并复用同一客户端。
  # @return [ZabbixManager::ValueMaps]
  def valuemaps
    @valuemaps ||= ValueMaps.new(@client)
  end

  # 返回网络发现规则模块并复用同一客户端。
  # @return [ZabbixManager::Drules]
  def drules
    @drules ||= Drules.new(@client)
  end

  # 返回设备、接口和线路监控的幂等业务编排模块。
  def monitoring
    @monitoring ||= Monitoring.new(self)
  end
end
