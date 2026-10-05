# frozen_string_literal: true

require "spec_helper"

RSpec.describe "High-level resource response contracts" do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.4.0", options: {}) }

  [nil, {}, [nil], [{}]].each do |rows|
    it "reports #{rows.inspect} as a protocol error in identity lookups" do
      allow(client).to receive(:api_request).and_return(rows)
      operations = [
        -> { ZabbixManager::Hosts.new(client).resolve(hostid: 101, host: "router") },
        -> { ZabbixManager::Items.new(client).find_by_key(hostid: 101, key: "uptime") },
        -> { ZabbixManager::Triggers.new(client).find_by_id(1) },
        -> { ZabbixManager::HostGroups.new(client).get_id(name: "Routers") },
        -> { ZabbixManager::HostGroups.new(client).all },
        -> { ZabbixManager::HostGroups.new(client).update(groupid: 1, name: "Routers") },
        -> { ZabbixManager::Proxies.new(client).get_proxy_id("proxy") },
        -> { ZabbixManager::HostInterfaces.new(client).delete_many(hostid: 101, interfaceids: [1]) }
      ]

      operations.each { |operation| expect(&operation).to raise_error(ZabbixManager::ProtocolError) }
    end
  end

  it "validates overridden ID query results before deciding an update" do
    allow(client).to receive(:api_request).and_return(nil)
    expect { ZabbixManager::Hosts.new(client).update(hostid: 1, name: "Router") }
      .to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects a different trigger ID before merging dependencies" do
    allow(client).to receive(:with_upsert_lock).and_yield
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything) do |params:, **|
      if params.key?(:hostids)
        [{ "triggerid" => "1" }]
      else
        [{ "triggerid" => "2", "dependencies" => [{ "triggerid" => "3" }] }]
      end
    end
    expect(client).not_to receive(:api_request).with(method: "trigger.update", params: anything)

    expect do
      ZabbixManager::Triggers.new(client).add_dependencies(
        hostid: 101, triggerid: 1, depends_on: [4], allow_cross_host_dependencies: true
      )
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "retains raw response pass-through for callers using the native API" do
    allow(client).to receive(:api_request).and_return(nil)

    expect(ZabbixManager::Items.new(client).get_raw(output: "extend")).to be_nil
  end

  it "continues line reconciliation after one host discovery returns a malformed response" do
    requests = []
    allow(client).to receive(:with_upsert_lock).and_yield
    allow(client).to receive(:api_request) do |method:, params:|
      requests << [method, params]
      case method
      when "host.get"
        params.dig(:filter, :hostid) == 101 ? nil : [{ "hostid" => "102", "host" => "router" }]
      when "item.get"
        %w[in out].each_with_index.map do |direction, index|
          { "itemid" => (index + 1).to_s, "hostid" => "102", "key_" => "net.if.#{direction}[1]",
            "name" => "Gi1/0/1 #{direction == 'in' ? 'inbound' : 'outbound'}", "units" => "bps",
            "type" => "18", "value_type" => "3", "status" => "0" }
        end
      when "trigger.get" then []
      when "trigger.create" then { "triggerids" => ["301"] }
      else raise "unexpected request #{method}"
      end
    end
    manager = Struct.new(:client, :hosts, :items, :triggers).new(
      client, ZabbixManager::Hosts.new(client), ZabbixManager::Items.new(client), ZabbixManager::Triggers.new(client)
    )
    definitions = [101, 102].map do |hostid|
      { host: { hostid: hostid, host: "router" }, line_id: hostid.to_s,
        interface_name: "Gi1/0/1", capacity_mbps: 100 }
    end

    results = ZabbixManager::Monitoring.new(manager).reconcile_lines(definitions)

    expect(results.map { |result| result[:status] }).to eq(%i[error ok])
    expect(results.first[:error][:class]).to eq("ZabbixManager::ProtocolError")
    expect(results.last[:result][:triggerids]).to eq(bandwidth: 301)
    expect(requests.count { |method, _params| method == "trigger.create" }).to eq(1)
  end

  it "snapshots trigger definitions before discovery callbacks mutate the caller input" do
    attributes = { hostid: 101, description: +"original", expression: +"last(/router/uptime)=0" }
    writes = []
    allow(client).to receive(:with_upsert_lock).and_yield
    allow(client).to receive(:api_request) do |method:, params:|
      if method == "trigger.get"
        attributes[:description].replace("changed")
        []
      else
        writes << params.deep_dup
        { "triggerids" => ["1"] }
      end
    end

    ZabbixManager::Triggers.new(client).upsert_for_host(attributes)

    expect(writes.first[:description]).to eq("original")
    expect(attributes[:description]).to eq("changed")
  end

  it "snapshots interface definitions before the first write callback changes the next endpoint" do
    endpoints = ["192.0.2.1", "192.0.2.2"].map do |ip|
      { type: 1, main: 1, useip: 1, ip: ip.dup, port: "10050" }
    end
    writes = []
    allow(client).to receive(:with_upsert_lock).and_yield
    allow(client).to receive(:api_request) do |method:, params:|
      next [] if method == "hostinterface.get"

      writes << params.deep_dup
      endpoints.last[:ip].clear if writes.one?
      { "interfaceids" => [writes.length.to_s] }
    end

    ZabbixManager::HostInterfaces.new(client).reconcile_for_host(hostid: 101, interfaces: endpoints)

    expect(writes.map { |attributes| attributes[:ip] }).to eq(%w[192.0.2.1 192.0.2.2])
    expect(endpoints.last[:ip]).to eq("")
  end
end
