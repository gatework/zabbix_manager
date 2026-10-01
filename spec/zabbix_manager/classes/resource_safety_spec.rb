# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Resource mutation boundaries" do
  let(:client) { instance_double(ZabbixManager::Client, options: {}) }

  before { allow(client).to receive(:with_upsert_lock).and_yield }

  it "validates every new interface before writing any interface" do
    interfaces = ZabbixManager::HostInterfaces.new(client)
    writes = []
    allow(client).to receive(:api_request) do |request|
      if request[:method] == "hostinterface.get"
        []
      else
        writes << request
        { "interfaceids" => ["10"] }
      end
    end

    expect do
      interfaces.reconcile_for_host(hostid: 1, interfaces: [
                                      { type: 1, main: 1, useip: 1, ip: "192.0.2.1", port: "10050" },
                                      { type: 2, main: 1, useip: 1, ip: "192.0.2.2", port: "161",
                                        details: { version: 2 } }
                                    ])
    end.to raise_error(ZabbixManager::Invalid)
    expect(writes).to be_empty
  end

  it "validates every new item before writing any item" do
    items = ZabbixManager::Items.new(client)
    writes = []
    allow(client).to receive(:api_request) do |request|
      if request[:method] == "item.get"
        []
      else
        writes << request
        { "itemids" => ["10"] }
      end
    end

    expect do
      items.upsert_many([
                          { hostid: 1, name: "Uptime", key_: "system.uptime", type: 0, interfaceid: 2 },
                          { hostid: 1, name: "SNMP", key_: "snmp.test", type: 20, interfaceid: 2 }
                        ])
    end.to raise_error(ZabbixManager::Invalid)
    expect(writes).to be_empty
  end

  it "refuses to select an arbitrary host macro when its identity is ambiguous" do
    macros = ZabbixManager::UserMacros.new(client)
    allow(client).to receive(:api_request).and_return([
                                                        { "hostmacroid" => "10", "macro" => "{$TOKEN}" },
                                                        { "hostmacroid" => "11", "macro" => "{$TOKEN}" }
                                                      ])

    expect { macros.get_id(macro: "{$TOKEN}", hostid: 1) }.to raise_error(ZabbixManager::Conflict)
  end

  it "does not collapse nil and empty values when deciding to skip an update" do
    groups = ZabbixManager::HostGroups.new(client)
    writes = []
    allow(client).to receive(:api_request) do |request|
      if request[:method] == "hostgroup.get"
        [{ "groupid" => "1", "name" => "Routers", "description" => "" }]
      else
        writes << request
        { "groupids" => ["1"] }
      end
    end

    expect(groups.update(groupid: 1, description: nil)).to eq(1)
    expect(writes).to eq([{ method: "hostgroup.update", params: [{ groupid: 1, description: nil }] }])
  end

  it "rejects an update without its object ID before making a request" do
    expect(client).not_to receive(:api_request)

    expect { ZabbixManager::HostGroups.new(client).update(name: "Routers") }
      .to raise_error(ZabbixManager::Invalid, /groupid/)
  end
end

RSpec.describe "Resource input types" do
  let(:client) { instance_double(ZabbixManager::Client) }

  it "rejects string booleans for all status operations before any API call" do
    expect(client).not_to receive(:api_request)
    expect { ZabbixManager::Hosts.new(client).set_status([1], enabled: "false") }
      .to raise_error(ZabbixManager::Invalid, /enabled/)
    expect { ZabbixManager::Items.new(client).set_status(hostid: 1, itemids: [2], enabled: "false") }
      .to raise_error(ZabbixManager::Invalid, /enabled/)
    expect { ZabbixManager::Triggers.new(client).set_status(hostid: 1, triggerids: [3], enabled: "false") }
      .to raise_error(ZabbixManager::Invalid, /enabled/)
  end

  it "rejects fractional item types before item.create" do
    expect(client).to receive(:api_request).with(
      method: "item.get", params: { hostids: 1, output: "extend", selectPreprocessing: "extend",
                                    filter: { key_: "uptime" } }
    ).and_return([])
    expect(client).not_to receive(:api_request).with(hash_including(method: "item.create"))
    expect do
      ZabbixManager::Items.new(client).upsert_by_key(
        hostid: 1, name: "Uptime", key_: "uptime", type: 0.9, interfaceid: 2
      )
    end.to raise_error(ZabbixManager::Invalid, /type/)
  end

  it "rejects fractional SNMP versions before creating interfaces" do
    expect(client).not_to receive(:api_request)
    expect do
      ZabbixManager::HostInterfaces.new(client).validate_for_create(
        type: 2, main: 1, useip: 1, ip: "192.0.2.1", port: "161", details: { version: 2.5, community: "token" }
      )
    end.to raise_error(ZabbixManager::Invalid, /version/)
  end

  it "rejects invalid IDs before ownership lookup or mutation" do
    expect(client).not_to receive(:api_request)
    expect { ZabbixManager::Items.new(client).delete_many(hostid: 1, itemids: ["garbage"]) }
      .to raise_error(ZabbixManager::Invalid, /itemids/)
    expect { ZabbixManager::Triggers.new(client).delete_many(hostid: 1, triggerids: [1.5]) }
      .to raise_error(ZabbixManager::Invalid, /triggerids/)
  end
end
