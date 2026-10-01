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
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything).and_return([])
    allow(hosts).to receive(:resolve) do |reference|
      found = reference.is_a?(Hash) ? hosts.find_by_id(reference[:hostid]) : hosts.find_by_candidates(reference)
      found.deep_symbolize_keys
    end
    allow(ZabbixManager::Monitoring::Device).to receive(:new).and_call_original
    allow(hosts).to receive(:find_by_id).with(10_101)
                                        .and_return(
                                          "hostid" => "10101", "host" => "router-01", "name" => "Example router"
                                        )
  end

  def traffic_item(id:, name:, key:, oid: "", units: "bps", preprocessing: nil)
    item = { "itemid" => id.to_s, "hostid" => "10101", "name" => name, "key_" => key, "snmp_oid" => oid,
             "units" => units, "value_type" => "3", "status" => "0" }
    item["preprocessing"] = preprocessing if preprocessing
    item
  end

  def bps_preprocessing
    [{ "type" => "10", "params" => "" }, { "type" => "1", "params" => "8" }]
  end

  def device_definition(data, result: nil, error: nil)
    definition = ZabbixManager::Monitoring::Device.new(data)
    allow(ZabbixManager::Monitoring::Device).to receive(:new).with(data).and_return(definition)
    call = allow(definition).to receive(:reconcile).with(manager)
    error ? call.and_raise(error) : call.and_return(result)
    definition
  end

  it "returns the device workflow receipt for reuse in the next reconciliation" do
    data = { host: "router-01" }
    receipt = { hostid: 10_101, enabled: true, managed: { group_ids: ["2"], template_ids: [], tag_names: [] } }
    definition = device_definition(data, result: receipt)

    expect(monitoring.reconcile_device(data)).to eq(receipt)
    expect(definition).to have_received(:reconcile).with(manager).once
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
    device_definition(devices[0], result: { hostid: 10_101, enabled: true, managed: {} })
    device_definition(devices[1], error: ZabbixManager::ApiError.new("remote rejected"))
    discovered = [
      traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[a]"),
      traffic_item(id: 2, name: "Gi1/0/1 outbound", key: "net.if.out[a]")
    ]
    allow(items).to receive(:monitored_traffic_candidates).with(10_101).and_return(discovered)
    allow(triggers).to receive(:upsert_for_host).and_return(3)

    result = monitoring.reconcile_network(devices: devices, lines: lines)

    expect(result[:devices]).to contain_exactly(
      { status: :ok, device: { host: "router-01", name: "Example router" },
        result: { hostid: 10_101, enabled: true, managed: {} } },
      hash_including(status: :error, device: { host: "router-02", name: "Example backup router" })
    )
    expect(result[:lines].first).to include(status: :ok)
    expect(result[:summary]).to eq(
      devices: { total: 2, succeeded: 1, failed: 1, unknown: 0 },
      lines: { total: 1, succeeded: 1, failed: 0, unknown: 0 }
    )
  end

  it "在设备写入前预检整批线路" do
    device = { host: "router-01" }
    expect(ZabbixManager::Monitoring::Device).not_to receive(:new)

    expect do
      monitoring.reconcile_network(
        devices: [device],
        lines: [{ line_id: "line-a", host: "router-01", interface_name: "Gi1/0/1", capacity_mbps: 0 }]
      )
    end.to raise_error(ZabbixManager::Invalid, /must be positive/)
  end

  it "在设备写入前拒绝重复技术主机名" do
    device = { host: "router-01" }
    expect(hosts).not_to receive(:get_raw)

    expect do
      monitoring.reconcile_devices([device, device])
    end.to raise_error(ZabbixManager::Invalid, /duplicate device host/)
  end

  it "批量设备在传输失败后继续处理并保留逐条结果" do
    devices = [{ host: "router-01" }, { host: "router-02" }, { host: "router-03" }]
    device_definition(devices[0], result: { hostid: 101 })
    device_definition(devices[1], error: ZabbixManager::TransportError.new("timeout"))
    device_definition(devices[2], result: { hostid: 103 })

    results = monitoring.reconcile_devices(devices)

    expect(results.map { |result| result[:status] }).to eq(%i[ok unknown ok])
    expect(results[1][:error]).to include(class: "ZabbixManager::TransportError")
  end

  it "upserts interface items and bandwidth, error, and packet-loss triggers" do
    allow(items).to receive(:upsert_many).and_return([201, 202, 203, 204, 205])
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
    expect(items).to have_received(:upsert_many)
      .with(all(include(hostid: 10_101, interfaceid: 12)))
    expected_problem = "avg(/router-01/net.if.in[ifHCInOctets.1],5m)>800000000 or " \
                       "avg(/router-01/net.if.out[ifHCOutOctets.1],5m)>800000000"
    expected_recovery = "avg(/router-01/net.if.in[ifHCInOctets.1],5m)<=700000000 and " \
                        "avg(/router-01/net.if.out[ifHCOutOctets.1],5m)<=700000000"
    expect(triggers).to have_received(:upsert_for_host).with(
      hash_including(
        expression: expected_problem,
        recovery_expression: expected_recovery
      )
    )
  end

  it "rejects invalid threshold hysteresis before creating triggers" do
    expect(items).not_to receive(:upsert_many)
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
    expect(items).not_to receive(:upsert_many)
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
    expect(items).not_to receive(:upsert_many)
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
      capacity_mbps: "200",
      host_candidates: ["edge-switch-01", "192.0.2.10"],
      device: "edge-switch-01",
      interface_name: "Ten-GigabitEthernet1/0/49",
      isp: "Example ISP",
      high_water: 0.90,
      recovery_water: 0.80,
      problem_window: "5m",
      recovery_window: "15m",
      severity: 4
    )

    expect(result).to include(hostid: 10_101, itemids: { inbound: 201, outbound: 202 }, triggerids: { bandwidth: 301 })
    expect(triggers).to have_received(:upsert_for_host).with(
      hash_including(
        managed_key: "interface:line-88:bandwidth",
        expression: include("avg(/edge-switch-01/net.if.in[ifHCInOctets.49],5m)>180000000"),
        recovery_expression: include("avg(/edge-switch-01/net.if.out[ifHCOutOctets.49],15m)<=160000000"),
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

    expect(result[:triggerids]).to eq(bandwidth: 3)
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

    expect(results.map { |result| result.dig(:result, :triggerids, :bandwidth) }).to eq([3, 4])
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
    allow(items).to receive(:upsert_many).and_return([1, 2])
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

  context "strict monitoring boundaries" do
    let(:line) do
      { host: { hostid: 10_101, host: "router-01" }, interface_name: "Gi1/0/1", capacity_mbps: 100 }
    end

    before do
      allow(items).to receive(:monitored_traffic_candidates).and_return(
        [
          traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[a]"),
          traffic_item(id: 2, name: "Gi1/0/1 outbound", key: "net.if.out[a]")
        ]
      )
      allow(triggers).to receive(:upsert_for_host).and_return(3)
    end

    it "rejects non-finite capacities before host discovery" do
      expect(hosts).not_to receive(:find_by_id)
      expect { monitoring.reconcile_line(line.merge(capacity_mbps: Float::INFINITY)) }
        .to raise_error(ZabbixManager::Invalid, /finite/)
    end

    it "rejects fractional priorities instead of truncating them" do
      expect(triggers).not_to receive(:upsert_for_host)
      expect { monitoring.reconcile_line(line.merge(severity: 3.8)) }
        .to raise_error(ZabbixManager::Invalid, /integer/)
    end

    it "rejects zero duration windows before remote writes" do
      expect(triggers).not_to receive(:upsert_for_host)
      expect { monitoring.reconcile_line(line.merge(problem_window: "0m")) }
        .to raise_error(ZabbixManager::Invalid, /window/)
    end

    it "validates discovered item keys before constructing expressions" do
      allow(items).to receive(:monitored_traffic_candidates).and_return(
        [
          traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[a],5m)>0 or last(/other/secret"),
          traffic_item(id: 2, name: "Gi1/0/1 outbound", key: "net.if.out[a]")
        ]
      )
      expect(triggers).not_to receive(:upsert_for_host)
      expect { monitoring.reconcile_line(line) }.to raise_error(ZabbixManager::Invalid, /key_/)
    end

    it "distinguishes bytes per second from bits per second" do
      allow(items).to receive(:monitored_traffic_candidates).and_return(
        [
          traffic_item(id: 1, name: "Gi1/0/1 inbound", key: "net.if.in[a]", units: "Bps"),
          traffic_item(id: 2, name: "Gi1/0/1 outbound", key: "net.if.out[a]")
        ]
      )
      expect(triggers).not_to receive(:upsert_for_host)
      expect { monitoring.reconcile_line(line) }.to raise_error(ZabbixManager::Invalid, /bps units/)
    end

    it "does not match a shorter interface inside another interface prefix" do
      allow(items).to receive(:monitored_traffic_candidates).and_return(
        [
          traffic_item(id: 1, name: "VlanGi1/0/1 inbound", key: "net.if.in[a]"),
          traffic_item(id: 2, name: "VlanGi1/0/1 outbound", key: "net.if.out[a]")
        ]
      )
      expect(triggers).not_to receive(:upsert_for_host)
      expect { monitoring.reconcile_line(line) }.to raise_error(ZabbixManager::Conflict, /found 0/)
    end

    it "rejects duplicate implicit line identities before writing either line" do
      expect(triggers).not_to receive(:upsert_for_host)
      expect { monitoring.reconcile_lines([line, line.merge(interface_name: "GigabitEthernet1/0/1")]) }
        .to raise_error(ZabbixManager::Invalid, /duplicate line/)
    end

    it "rejects nil collections instead of reporting successful empty work" do
      expect { monitoring.reconcile_lines(nil) }.to raise_error(ZabbixManager::Invalid, /array/)
      expect { monitoring.reconcile_devices(nil) }.to raise_error(ZabbixManager::Invalid, /array/)
    end

    it "retains uncertain write outcomes in results and summaries" do
      allow(triggers).to receive(:upsert_for_host).and_raise(ZabbixManager::ResultUnknown, "response lost")
      result = monitoring.reconcile_network(devices: [], lines: [line])
      expect(result[:lines].first[:status]).to eq(:unknown)
      expect(result[:summary][:lines]).to eq(total: 1, succeeded: 0, failed: 0, unknown: 1)
    end

    it "fails fast without consuming the remaining lines" do
      allow(triggers).to receive(:upsert_for_host).and_raise(ZabbixManager::ResultUnknown, "response lost")
      expect { monitoring.reconcile_lines([line, line.merge(line_id: "other")], fail_fast: true) }
        .to raise_error(ZabbixManager::ResultUnknown)
      expect(triggers).to have_received(:upsert_for_host).once
    end
    it "reports protocol failures during writes as unknown and during discovery as errors" do
      allow(triggers).to receive(:upsert_for_host).and_raise(ZabbixManager::ProtocolError, "untrustworthy reply")
      expect(monitoring.reconcile_lines([line]).first[:status]).to eq(:unknown)
      allow(items).to receive(:monitored_traffic_candidates).and_raise(ZabbixManager::ProtocolError,
                                                                       "invalid inventory")
      expect(monitoring.reconcile_lines([line]).first[:status]).to eq(:error)
    end

    it "does not turn confirmed API rejection into uncertainty" do
      allow(triggers).to receive(:upsert_for_host).and_raise(ZabbixManager::ApiError, "denied")
      expect(monitoring.reconcile_lines([line]).first[:status]).to eq(:error)
    end

    it "detects different host references that resolve to the same implicit line target" do
      allow(hosts).to receive(:find_by_candidates).and_return("hostid" => "10101", "host" => "router-01")
      expect(triggers).not_to receive(:upsert_for_host)
      expect { monitoring.reconcile_lines([line, line.merge(host: "Router One")]) }
        .to raise_error(ZabbixManager::Invalid, /duplicate line target/)
    end

    it "rejects legacy fields and ambiguous percentage water levels" do
      expect { monitoring.reconcile_line(line.merge(iface1: "other")) }
        .to raise_error(ZabbixManager::Invalid, /iface1/)
      expect { monitoring.reconcile_line(line.merge(high_water: 90)) }
        .to raise_error(ZabbixManager::Invalid, /high_water/)
    end

    it "retains valid empty batches as explicit zero counts" do
      result = monitoring.reconcile_network(devices: [], lines: [])
      expect(result[:summary].values).to all(eq(total: 0, succeeded: 0, failed: 0, unknown: 0))
    end
  end
  context "resource composition" do
    let(:items) { ZabbixManager::Items.new(client) }

    it "preflights every item creation before writing the first interface item" do
      allow(client).to receive(:api_request).with(method: "item.get", params: anything).and_return([])
      expect(client).not_to receive(:api_request).with(method: "item.create", params: anything)
      expect do
        monitoring.reconcile_interface(
          host: { hostid: 10_101, host: "router-01" }, interface: { name: "eth0" },
          items: { first: { key_: "first", type: 2 }, second: { key_: "second" } }
        )
      end.to raise_error(ZabbixManager::Invalid, /type is required/)
    end
  end
end
