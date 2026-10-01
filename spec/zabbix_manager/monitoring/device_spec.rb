# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Monitoring::Device do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.4.0") }
  let(:manager) do
    instance_double(
      ZabbixManager, client: client, hosts: ZabbixManager::Hosts.new(client),
                     host_interfaces: ZabbixManager::HostInterfaces.new(client), host_groups: ZabbixManager::HostGroups.new(client),
                     templates: ZabbixManager::Templates.new(client), user_macros: ZabbixManager::UserMacros.new(client),
                     proxies: ZabbixManager::Proxies.new(client), proxy_groups: ZabbixManager::ProxyGroups.new(client)
    )
  end
  let(:definition) do
    { host: "router-01", name: "Router", groups: ["Networks"], templates: ["Generic SNMP"],
      proxy_group: "HQ", snmp: { ip: "192.0.2.1", community: "secret-community" },
      tags: [{ tag: "inventory.owner", value: "network" }], inventory: { serialno_a: "SERIAL-1" } }
  end

  def remote_host(**changes)
    { "hostid" => "42", "host" => "router-01", "hostgroups" => [{ "groupid" => "2" }],
      "parentTemplates" => [{ "templateid" => "3" }], "tags" => [], "interfaces" => [] }.merge(
        changes.transform_keys(&:to_s)
      )
  end

  def writes
    @requests.reject { |request| request[:method].end_with?(".get") }
  end

  before do
    @requests = []
    @hosts = []
    @interfaces = []
    @macros = []
    allow(client).to receive(:with_upsert_lock).and_yield
    allow(client).to receive(:api_request) do |method:, params:|
      @requests << { method: method, params: params.deep_dup }
      case method
      when "host.get" then @hosts.deep_dup
      when "hostgroup.get" then [{ "groupid" => "2", "name" => "Networks" }]
      when "template.get" then [{ "templateid" => "3", "host" => "Generic SNMP" }]
      when "proxygroup.get" then [{ "proxy_groupid" => "5", "name" => "HQ" }]
      when "proxy.get" then [{ "proxyid" => "4", "name" => "Edge", "host" => "Edge" }]
      when "hostinterface.get" then @interfaces.deep_dup
      when "usermacro.get" then @macros.deep_dup
      when "host.create", "host.update" then { "hostids" => ["42"] }
      when "hostinterface.create", "hostinterface.update" then { "interfaceids" => ["71"] }
      when "usermacro.create", "usermacro.update" then { "hostmacroids" => ["81"] }
      else raise "Unexpected method #{method}"
      end
    end
  end

  it "resolves named dependencies and creates secret SNMP macro and proxy-group routing in one host call" do
    input = definition.deep_dup
    result = described_class.new(definition).reconcile(manager)

    expect(writes).to contain_exactly(hash_including(method: "host.create"))
    attributes = writes.first[:params]
    expect(attributes).to include(
      host: "router-01", groups: [{ groupid: "2" }], templates: [{ templateid: "3" }],
      monitored_by: 2, proxy_groupid: 5, inventory: { serialno_a: "SERIAL-1" },
      macros: [{ macro: "{$SNMP_COMMUNITY}", value: "secret-community", type: 1 }]
    )
    expect(attributes[:interfaces].first[:details]).to eq(version: 2, bulk: 1, community: "{$SNMP_COMMUNITY}")
    expect(result).to eq(hostid: 42, enabled: true,
                         managed: { group_ids: ["2"], template_ids: ["3"], tag_names: ["inventory.owner"] })
    expect(definition).to eq(input)
    expect(result.inspect).not_to include("secret-community")
    expect(described_class.new(definition).inspect).not_to include("secret-community")
  end

  it "removes previous managed memberships while preserving unrelated memberships and tags" do
    @hosts = [remote_host(hostgroups: [{ "groupid" => "6" }, { "groupid" => "9" }],
                          parentTemplates: [{ "templateid" => "7" }, { "templateid" => "8" }],
                          tags: [{ "tag" => "inventory.old", "value" => "old", "automatic" => "0" },
                                 { "tag" => "operator", "value" => "noc", "automatic" => "0" }])]
    input = definition.except(:snmp).merge(
      managed: { group_ids: [6], template_ids: [7], tag_names: ["inventory.old"] }
    )

    result = described_class.new(input).reconcile(manager)

    attributes = writes.last[:params].first
    expect(attributes[:groups]).to eq([{ groupid: "9" }, { groupid: "2" }])
    expect(attributes[:templates]).to eq([{ templateid: "8" }, { templateid: "3" }])
    expect(attributes[:tags]).to eq([{ tag: "operator", value: "noc" },
                                     { tag: "inventory.owner", value: "network" }])
    expect(result[:managed]).to eq(group_ids: ["2"], template_ids: ["3"], tag_names: ["inventory.owner"])
  end

  it "updates the unique main SNMP interface when its address changes and preserves unrelated macros" do
    @interfaces = [{ "interfaceid" => "71", "type" => "2", "main" => "1", "useip" => "1",
                     "ip" => "192.0.2.9", "dns" => "", "port" => "161" }]
    @hosts = [remote_host(interfaces: @interfaces)]
    @macros = [{ "hostmacroid" => "81" }]

    described_class.new(definition).reconcile(manager)

    expect(writes.map { |request| request[:method] }).to eq(%w[usermacro.update hostinterface.update host.update])
    expect(writes[0][:params]).to include(hostmacroid: 81, macro: "{$SNMP_COMMUNITY}", type: 1)
    expect(writes[1][:params]).to include(interfaceid: "71", ip: "192.0.2.1")
    expect(writes[2][:params].first).not_to have_key(:macros)
    expect(writes[2][:params].first).not_to have_key(:interfaces)
  end

  it "does not change memberships omitted from a partial update or lose the previous managed receipt" do
    @hosts = [remote_host]
    previous = { group_ids: [2], template_ids: [3], tag_names: ["owner"] }

    result = described_class.new(host: "router-01", name: "New name", managed: previous).reconcile(manager)

    expect(writes.last[:params].first).to eq(host: "router-01", name: "New name", status: 0, hostid: "42")
    expect(result[:managed]).to eq(group_ids: ["2"], template_ids: ["3"], tag_names: ["owner"])
  end

  it "disables an existing host without requiring credentials or configured templates" do
    @hosts = [remote_host]

    result = described_class.new(host: "router-01", enabled: false).reconcile(manager)

    expect(writes).to eq([{ method: "host.update", params: [{ hostid: "42", status: 1 }] }])
    expect(result).to include(hostid: 42, enabled: false)
  end

  it "reports an absent disabled host without creating it" do
    result = described_class.new(host: "router-01", enabled: false).reconcile(manager)

    expect(result).to eq(hostid: nil, enabled: false,
                         managed: { group_ids: [], template_ids: [], tag_names: [] })
    expect(writes).to be_empty
  end

  it "supports native interface definitions and ID references without name lookups" do
    input = { host: "router-01", groups: [{ groupid: 2 }], templates: [], proxy: { proxyid: 4 },
              interfaces: [{ type: 1, main: 1, useip: 0, dns: "router.example", port: "10050" }] }

    described_class.new(input).reconcile(manager)

    expect(@requests.map { |request| request[:method] }).to eq(%w[host.get host.get host.create])
    expect(writes.first[:params]).to include(monitored_by: 1, proxyid: 4)
  end

  it "maps a proxy to the native pre-7.0 host field" do
    allow(client).to receive(:api_version).and_return("6.0.0")

    described_class.new(definition.except(:proxy_group).merge(proxy: "Edge")).reconcile(manager)

    expect(writes.first[:params]).to include(proxy_hostid: 4)
    expect(writes.first[:params]).not_to have_key(:monitored_by)
  end

  it "rejects a missing named template before creating or updating anything" do
    @hosts = [remote_host]

    expect do
      described_class.new(definition.merge(templates: ["Missing"])).reconcile(manager)
    end.to raise_error(ZabbixManager::ApiError, /template/)
    expect(writes).to be_empty
  end

  it "rejects unsupported proxy groups before any mutation" do
    allow(client).to receive(:api_version).and_return("6.0.0")

    expect { described_class.new(definition).reconcile(manager) }.to raise_error(ZabbixManager::Invalid, /version/)
    expect(writes).to be_empty
  end

  it "rejects secret macros on servers that do not support them" do
    allow(client).to receive(:api_version).and_return("4.4.0")

    expect do
      described_class.new(definition.except(:proxy_group)).reconcile(manager)
    end.to raise_error(ZabbixManager::Invalid, /macro type/)
    expect(writes).to be_empty
  end

  it "rejects ambiguous primary SNMP interfaces before even writing the secret macro" do
    @hosts = [remote_host(interfaces: [{ "interfaceid" => "71", "type" => "2", "main" => "1" },
                                       { "interfaceid" => "72", "type" => "2", "main" => "1" }])]

    expect { described_class.new(definition).reconcile(manager) }.to raise_error(ZabbixManager::Conflict, /SNMP/)
    expect(writes).to be_empty
  end

  it "preflights explicit interface ownership before macro or host writes" do
    @hosts = [remote_host]
    input = definition.merge(snmp: definition[:snmp].merge(interfaceid: 999))

    expect { described_class.new(input).reconcile(manager) }.to raise_error(ZabbixManager::Invalid, /belong/)
    expect(writes).to be_empty
  end

  it "preflights every macro identity before writing any macro" do
    @hosts = [remote_host]
    @macros = [{ "hostmacroid" => "81" }, { "hostmacroid" => "82" }]

    expect do
      described_class.new(definition.except(:snmp).merge(macros: [{ macro: "{$A}", value: "secret" }]))
                     .reconcile(manager)
    end.to raise_error(ZabbixManager::Conflict, /macros/)
    expect(writes).to be_empty
  end

  it "refuses an incomplete snapshot instead of removing unknown memberships" do
    @hosts = [remote_host.except("hostgroups")]

    expect { described_class.new(definition).reconcile(manager) }.to raise_error(ZabbixManager::ProtocolError, /groups/)
    expect(writes).to be_empty
  end

  it "does not replay or replace a host creation after an uncertain write" do
    allow(client).to receive(:api_request).with(method: "host.create", params: anything)
                                          .and_raise(ZabbixManager::ResultUnknown, "unconfirmed")

    expect { described_class.new(definition).reconcile(manager) }.to raise_error(ZabbixManager::ResultUnknown)
    expect(client).to have_received(:api_request).with(method: "host.create", params: anything).once
    expect(client).not_to have_received(:api_request).with(method: "host.update", params: anything)
  end

  it "rejects invalid local shapes and conflicts without querying the API" do
    invalid = [
      { enabled: nil }, { enabled: "false" }, { enabled: false, status: 0 }, { managed: nil },
      { groups: [0] }, { inventory: [] }, { tags: [{ tag: "x", value: nil }] },
      { proxy: "Edge", proxy_group: "HQ" }, { proxy: "Edge", proxyid: 4 },
      { snmp: { ip: "192.0.2.1", dns: "router", community: "secret" } },
      { snmp: { ip: "192.0.2.1", community: "secret", version: 3 } },
      { snmp: { ip: "192.0.2.1", community: "secret", port: 0 } },
      { interfaces: [{ interfaceid: 0 }] },
      { macros: [{ macro: "{$SNMP_COMMUNITY}", value: "secret" }] }
    ]
    invalid.each do |change|
      expect { described_class.new(definition.merge(change)) }.to raise_error(ZabbixManager::Invalid)
    end
    expect(@requests).to be_empty
  end
  it "rejects malformed interface details before any macro or interface mutation" do
    @interfaces = [{ "interfaceid" => "71" }]
    @hosts = [remote_host(interfaces: @interfaces)]
    input = { host: "router-01", interfaces: [{ interfaceid: 71, details: 1 }],
              macros: [{ macro: "{$SECRET}", value: "secret", type: 1 }] }

    expect { described_class.new(input).reconcile(manager) }.to raise_error(ZabbixManager::Invalid, /details/)
    expect(writes).to be_empty
  end

  it "rejects a desired tag name with a different unowned value before changing macros" do
    @hosts = [remote_host(tags: [{ "tag" => "inventory.owner", "value" => "operator" }])]

    expect { described_class.new(definition).reconcile(manager) }.to raise_error(ZabbixManager::Conflict, /tag/)
    expect(writes).to be_empty
  end

  it "can adopt an identical tag pair without duplicating it" do
    @hosts = [remote_host(tags: [{ "tag" => "inventory.owner", "value" => "network" }])]

    result = described_class.new(definition.except(:snmp)).reconcile(manager)

    expect(writes.last[:params].first[:tags]).to eq([{ tag: "inventory.owner", value: "network" }])
    expect(result[:managed][:tag_names]).to eq(["inventory.owner"])
  end
  it "rechecks a host created by another caller and preserves its unmanaged memberships" do
    existing = remote_host(hostgroups: [{ "groupid" => "9" }])
    allow(client).to receive(:api_request).with(method: "host.get", params: anything)
                                          .and_return([], [existing], [existing])

    result = described_class.new(definition.except(:snmp).merge(
                                   interfaces: [{ type: 1, main: 1, useip: 1, ip: "192.0.2.1", port: "10050" }]
                                 )).reconcile(manager)

    expect(result[:hostid]).to eq(42)
    expect(writes.map { |request| request[:method] }).not_to include("host.create")
    expect(writes.last[:params].first[:groups]).to eq([{ groupid: "9" }, { groupid: "2" }])
  end

  it "keeps a caller's validated definition independent of subsequent string mutations" do
    definition[:host] = definition[:host].dup
    definition[:snmp][:community] = definition[:snmp][:community].dup
    device = described_class.new(definition)
    definition[:host].replace("other-host")
    definition[:snmp][:community].replace("different-secret")

    device.reconcile(manager)

    expect(writes.first[:params][:host]).to eq("router-01")
    expect(writes.first[:params][:macros].first[:value]).to eq("secret-community")
  end

  it "keeps explicit empty templates as removal of previously managed templates only" do
    @hosts = [remote_host(parentTemplates: [{ "templateid" => "3" }, { "templateid" => "8" }])]

    result = described_class.new(host: "router-01", templates: [], managed: { template_ids: [3] }).reconcile(manager)

    expect(writes.last[:params].first[:templates]).to eq([{ templateid: "8" }])
    expect(result[:managed][:template_ids]).to eq([])
  end

  it "accepts native user-macro ports without coercing them to integers" do
    input = definition.except(:snmp).merge(
      interfaces: [{ type: 1, main: 1, useip: 0, dns: "router.example", port: "{$AGENT_PORT}" }]
    )

    described_class.new(input).reconcile(manager)

    expect(writes.first[:params][:interfaces].first[:port]).to eq("{$AGENT_PORT}")
  end

  it "does not report a creation whose receipt does not contain a valid ID" do
    allow(client).to receive(:api_request).with(method: "host.create", params: anything)
                                          .and_return("hostids" => ["bad-id"])

    expect { described_class.new(definition).reconcile(manager) }.to raise_error(ZabbixManager::ProtocolError)
    expect(client).to have_received(:api_request).with(method: "host.create", params: anything).once
  end

  it "stops at an uncertain macro write without touching interfaces or host metadata" do
    @hosts = [remote_host]
    allow(client).to receive(:api_request).with(method: "usermacro.create", params: anything)
                                          .and_raise(ZabbixManager::ResultUnknown, "unconfirmed")

    expect { described_class.new(definition).reconcile(manager) }.to raise_error(ZabbixManager::ResultUnknown)
    expect(client).to have_received(:api_request).with(method: "usermacro.create", params: anything).once
    expect(client).not_to have_received(:api_request).with(method: "hostinterface.create", params: anything)
    expect(client).not_to have_received(:api_request).with(method: "host.update", params: anything)
  end
end
