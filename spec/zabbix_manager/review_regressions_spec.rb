# frozen_string_literal: true

require "spec_helper"

RSpec.describe "审查发现的资源与监控边界" do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.0.0", options: {}) }

  before { allow(client).to receive(:with_upsert_lock).and_yield }

  it "角色详情遵循基类 roleid 契约" do
    expect(client).to receive(:api_request).with(
      method: "role.get", params: { roleids: "12", output: "extend", selectRules: "extend" }
    ).and_return([])
    ZabbixManager::Roles.new(client).dump_by_id("roleid" => 12)
  end

  it "角色查询拒绝缺失或矛盾的 ID，不产生无范围查询" do
    expect(client).not_to receive(:api_request)
    [{}, { roleid: 12, id: 13 }].each do |attributes|
      expect { ZabbixManager::Roles.new(client).dump_by_id(attributes) }.to raise_error(ZabbixManager::Invalid)
    end
  end

  it "现代值映射以主机和名称共同定位，更新不提交主机 ID" do
    expect(client).to receive(:api_request).with(
      method: "valuemap.get", params: { filter: { hostid: "1", name: "Status" }, output: %w[valuemapid name] }
    ).and_return([{ "valuemapid" => "4", "name" => "Status" }])
    expect(client).to receive(:api_request).with(
      method: "valuemap.get", params: { filter: { valuemapid: 4 }, output: "extend" }
    ).and_return([{ "valuemapid" => "4", "name" => "Old" }])
    expect(client).to receive(:api_request).with(
      method: "valuemap.update", params: [{ valuemapid: 4, name: "Status", mappings: [] }]
    ).and_return("valuemapids" => ["4"])
    expect(ZabbixManager::ValueMaps.new(client).create_or_update(hostid: 1, name: "Status", mappings: [])).to eq(4)
  end

  it "现代值映射查询要求主机，旧版仍使用全局名称" do
    expect(client).not_to receive(:api_request)
    maps = ZabbixManager::ValueMaps.new(client)
    expect { maps.get_id(name: "Status") }.to raise_error(ZabbixManager::Invalid, /hostid/)
    allow(client).to receive(:api_version).and_return("5.2.0")
    expect(maps.identity_filter(name: "Status")).to eq(name: "Status")
  end

  it "接口创建拒绝引用已有 ID，完整端点可以通过" do
    interfaces = ZabbixManager::HostInterfaces.new(client)
    expect { interfaces.validate_for_create([{ interfaceid: 12 }]) }.to raise_error(ZabbixManager::Invalid)
    endpoint = { type: 1, main: 1, useip: 1, ip: "192.0.2.10", port: "10050" }
    expect(interfaces.validate_for_create([endpoint]).first).to include(endpoint)
  end

  it "接口批次在写入前拒绝两个引用指向同一远端接口" do
    existing = { "interfaceid" => "12", "type" => "1", "main" => "1", "useip" => "1",
                 "ip" => "192.0.2.10", "dns" => "", "port" => "10050" }
    expect(client).to receive(:api_request).with(
      method: "hostinterface.get", params: { hostids: 1, output: "extend" }
    ).and_return([existing])
    expect(client).not_to receive(:api_request).with(method: "hostinterface.update", params: anything)
    expect do
      ZabbixManager::HostInterfaces.new(client).reconcile_for_host(
        hostid: 1, interfaces: [{ interfaceid: 12, port: "20000" }, existing.except("interfaceid")]
      )
    end.to raise_error(ZabbixManager::Invalid, /duplicate/)
  end

  it "接口名保留未知名称的分隔符和大小写，仅转换已知厂商别名" do
    traffic = ZabbixManager::Monitoring::TrafficItems
    expect(traffic.interface_matches?({ "name" => "port-1 inbound" }, "port1")).to be(false)
    expect(traffic.interface_identity("Port1")).not_to eq(traffic.interface_identity("port1"))
    expect(traffic.interface_matches?({ "name" => "port-1 inbound" }, "port-1")).to be(true)
    expect(traffic.interface_identity("Ten-GigabitEthernet1/0/1")).to eq(traffic.interface_identity("Te1/0/1"))
  end

  it "普通 32 位 SNMP 计数要求速率和 bit 转换" do
    traffic = ZabbixManager::Monitoring::TrafficItems
    %w[10 16].each do |column|
      counter = { key_: "net.if.in[1]", type: 20, units: "bps",
                  snmp_oid: "1.3.6.1.2.1.2.2.1.#{column}.1", preprocessing: [] }
      expect { traffic.validate_bps!(counter) }.to raise_error(ZabbixManager::Invalid, /preprocessing/)
      counter[:preprocessing] = [{ type: 10 }, { type: 1, params: "8" }]
      expect { traffic.validate_bps!(counter) }.not_to raise_error
    end
  end

  it "阈值拒绝字符类型的监控项" do
    expect do
      ZabbixManager::Monitoring::Thresholds.new(client).prepare_triggers(
        host: { hostid: 1, host: "router" }, interface: { name: "eth0" },
        items: { packet_loss: { key_: "loss", units: "%", value_type: 1 } },
        thresholds: { packet_loss: { high: 5, recovery: 2 } }
      )
    end.to raise_error(ZabbixManager::Invalid, /numeric/)
  end

  it "部分更新按远端有效配置校验量纲，拒绝前不写入" do
    manager = ZabbixManager.allocate
    manager.instance_variable_set(:@client, client)
    manager.instance_variable_set(:@resources, {})
    expect(client).to receive(:api_request).with(
      method: "host.get", params: hash_including(filter: { hostid: 1 })
    ).and_return([{ "hostid" => "1", "host" => "router", "name" => "router" }])
    allow(client).to receive(:api_request) do |method:, params:|
      raise "unexpected write #{method}" unless method == "item.get"

      key = params.fetch(:filter).fetch(:key_)
      [{ "itemid" => key.include?(".in[") ? "11" : "12", "hostid" => "1", "key_" => key,
         "name" => key, "type" => "0", "value_type" => "3", "units" => "bytes", "preprocessing" => [] }]
    end
    expect do
      manager.monitoring.reconcile_interface(
        host: { hostid: 1, host: "router" }, interface: { name: "eth0" },
        items: { inbound_bps: { key_: "net.if.in[eth0]", units: "bps" },
                 outbound_bps: { key_: "net.if.out[eth0]", units: "bps" } },
        thresholds: { bandwidth: { capacity_bps: 1000, high_percent: 80, recovery_percent: 70 } }
      )
    end.to raise_error(ZabbixManager::Invalid, /preprocessing/)
  end
  it "合法部分更新保留远端类型与预处理，并完成触发器对账" do
    writes = []
    preprocessing = [{ "type" => "10" }, { "type" => "1", "params" => "8" }]
    allow(client).to receive(:api_request) do |method:, params:|
      case method
      when "host.get" then [{ "hostid" => "1", "host" => "router", "name" => "router" }]
      when "item.get"
        key = params.fetch(:filter).fetch(:key_)
        [{ "itemid" => key.include?(".in[") ? "11" : "12", "hostid" => "1", "key_" => key,
           "name" => key, "type" => "0", "value_type" => "3", "units" => "bps",
           "preprocessing" => preprocessing }]
      when "item.update"
        writes << params
        { "itemids" => [params.fetch(:itemid)] }
      when "trigger.get" then []
      when "trigger.create" then { "triggerids" => ["21"] }
      else raise "unexpected method #{method}"
      end
    end
    manager = ZabbixManager.allocate
    manager.instance_variable_set(:@client, client)
    manager.instance_variable_set(:@resources, {})
    result = manager.monitoring.reconcile_interface(
      host: { hostid: 1, host: "router" }, interface: { name: "eth0" },
      items: { inbound_bps: { key_: "net.if.in[eth0]", type: 0, units: "bps" },
               outbound_bps: { key_: "net.if.out[eth0]", type: 0, units: "bps" } },
      thresholds: { bandwidth: { capacity_bps: 1000, high_percent: 80, recovery_percent: 70 } }
    )
    expect(result[:triggerids]).to eq(bandwidth: 21)
    expect(writes.length).to eq(2)
    expect(writes.all? { |attributes| (attributes.keys & %i[value_type preprocessing]).empty? }).to be(true)
    expect(preprocessing).to eq([{ "type" => "10" }, { "type" => "1", "params" => "8" }])
  end

  it "符号形式的普通及 HC octet OID 同样要求转换" do
    traffic = ZabbixManager::Monitoring::TrafficItems
    %w[IF-MIB::ifInOctets.1 IF-MIB::ifHCOutOctets.1 get[IF-MIB::ifInOctets.1]].each do |oid|
      counter = { key_: "net.if.in[eth0]", type: 20, units: "bps", snmp_oid: oid, preprocessing: [] }
      expect { traffic.validate_bps!(counter) }.to raise_error(ZabbixManager::Invalid, /preprocessing/)
      counter[:preprocessing] = [{ type: 10 }, { type: 1, params: "8" }]
      expect { traffic.validate_bps!(counter) }.not_to raise_error
    end
  end
end
