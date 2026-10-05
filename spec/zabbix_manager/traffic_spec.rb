# frozen_string_literal: true

require "spec_helper"
require "zabbix_manager/traffic"

RSpec.describe ZabbixManager::Traffic do
  let(:manager) { instance_double(ZabbixManager) }
  let(:traffic) { described_class.new(manager) }
  let(:metadata) { [item("2")] }

  before do
    allow(manager).to receive(:query).with(method: "item.get", params: anything).and_return(metadata)
  end

  def item(id, value_type: "3", **attributes)
    { "itemid" => id, "hostid" => "1", "name" => "Traffic", "units" => "bps", "value_type" => value_type }
      .merge(attributes.transform_keys(&:to_s))
  end

  def history(clock, value, ns: "0", itemid: "2")
    { "itemid" => itemid, "clock" => clock.to_s, "ns" => ns, "value" => value.to_s }
  end

  def interface_items
    [
      item("2").merge("name" => "Gi1/0/1 inbound", "key_" => "net.if.in[Gi1/0/1]", "type" => "18"),
      item("3").merge("name" => "Gi1/0/1 outbound", "key_" => "net.if.out[Gi1/0/1]", "type" => "18")
    ]
  end

  def query(**options)
    traffic.series(hostid: 1, itemids: [2], time_from: 100, time_till: 200, **options)
  end

  def series(**options)
    query(**options).fetch(:series).first
  end

  it "scopes item ownership and requests numeric history with deterministic nanosecond ordering" do
    expect(manager).to receive(:query).with(
      method: "item.get",
      params: { hostids: ["1"], itemids: ["2"], monitored: true, output: %w[itemid hostid name units value_type] }
    ).and_return(metadata)
    expect(manager).to receive(:query).with(
      method: "history.get",
      params: { itemids: ["2"], history: 3, time_from: 100, time_till: 200, limit: 12_001,
                output: %w[itemid clock ns value], sortfield: %w[clock ns], sortorder: "DESC" }
    ).and_return([history(110, 3, ns: "9"), history(110, 2, ns: "1"), history(100, 1)])

    result = query
    expect(result).to include(hostid: "1", source: :history, time_from: 100, time_till: 200)
    expect(result[:series].first).to include(status: :ok, truncated: false, record_count: 3,
                                             sample_count: 3, current_value: 3, peak_value: 3)
    expect(result[:series].first[:points].map { |point| point.values_at(:clock, :ns, :value) })
      .to eq([[100, 0, 1], [110, 1, 2], [110, 9, 3]])
  end

  it "preserves request order, deduplicates IDs and reports missing entries in a large metadata collection" do
    ids = (2..2001).to_a.reverse
    metadata.replace(ids.drop(1).reverse.map { |id| item(id.to_s, value_type: "1") })
    expect(manager).not_to receive(:query).with(method: "history.get", params: anything)

    result = query(itemids: ids + [ids.last])[:series]

    expect(result.map { |entry| entry[:itemid] }).to eq(ids.map(&:to_s))
    expect(result.first[:status]).to eq(:unavailable)
    expect(result.drop(1)).to all(include(status: :unsupported))
  end

  it "retains unsigned integer precision beyond floating-point capacity" do
    allow(manager).to receive(:query).with(method: "history.get", params: anything)
                                     .and_return([history(200, "18446744073709551615")])
    expect(series[:current_value]).to eq(18_446_744_073_709_551_615)
  end

  it "retains decimal precision and requests the matching numeric history type" do
    metadata.first["value_type"] = "0"
    expect(manager).to receive(:query).with(method: "history.get", params: hash_including(history: 0))
                                      .and_return([history(200, "0.123456789012345678901")])
    expect(series[:current_value]).to eq(BigDecimal("0.123456789012345678901"))
  end

  it "reduces chart density without replacing exact current values or peaks with bucket averages" do
    rows = [history(100, 1), history(110, 11), history(120, 3), history(130, 7)]
    allow(manager).to receive(:query).with(method: "history.get", params: anything).and_return(rows)

    result = series(max_points: 2)
    expect(result).to include(current_value: 7, peak_value: 11, record_count: 4, sample_count: 4)
    expect(result[:points]).to eq([
                                    { clock: 110, ns: 0, count: 2, value: BigDecimal("6"), min: 1, max: 11 },
                                    { clock: 130, ns: 0, count: 2, value: BigDecimal("5"), min: 3, max: 7 }
                                  ])
  end

  it "requests one extra record and visibly marks truncated history while retaining the latest rows" do
    expect(manager).to receive(:query).with(method: "history.get", params: hash_including(limit: 3))
                                      .and_return([history(200, 4), history(150, 3), history(100, 99)])
    expect(series(limit: 2)).to include(truncated: true, record_count: 2, sample_count: 2,
                                        current_value: 4, peak_value: 4)
  end

  it "preserves empty and missing items rather than inventing zero samples or last-value fallbacks" do
    metadata.first.merge!("lastvalue" => "42", "lastclock" => "200")
    allow(manager).to receive(:query).with(method: "history.get", params: anything).and_return([])
    result = query(itemids: [2, 3])[:series]
    expect(result.map { |entry| entry[:status] }).to eq(%i[empty unavailable])
    expect(result).to all(include(current_value: nil, peak_value: nil, points: [], sample_count: 0))
  end

  it "reports unsupported value types without requesting incompatible history" do
    metadata.first["value_type"] = "1"
    expect(manager).not_to receive(:query).with(method: "history.get", params: anything)
    expect(series).to include(itemid: "2", status: :unsupported, value_type: 1, points: [])
  end

  it "uses supported trend parameters and weights hourly averages by their sample counts" do
    expect(manager).to receive(:query).with(
      method: "trend.get",
      params: { itemids: ["2"], time_from: 100, time_till: 200, limit: 12_001,
                output: %w[itemid clock num value_min value_avg value_max] }
    ).and_return([
                   { "itemid" => "2", "clock" => "200", "num" => "6",
                     "value_min" => "15", "value_avg" => "20", "value_max" => "25" },
                   { "itemid" => "2", "clock" => "100", "num" => "2",
                     "value_min" => "5", "value_avg" => "10", "value_max" => "15" }
                 ])

    result = series(source: :trends, max_points: 1)
    expect(result).to include(sample_count: 8, record_count: 2, current_value: BigDecimal("20"),
                              peak_value: BigDecimal("25"))
    expect(result[:points]).to eq([
                                    { clock: 200, ns: 0, count: 8, value: BigDecimal("17.5"),
                                      min: BigDecimal("5"), max: BigDecimal("25") }
                                  ])
  end

  it "sorts and marks a limited trend collection without asserting it covers the whole range" do
    rows = [200, 100].map do |clock|
      { "itemid" => "2", "clock" => clock.to_s, "num" => "1",
        "value_min" => "1", "value_avg" => "1", "value_max" => "1" }
    end
    allow(manager).to receive(:query).with(method: "trend.get", params: anything).and_return(rows)
    expect(series(source: :trends, limit: 1)).to include(truncated: true, record_count: 1, sample_count: 1)
  end

  it "accepts Time boundaries as inclusive Unix seconds" do
    expect(manager).to receive(:query).with(
      method: "history.get", params: hash_including(time_from: 100, time_till: 200)
    ).and_return([history(100, 1), history(200, 2)])
    expect(query(time_from: Time.at(100.9), time_till: Time.at(200.9))[:time_from]).to eq(100)
  end

  [
    { hostid: 0 }, { itemids: [] }, { itemids: ["bad"] }, { time_from: "100" },
    { time_till: 99 }, { time_from: -1 }, { limit: 1.5 }, { max_points: 0 }, { source: :auto }
  ].each do |options|
    it "rejects invalid query options #{options.inspect} before contacting Zabbix" do
      expect(manager).not_to receive(:query)
      expect { query(**options) }.to raise_error(ZabbixManager::Invalid)
    end
  end

  [nil, {}, [nil]].each do |rows|
    it "rejects malformed item result #{rows.inspect}" do
      allow(manager).to receive(:query).with(method: "item.get", params: anything).and_return(rows)
      expect { query }.to raise_error(ZabbixManager::ProtocolError)
    end
  end

  it "rejects item metadata for another host" do
    metadata.first["hostid"] = "9"
    expect { query }.to raise_error(ZabbixManager::ProtocolError, /ownership/)
  end

  it "rejects an unexpected item and duplicate item metadata" do
    metadata << item("3")
    expect { query }.to raise_error(ZabbixManager::ProtocolError, /ownership/)
    metadata[-1] = item("2")
    expect { query }.to raise_error(ZabbixManager::ProtocolError, /duplicate/)
  end

  [
    { "value" => "NaN" }, { "value" => "Infinity" }, { "value" => "junk" },
    { "clock" => "201" }, { "clock" => "99" }, { "clock" => 150.5 },
    { "itemid" => "9" }, { "ns" => "1000000000" }
  ].each do |attributes|
    it "rejects malformed or out-of-scope history attributes #{attributes.inspect}" do
      metadata.first["value_type"] = "0"
      allow(manager).to receive(:query).with(method: "history.get", params: anything)
                                       .and_return([history(150, 1).merge(attributes)])
      expect { query }.to raise_error(ZabbixManager::ProtocolError)
    end
  end

  it "rejects fractional unsigned values and duplicate samples instead of losing evidence" do
    allow(manager).to receive(:query).with(method: "history.get", params: anything)
                                     .and_return([history(150, "1.5")], [history(150, 1), history(150, 1)])
    expect { query }.to raise_error(ZabbixManager::ProtocolError)
    expect { query }.to raise_error(ZabbixManager::ProtocolError, /duplicate/)
  end

  it "rejects a malformed history result instead of returning an empty observation" do
    allow(manager).to receive(:query).with(method: "history.get", params: anything).and_return(nil)
    expect { query }.to raise_error(ZabbixManager::ProtocolError, /array of objects/)
  end

  it "rejects a provider response exceeding the requested bound" do
    rows = [history(100, 1), history(110, 2), history(120, 3)]
    allow(manager).to receive(:query).with(method: "history.get", params: anything).and_return(rows)
    expect { query(limit: 1) }.to raise_error(ZabbixManager::ProtocolError, /limit/)
  end

  it "rejects inconsistent trend statistics" do
    rows = [{ "itemid" => "2", "clock" => "100", "num" => "2",
              "value_min" => "5", "value_avg" => "50", "value_max" => "10" }]
    allow(manager).to receive(:query).with(method: "trend.get", params: anything).and_return(rows)
    expect { query(source: :trends) }.to raise_error(ZabbixManager::ProtocolError, /statistics/)
  end

  [ZabbixManager::ApiError, ZabbixManager::TransportError].each do |error_class|
    it "propagates #{error_class} instead of claiming an empty observation" do
      allow(manager).to receive(:query).with(method: "history.get", params: anything).and_raise(error_class, "failed")
      expect { query }.to raise_error(error_class, "failed")
    end
  end

  it "resolves an interface into distinct validated inbound and outbound series" do
    hosts = instance_double(ZabbixManager::Hosts)
    items = instance_double(ZabbixManager::Items)
    allow(manager).to receive_messages(hosts: hosts, items: items)
    expect(hosts).to receive(:resolve).with("router").and_return(hostid: "1", host: "router")
    expect(items).to receive(:monitored_traffic_candidates).with("1").and_return(interface_items)
    metadata << item("3")
    allow(manager).to receive(:query).with(method: "history.get", params: anything).and_return([])

    result = traffic.for_interface(host: "router", interface_name: "GigabitEthernet1/0/1",
                                   time_from: 100, time_till: 200)
    expect(result).to include(host: "router", interface_name: "GigabitEthernet1/0/1")
    expect(result[:series].map { |entry| entry.values_at(:itemid, :direction, :status) })
      .to eq([["2", :inbound, :empty], ["3", :outbound, :empty]])
  end

  it "rejects malformed interface discovery results as protocol errors" do
    hosts = instance_double(ZabbixManager::Hosts, resolve: { hostid: "1", host: "router" })
    items = instance_double(ZabbixManager::Items, monitored_traffic_candidates: nil)
    allow(manager).to receive_messages(hosts: hosts, items: items)
    expect do
      traffic.for_interface(host: "router", interface_name: "Gi1/0/1", time_from: 100, time_till: 200)
    end.to raise_error(ZabbixManager::ProtocolError, /array of objects/)
  end

  it "rejects interface units that changed after bps discovery" do
    hosts = instance_double(ZabbixManager::Hosts, resolve: { hostid: "1", host: "router" })
    items = instance_double(ZabbixManager::Items, monitored_traffic_candidates: interface_items)
    allow(manager).to receive_messages(hosts: hosts, items: items)
    metadata.first["units"] = "Bps"
    allow(manager).to receive(:query).with(method: "history.get", params: anything).and_return([])
    expect do
      traffic.for_interface(host: "router", interface_name: "Gi1/0/1", time_from: 100, time_till: 200)
    end.to raise_error(ZabbixManager::Conflict, /bps/)
  end

  it "retains unavailable directions when an item disappears after discovery" do
    hosts = instance_double(ZabbixManager::Hosts, resolve: { hostid: "1", host: "router" })
    items = instance_double(ZabbixManager::Items, monitored_traffic_candidates: interface_items)
    allow(manager).to receive_messages(hosts: hosts, items: items)
    metadata.clear
    result = traffic.for_interface(host: "router", interface_name: "Gi1/0/1", time_from: 100, time_till: 200)
    expect(result[:series]).to all(include(status: :unavailable))
    expect(result[:series].map { |entry| entry[:direction] }).to eq(%i[inbound outbound])
  end
end
