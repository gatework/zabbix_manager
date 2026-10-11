# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Canonical resource identities" do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.0.0", options: {}) }

  it "canonicalizes an update ID before writing and checking its receipt" do
    expect(client).to receive(:api_request).with(
      method: "hostgroup.get", params: { filter: { groupid: "1" }, output: "extend" }
    ).and_return([])
    expect(client).to receive(:api_request).with(
      method: "hostgroup.update", params: [{ groupid: "1", name: "Routers" }]
    ).and_return("groupids" => ["1"])

    expect(ZabbixManager::HostGroups.new(client).update(groupid: "+01", name: "Routers")).to eq(1)
  end

  it "canonicalizes role IDs before writing" do
    expect(client).to receive(:api_request).with(
      method: "role.update", params: { roleid: "1", rules: { "ui.default_access": 0 } }
    ).and_return("roleids" => ["1"])
    expect(ZabbixManager::Roles.new(client).rules(roleid: "+01", rules: { "ui.default_access" => 0 })).to eq(1)
  end

  it "canonicalizes both kinds of macro update IDs" do
    macros = ZabbixManager::UserMacros.new(client)
    %w[host global].each do |scope|
      id_field = "#{scope}macroid"
      operation = scope == "host" ? "update" : "updateglobal"
      expect(client).to receive(:api_request).with(
        method: "usermacro.#{operation}", params: { id_field.to_sym => "1", value: "new" }
      ).and_return("#{id_field}s" => ["1"])
      method = scope == "host" ? :update : :update_global
      expect(macros.public_send(method, id_field => "+01", "value" => "new")).to eq(1)
    end
  end

  it "sends a deduplicated canonical user media update" do
    expect(client).to receive(:api_request).with(
      method: "user.update", params: [{ userid: "1", medias: [] }]
    ).and_return("userids" => ["1"])
    expect(ZabbixManager::Users.new(client).update_medias(userids: ["+01", "1"], media: [])).to eq(1)
  end

  it "canonicalizes explicit host IDs in high-level resource queries" do
    requests = []
    allow(client).to receive(:api_request) do |**request|
      requests << request
      []
    end
    ZabbixManager::Items.new(client).for_host("+01")
    ZabbixManager::Items.new(client).monitored_traffic_candidates("+01")
    ZabbixManager::Triggers.new(client).for_host("+01")
    ZabbixManager::Triggers.new(client).find_for_host(hostid: "+01", description: "Loss")
    ZabbixManager::Hosts.new(client).find_by_id("+01")

    expect(requests.map { |request| request[:params][:hostids] || request[:params].dig(:filter, :hostid) })
      .to eq(["1", ["1"], "1", "1", "1"])
  end

  it "uses one interface lock for all spellings of a host ID" do
    interfaces = ZabbixManager::HostInterfaces.new(client)
    expect(client).to receive(:with_upsert_lock).with("host-interfaces:1").exactly(3).times.and_yield
    allow(client).to receive(:api_request).and_return([])
    [1, "01", "+1"].each { |id| interfaces.reconcile_for_host(hostid: id, interfaces: []) }
  end

  it "uses one trigger lock for all spellings of a host ID" do
    triggers = ZabbixManager::Triggers.new(client)
    expect(client).to receive(:with_upsert_lock).with("trigger:1:uptime").exactly(3).times.and_yield
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything).and_return([])
    allow(client).to receive(:api_request).with(method: "trigger.create", params: anything)
                                          .and_return("triggerids" => ["2"])
    [1, "01", "+1"].each do |id|
      triggers.upsert_for_host(hostid: id, description: "uptime", expression: "last(/router/uptime)=0")
    end
  end

  it "matches equivalent interface numeric fields instead of creating another endpoint" do
    existing = { "interfaceid" => "10", "type" => "1", "main" => "1", "useip" => "1",
                 "ip" => "192.0.2.1", "dns" => "", "port" => "10050" }
    allow(client).to receive(:with_upsert_lock).and_yield
    expect(client).to receive(:api_request).with(method: "hostinterface.get", params: anything).and_return([existing])
    expect(client).to receive(:api_request).with(method: "hostinterface.update", params: anything)
                                           .and_return("interfaceids" => ["10"])
    expect(client).not_to receive(:api_request).with(method: "hostinterface.create", params: anything)
    expect(ZabbixManager::HostInterfaces.new(client).reconcile_for_host(
             hostid: 1, interfaces: [{ type: "+01", main: 1, useip: "+01", ip: "192.0.2.1", port: "10050" }]
           )).to eq([10])
  end
end
