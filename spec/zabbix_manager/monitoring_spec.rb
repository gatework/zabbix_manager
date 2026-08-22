# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Monitoring do
  let(:hosts) { instance_double(ZabbixManager::Hosts) }
  let(:items) { instance_double(ZabbixManager::Items) }
  let(:triggers) { instance_double(ZabbixManager::Triggers) }
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.4.0") }
  let(:manager) { instance_double(ZabbixManager, client: client, hosts: hosts, items: items, triggers: triggers) }
  let(:monitoring) { described_class.new(manager) }

  before do
    allow(hosts).to receive(:find_by_id).with(10_101)
                                        .and_return(
                                          "hostid" => "10101", "host" => "router-01", "name" => "Example router"
                                        )
  end

  def traffic_item(id:, name:, key:, oid: "", units: "bps", preprocessing: nil)
    item = { "itemid" => id.to_s, "name" => name, "key_" => key, "snmp_oid" => oid, "units" => units }
    item["preprocessing"] = preprocessing if preprocessing
    item
  end

  def bps_preprocessing
    [{ "type" => "10", "params" => "" }, { "type" => "1", "params" => "8" }]
  end

  it "delegates device reconciliation to the host domain" do
    data = { host: "router-01", groups: [{ groupid: 2 }], interfaces: [{ ip: "192.0.2.1" }] }
    allow(hosts).to receive(:reconcile).with(data).and_return(10_101)

    expect(monitoring.reconcile_device(data)).to eq(10_101)
  end

  it "分阶段创建或更新一批设备和线路并返回汇总" do
    devices = [
      { host: "router-01", name: "Example router" },
      { host: "router-02", name: "Example backup router" }
    ]
    lines = [
      { line_id: "line-a", host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1",
        capacity_mbps: 100 }
    ]
    devices.each { |device| allow(hosts).to receive(:validate).with(device).and_return(device) }
    allow(hosts).to receive(:reconcile).with(devices[0]).and_return(10_101)
    allow(hosts).to receive(:reconcile).with(devices[1]).and_raise(ZabbixManager::ApiError, "remote rejected")
    discovered = [
      traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[a]"),
      traffic_item(id: 2, name: "Gi1/0/1 outbound", key: "net.if.out[a]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).with(10_101).and_return(discovered)
    allow(triggers).to receive(:upsert_for_host).and_return(3)

    result = monitoring.reconcile_network(devices: devices, lines: lines)

    expect(result[:devices]).to contain_exactly(
      { status: :ok, device: { host: "router-01", name: "Example router" }, hostid: 10_101 },
      hash_including(status: :error, device: { host: "router-02", name: "Example backup router" })
    )
    expect(result[:lines].first).to include(status: :ok)
    expect(result[:summary]).to eq(
      devices: { total: 2, succeeded: 1, failed: 1 },
      lines: { total: 1, succeeded: 1, failed: 0 }
    )
  end

  it "在设备写入前预检整批线路" do
    device = { host: "router-01" }
    allow(hosts).to receive(:validate).with(device).and_return(device)
    expect(hosts).not_to receive(:reconcile)

    expect do
      monitoring.reconcile_network(
        devices: [device],
        lines: [{ line_id: "line-a", device: "router-01", interface_name: "Gi1/0/1", capacity_mbps: 0 }]
      )
    end.to raise_error(ZabbixManager::Invalid, /must be positive/)
  end

  it "在设备写入前拒绝重复技术主机名" do
    device = { host: "router-01" }
    allow(hosts).to receive(:validate).twice.and_return(device)
    expect(hosts).not_to receive(:reconcile)

    expect do
      monitoring.reconcile_devices([device, device])
    end.to raise_error(ZabbixManager::Invalid, /duplicate device host/)
  end

  it "批量设备在传输失败后继续处理并保留逐条结果" do
    devices = [{ host: "router-01" }, { host: "router-02" }, { host: "router-03" }]
    devices.each { |device| allow(hosts).to receive(:validate).with(device).and_return(device) }
    allow(hosts).to receive(:reconcile).with(devices[0]).and_return(101)
    allow(hosts).to receive(:reconcile).with(devices[1]).and_raise(ZabbixManager::TransportError, "timeout")
    allow(hosts).to receive(:reconcile).with(devices[2]).and_return(103)

    results = monitoring.reconcile_devices(devices)

    expect(results.map { |result| result[:status] }).to eq(%i[ok error ok])
    expect(results[1][:error]).to include(class: "ZabbixManager::TransportError")
  end

  it "upserts interface items and bandwidth, error, and packet-loss triggers" do
    allow(items).to receive(:upsert_by_key).and_return(201, 202, 203, 204, 205)
    allow(triggers).to receive(:upsert_for_host).and_return(301, 302, 303)

    result = monitoring.reconcile_interface(
      host: { hostid: 10_101, host: "router-01" },
      interface: { name: "GigabitEthernet1/0/1", interfaceid: 12 },
      items: {
        inbound_bps: {
          key_: "net.if.in[ifHCInOctets.1]", name: "Inbound", units: "bps", preprocessing: bps_preprocessing
        },
        outbound_bps: {
          key_: "net.if.out[ifHCOutOctets.1]", name: "Outbound", units: "bps", preprocessing: bps_preprocessing
        },
        in_errors: { key_: "net.if.in.errors.rate[1]", name: "Input error rate" },
        out_errors: { key_: "net.if.out.errors.rate[1]", name: "Output error rate" },
        packet_loss: { key_: "icmppingloss[192.0.2.2]", name: "Packet loss", units: "%" }
      },
      thresholds: {
        bandwidth: { capacity_bps: 1_000_000_000, high_percent: 80, recovery_percent: 70 },
        errors: { high: 100, recovery: 20, function: "max" },
        packet_loss: { high: 5, recovery: 2 }
      }
    )

    expect(result).to eq(
      hostid: 10_101,
      interface: "GigabitEthernet1/0/1",
      itemids: { inbound_bps: 201, outbound_bps: 202, in_errors: 203, out_errors: 204, packet_loss: 205 },
      triggerids: { bandwidth: 301, errors: 302, packet_loss: 303 }
    )
    expect(items).to have_received(:upsert_by_key)
      .with(hash_including(hostid: 10_101, interfaceid: 12)).exactly(5).times
    expected_problem = "avg(/router-01/net.if.in[ifHCInOctets.1],5m)>800000000 or " \
                       "avg(/router-01/net.if.out[ifHCOutOctets.1],5m)>800000000"
    expected_recovery = "avg(/router-01/net.if.in[ifHCInOctets.1],5m)<700000000 and " \
                        "avg(/router-01/net.if.out[ifHCOutOctets.1],5m)<700000000"
    expect(triggers).to have_received(:upsert_for_host).with(
      hash_including(
        expression: expected_problem,
        recovery_expression: expected_recovery
      )
    )
  end

  it "rejects invalid threshold hysteresis before creating triggers" do
    expect(items).not_to receive(:upsert_by_key)
    expect(triggers).not_to receive(:upsert_for_host)

    expect do
      monitoring.reconcile_interface(
        host: { hostid: 10_101, host: "router-01" },
        interface: { name: "wan0" },
        items: { packet_loss: { key_: "icmppingloss[192.0.2.2]", name: "Loss", units: "%" } },
        thresholds: { packet_loss: { high: 5, recovery: 5 } }
      )
    end.to raise_error(ArgumentError, /lower than high/)
  end

  it "requires every threshold to reference a reconciled item metric" do
    expect(items).not_to receive(:upsert_by_key)
    expect(triggers).not_to receive(:upsert_for_host)

    expect do
      monitoring.reconcile_interface(
        host: { hostid: 10_101, host: "router-01" },
        interface: { name: "wan0" },
        items: {},
        thresholds: { bandwidth: { capacity_bps: 100, high_percent: 80, recovery_percent: 70 } }
      )
    end.to raise_error(ArgumentError, /requires item metric inbound_bps/)
  end

  it "validates all items and thresholds before any remote write" do
    expect(items).not_to receive(:upsert_by_key)
    expect(triggers).not_to receive(:upsert_for_host)

    expect do
      monitoring.reconcile_interface(
        host: { hostid: 10_101, host: "router-01" },
        interface: { name: "wan0" },
        items: { packet_loss: { key_: "icmppingloss[192.0.2.2]", units: "%" } },
        thresholds: { packet_loss: { high: 5, recovery: 2, priority: 9 } }
      )
    end.to raise_error(ArgumentError, /priority/)
  end

  it "reconciles an imported line against existing interface traffic items" do
    allow(hosts).to receive(:find_by_candidates)
      .with(["edge-switch-01", "192.0.2.10"])
      .and_return("hostid" => "10101", "host" => "edge-switch-01", "name" => "Example edge switch")
    discovered = [
      traffic_item(
        id: 201, name: "Ten-GigabitEthernet1/0/49 inbound", key: "net.if.in[ifHCInOctets.49]",
        oid: "1.3.6.1.2.1.31.1.1.1.6.49", preprocessing: bps_preprocessing
      ),
      traffic_item(
        id: 202, name: "Te1/0/49 outbound", key: "net.if.out[ifHCOutOctets.49]",
        oid: "1.3.6.1.2.1.31.1.1.1.10.49", preprocessing: bps_preprocessing
      )
    ]
    allow(items).to receive(:monitored_traffic_candidates).with("10101").and_return(discovered)
    allow(triggers).to receive(:upsert_for_host).and_return(301)

    result = monitoring.reconcile_line(
      line_id: "line-88",
      description: "Example upstream line",
      capacity: "200",
      device1: "edge-switch-01",
      ipaddr1: "192.0.2.10",
      iface1: "Ten-GigabitEthernet1/0/49",
      isp: "Example ISP",
      high_water: 0.90,
      recovery_water: 0.80,
      problem_window: "5m",
      recovery_window: "15m",
      severity: 4
    )

    expect(result).to include(hostid: 10_101, itemids: { inbound: 201, outbound: 202 }, triggerid: 301)
    expect(triggers).to have_received(:upsert_for_host).with(
      hash_including(
        managed_key: "interface:line-88:bandwidth",
        expression: include("avg(/edge-switch-01/net.if.in[ifHCInOctets.49],5m)>180000000"),
        recovery_expression: include("avg(/edge-switch-01/net.if.out[ifHCOutOctets.49],15m)<160000000"),
        priority: 4
      )
    )
  end

  it "refuses ambiguous line traffic items instead of selecting one by array order" do
    discovered = [
      traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[a]"),
      traffic_item(id: 2, name: "Gi1/0/1 inbound backup", key: "net.if.in[b]"),
      traffic_item(id: 3, name: "Gi1/0/1 outbound", key: "net.if.out[a]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).and_return(discovered)
    expect(triggers).not_to receive(:upsert_for_host)

    expect do
      monitoring.reconcile_line(
        host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100
      )
    end.to raise_error(ZabbixManager::Conflict, /expected one inbound.*found 2/)
  end

  it "does not confuse an interface name with a longer numeric suffix" do
    discovered = [
      traffic_item(id: 1, name: "Gi1/0/10 inbound", key: "net.if.in[a]"),
      traffic_item(id: 2, name: "Gi1/0/10 outbound", key: "net.if.out[a]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).and_return(discovered)
    expect(triggers).not_to receive(:upsert_for_host)

    expect do
      monitoring.reconcile_line(
        host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100
      )
    end.to raise_error(ZabbixManager::Conflict, /found 0/)
  end

  it "精确匹配子接口的全称和缩写" do
    discovered = [
      traffic_item(id: 1, name: "GigabitEthernet1/0/1.100 inbound", key: "net.if.in[a]"),
      traffic_item(id: 2, name: "GigabitEthernet1/0/1.100 outbound", key: "net.if.out[a]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).and_return(discovered)
    allow(triggers).to receive(:upsert_for_host).and_return(3)

    result = monitoring.reconcile_line(
      host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1.100", capacity_mbps: 100
    )

    expect(result[:triggerid]).to eq(3)
  end

  it "不把层级后缀或文本后缀误认为目标接口" do
    discovered = [
      traffic_item(id: 1, name: "Gi1/0/1/2 inbound", key: "net.if.in[a]"),
      traffic_item(id: 2, name: "Gi1/0/1-backup outbound", key: "net.if.out[a]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).and_return(discovered)

    expect do
      monitoring.reconcile_line(
        host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100
      )
    end.to raise_error(ZabbixManager::Conflict, /found 0/)
  end

  it "does not use an empty line id as the managed trigger identity" do
    discovered = [
      traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[a]"),
      traffic_item(id: 2, name: "Gi1/0/1 outbound", key: "net.if.out[a]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).and_return(discovered)
    allow(triggers).to receive(:upsert_for_host).and_return(3)

    monitoring.reconcile_line(
      line_id: "", host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100
    )

    expect(triggers).to have_received(:upsert_for_host).with(
      hash_including(managed_key: "interface:10101:gi1/0/1:bandwidth")
    )
  end

  it "ignores error metrics and rejects raw octet counters without bps preprocessing" do
    discovered = [
      traffic_item(
        id: 1, name: "Gi1/0/1 inbound", key: "ifHCInOctets[Gi1/0/1]",
        oid: "1.3.6.1.2.1.31.1.1.1.6.1", preprocessing: []
      ),
      traffic_item(
        id: 2, name: "Gi1/0/1 outbound", key: "ifHCOutOctets[Gi1/0/1]",
        oid: "1.3.6.1.2.1.31.1.1.1.10.1", preprocessing: []
      ),
      traffic_item(id: 3, name: "Gi1/0/1 input errors", key: "net.if.in[Gi1/0/1,errors]", units: "pps")
    ]
    allow(items).to receive(:monitored_traffic_candidates).and_return(discovered)
    expect(triggers).not_to receive(:upsert_for_host)

    expect do
      monitoring.reconcile_line(
        host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100
      )
    end.to raise_error(ZabbixManager::Invalid, /requires change-per-second/)
  end

  it "reuses host item discovery across a batch of lines" do
    discovered = [
      traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[Gi1/0/1]"),
      traffic_item(id: 2, name: "Gi1/0/1 outbound", key: "net.if.out[Gi1/0/1]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).and_return(discovered)
    allow(triggers).to receive(:upsert_for_host).and_return(3, 4)
    base = { host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100 }

    results = monitoring.reconcile_lines([base.merge(line_id: "line-1"), base.merge(line_id: "line-2")])

    expect(results.map { |result| result.dig(:result, :triggerid) }).to eq([3, 4])
    expect(items).to have_received(:monitored_traffic_candidates).once
  end

  it "在批量写入前拒绝重复 line_id" do
    expect(items).not_to receive(:monitored_traffic_candidates)
    line = { host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100 }

    expect do
      monitoring.reconcile_lines([line.merge(line_id: "line-1"), line.merge(line_id: "line-1")])
    end.to raise_error(ArgumentError, /duplicate line_id/)
  end

  it "为 Zabbix 5.0 生成旧式触发器表达式" do
    allow(client).to receive(:api_version).and_return("5.0.48")
    allow(items).to receive(:upsert_by_key).and_return(1, 2)
    allow(triggers).to receive(:upsert_for_host).and_return(3)

    monitoring.reconcile_interface(
      host: { hostid: 10_101, host: "router-01" },
      interface: { name: "Gi1/0/1" },
      items: {
        inbound_bps: { key_: "net.if.in[1]", name: "Inbound", units: "bps" },
        outbound_bps: { key_: "net.if.out[1]", name: "Outbound", units: "bps" }
      },
      thresholds: { bandwidth: { capacity_bps: 1000, high_percent: 80, recovery_percent: 70 } }
    )

    expect(triggers).to have_received(:upsert_for_host).with(
      hash_including(expression: include("{router-01:net.if.in[1].avg(5m)}>800"))
    )
  end
end
