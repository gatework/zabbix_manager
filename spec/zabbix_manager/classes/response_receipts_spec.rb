# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Confirmed resource write receipts" do
  let(:client) { instance_double(ZabbixManager::Client, options: { uncertain_write_delays: [0] }) }

  before { allow(client).to receive(:with_upsert_lock).and_yield }

  [nil, true, {}, { "groupids" => [] }, { "groupids" => [nil] },
   { "groupids" => ["bad"] }, { "groupids" => ["0"] }, { "groupids" => [1.5] }].each do |result|
    it "rejects malformed hostgroup.create receipt #{result.inspect}" do
      allow(client).to receive(:api_request).and_return(result)
      expect { ZabbixManager::HostGroups.new(client).create(name: "Routers") }
        .to raise_error(ZabbixManager::ProtocolError)
    end
  end

  it "rejects an empty host.create receipt rather than returning ID zero" do
    allow(client).to receive(:api_request).and_return("hostids" => [])
    expect do
      ZabbixManager::Hosts.new(client).create(
        host: "router", groups: [{ groupid: 1 }],
        interfaces: [{ type: 1, main: 1, useip: 1, ip: "192.0.2.1", port: "10050" }]
      )
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "validates item update receipts instead of returning a remembered ID" do
    allow(client).to receive(:api_request).with(method: "item.get", params: anything)
                                          .and_return([{ "itemid" => "10" }])
    allow(client).to receive(:api_request).with(method: "item.update", params: anything)
                                          .and_return("itemids" => [])
    expect do
      ZabbixManager::Items.new(client).upsert_by_key(hostid: 1, name: "Uptime", key_: "uptime")
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects a malformed lookup ID before attempting an item update" do
    allow(client).to receive(:api_request).with(method: "item.get", params: anything)
                                          .and_return([{ "itemid" => "garbage" }])
    expect(client).not_to receive(:api_request).with(hash_including(method: "item.update"))
    expect do
      ZabbixManager::Items.new(client).upsert_by_key(hostid: 1, name: "Uptime", key_: "uptime")
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "validates interface update receipts instead of returning a remembered ID" do
    allow(client).to receive(:api_request).with(method: "hostinterface.get", params: anything)
                                          .and_return([{ "interfaceid" => "10" }])
    allow(client).to receive(:api_request).with(method: "hostinterface.update", params: anything)
                                          .and_return("interfaceids" => [])
    expect do
      ZabbixManager::HostInterfaces.new(client).reconcile_for_host(hostid: 1,
                                                                   interfaces: [{
                                                                     interfaceid: 10, main: 1
                                                                   }])
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects fractional type on an existing item" do
    allow(client).to receive(:api_request).with(method: "item.get", params: anything)
                                          .and_return([{ "itemid" => "10", "hostid" => "1", "key_" => "uptime" }])
    expect(client).not_to receive(:api_request).with(hash_including(method: "item.update"))
    expect do
      ZabbixManager::Items.new(client).upsert_by_key(hostid: 1, name: "Uptime", key_: "uptime", type: 0.9)
    end.to raise_error(ZabbixManager::Invalid, /type/)
  end

  it "rejects fractional SNMP versions on an existing interface" do
    allow(client).to receive(:api_request).with(method: "hostinterface.get", params: anything)
                                          .and_return([{ "interfaceid" => "10" }])
    expect(client).not_to receive(:api_request).with(hash_including(method: "hostinterface.update"))
    expect do
      ZabbixManager::HostInterfaces.new(client).reconcile_for_host(
        hostid: 1, interfaces: [{ interfaceid: 10, details: { version: 2.5 } }]
      )
    end.to raise_error(ZabbixManager::Invalid, /version/)
  end

  %i[replace_dependencies add_dependencies].each do |operation|
    it "rejects a string ownership bypass flag in #{operation}" do
      expect(client).not_to receive(:api_request)
      expect do
        ZabbixManager::Triggers.new(client).public_send(
          operation, hostid: 1, triggerid: 2, depends_on: [3], allow_cross_host_dependencies: "false"
        )
      end.to raise_error(ZabbixManager::Invalid, /allow_cross_host_dependencies/)
    end
  end

  it "does not turn a denied create into success by reading back another trigger" do
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything)
                                          .and_return([], [{ "triggerid" => "10", "description" => "old",
                                                             "expression" => "old" }])
    allow(client).to receive(:api_request).with(method: "trigger.create", params: anything)
                                          .and_raise(ZabbixManager::ApiError, "denied")
    expect do
      ZabbixManager::Triggers.new(client).upsert_for_host(
        hostid: 1, managed_key: "managed", description: "desired", expression: "last(/r/key)>1"
      )
    end.to raise_error(ZabbixManager::ApiError, "denied")
  end

  it "does not confirm a timed-out create when only the managed key matches" do
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything)
                                          .and_return([], [{ "triggerid" => "10", "description" => "old",
                                                             "expression" => "old" }])
    allow(client).to receive(:api_request).with(method: "trigger.create", params: anything)
                                          .and_raise(ZabbixManager::TransportError, "timeout")
    expect do
      ZabbixManager::Triggers.new(client).upsert_for_host(
        hostid: 1, managed_key: "managed", description: "desired", expression: "last(/r/key)>1"
      )
    end.to raise_error(ZabbixManager::ResultUnknown)
  end

  it "confirms trigger dependencies as well as expressions after a lost create response" do
    persisted = nil
    allow(client).to receive(:api_request) do |method:, params:|
      case method
      when "trigger.create"
        persisted = params.deep_stringify_keys.merge("triggerid" => "10")
        raise ZabbixManager::TransportError, "response lost"
      when "trigger.get"
        next [] unless persisted

        readable = persisted.except("dependencies")
        readable["dependencies"] = persisted["dependencies"] if params[:selectDependencies] == ["triggerid"]
        [readable]
      else
        raise "Unexpected API method #{method}"
      end
    end

    id = ZabbixManager::Triggers.new(client).upsert_for_host(
      hostid: 1, managed_key: "line-bandwidth", description: "Line bandwidth",
      expression: "last(/r/key)>1", dependencies: [{ triggerid: "9" }]
    )
    expect(id).to eq(10)
    expect(client).to have_received(:api_request).with(method: "trigger.create", params: anything).once
  end
end
