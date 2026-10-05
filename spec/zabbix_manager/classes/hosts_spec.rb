# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Hosts do
  let(:client) { instance_double(ZabbixManager::Client, options: {}) }
  let(:hosts) { described_class.new(client) }

  before { allow(client).to receive(:with_upsert_lock).and_yield }

  it "has no experimental mojo methods or hard-coded SNMP community" do
    expect(hosts).not_to respond_to(:mojo_delete)
    expect(hosts).not_to respond_to(:update_mojo)
    expect(hosts.default_options).to eq(status: 0, inventory_mode: 1)
  end

  it "creates a host from explicit groups and interfaces" do
    attributes = {
      host: "router-01",
      groups: [{ groupid: 20 }],
      interfaces: [{
        type: 2, main: 1, useip: 1, ip: "192.0.2.1", dns: "", port: "161",
        details: { version: 2, community: "{$SNMP_COMMUNITY}" }
      }]
    }
    allow(client).to receive(:api_request)
      .with(method: "host.create", params: hash_including(attributes))
      .and_return("hostids" => ["10101"])

    expect(hosts.create(attributes)).to eq(10_101)
  end

  it "requires explicit groups and interfaces for a new host" do
    expect { hosts.create(host: "router-01", groups: []) }.to raise_error(ArgumentError, /groups/)
    expect { hosts.create(host: "router-01", groups: [{ groupid: 20 }]) }.to raise_error(ArgumentError, /interfaces/)
  end

  it "updates host metadata and reconciles existing and new interfaces without mutating input" do
    input = {
      host: "router-01",
      name: "Core router",
      interfaces: [
        { interfaceid: 12, type: 2, main: 1, useip: 1, ip: "192.0.2.10", port: "161" },
        { type: 1, main: 1, useip: 1, ip: "192.0.2.11", port: "10050" }
      ]
    }
    original = Marshal.load(Marshal.dump(input))
    allow(hosts).to receive(:get_id).with(host: "router-01").and_return(10_101)
    allow(client).to receive(:api_request)
      .with(method: "host.update", params: { host: "router-01", name: "Core router", hostid: 10_101 })
      .and_return("hostids" => ["10101"])
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.get", params: { hostids: 10_101, output: "extend" })
      .and_return([{
                    "interfaceid" => "12", "type" => "2", "main" => "1", "useip" => "1",
                    "ip" => "192.0.2.10", "dns" => "", "port" => "161"
                  }])
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.update", params: hash_including(interfaceid: "12",
                                                                   ip: "192.0.2.10"))
      .and_return("interfaceids" => ["12"])
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.create", params: hash_including(hostid: 10_101, ip: "192.0.2.11"))
      .and_return("interfaceids" => ["13"])

    expect(hosts.reconcile(input)).to eq(10_101)
    expect(input).to eq(original)
  end

  it "creates a missing host through the same reconciliation API" do
    input = {
      host: "router-01",
      groups: [{ groupid: 20 }],
      interfaces: [{
        type: 2, main: 1, useip: 1, ip: "192.0.2.1", dns: "", port: "161",
        details: { version: 2, community: "{$SNMP_COMMUNITY}" }
      }]
    }
    allow(hosts).to receive(:get_id).with(host: "router-01").and_return(nil)
    allow(hosts).to receive(:create).with(input).and_return(10_101)

    expect(hosts.reconcile(input)).to eq(10_101)
  end

  it "rejects duplicate desired interfaces before updating the host" do
    interface = { type: 2, main: 0, useip: 1, ip: "192.0.2.20", port: "161" }
    allow(hosts).to receive(:get_id).with(host: "router-01").and_return(10_101)
    expect(client).not_to receive(:api_request)

    expect do
      hosts.reconcile(host: "router-01", interfaces: [interface, interface.dup])
    end.to raise_error(ArgumentError, /duplicate desired interface identity/)
  end

  it "rejects line candidates that resolve to different hosts" do
    allow(client).to receive(:api_request) do |request|
      filter = request.dig(:params, :filter)
      case filter
      when { host: "router-01" }
        [{ "hostid" => "10101", "host" => "router-01" }]
      when { host: "192.0.2.10" }
        [{ "hostid" => "20202", "host" => "router-02" }]
      else
        []
      end
    end

    expect do
      hosts.find_by_candidates(["router-01", "192.0.2.10"])
    end.to raise_error(ZabbixManager::Conflict, /multiple hosts/)
  end
end

RSpec.describe "Host reconciliation preflight" do
  it "rejects invalid new interfaces before changing existing host metadata" do
    client = instance_double(ZabbixManager::Client)
    allow(client).to receive(:with_upsert_lock).and_yield
    writes = []
    allow(client).to receive(:api_request) do |method:, params:|
      case method
      when "host.get"
        [{ "hostid" => "1", "host" => "router-01" }]
      when "hostinterface.get"
        []
      else
        writes << { method: method, params: params }
        { "hostids" => ["1"] }
      end
    end

    interface = { type: 2, main: 1, useip: 1, ip: "192.0.2.1", port: "161", details: { version: 2 } }
    expect do
      ZabbixManager::Hosts.new(client).reconcile(host: "router-01", name: "New name", interfaces: [interface])
    end.to raise_error(ZabbixManager::Invalid, /community/)
    expect(writes).to be_empty
  end
end
