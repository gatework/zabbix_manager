# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "managed line monitoring" do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.4.0", options: { uncertain_write_delays: [] }) }
  let(:manager) do
    Struct.new(:client, :hosts, :items, :triggers).new(
      client, ZabbixManager::Hosts.new(client), ZabbixManager::Items.new(client), ZabbixManager::Triggers.new(client)
    )
  end
  let(:monitoring) { ZabbixManager::Monitoring.new(manager) }
  let(:definition) do
    { line_id: "WAN:A", host: { hostid: 101, host: "router" }, interface_name: "Gi1/0/1", capacity_mbps: 100 }
  end
  let(:inventory) do
    [
      { "itemid" => "1", "hostid" => "101", "name" => "Gi1/0/1 inbound", "key_" => "net.if.in[1]",
        "units" => "bps", "value_type" => "3", "status" => "0" },
      { "itemid" => "2", "hostid" => "101", "name" => "Gi1/0/1 outbound", "key_" => "net.if.out[1]",
        "units" => "bps", "value_type" => "3", "status" => "0" },
      { "itemid" => "3", "hostid" => "101", "name" => "Gi1/0/1 interface speed", "key_" => "net.if.speed[1]",
        "units" => "bps", "value_type" => "3", "status" => "0" },
      { "itemid" => "4", "hostid" => "101", "name" => "Gi1/0/1 operational status", "key_" => "net.if.status[1]",
        "units" => "", "value_type" => "3", "status" => "0" }
    ]
  end
  let(:remote_triggers) { [] }
  let(:requests) { [] }

  before do
    allow(client).to receive(:with_upsert_lock).and_yield
    allow(client).to receive(:api_request) do |method:, params:|
      requests << [method, params]
      case method
      when "host.get"
        [{ "hostid" => "101", "host" => "router" }]
      when "item.get"
        key = params.dig(:filter, :key_)
        key ? inventory.select { |item| Array(key).include?(item["key_"]) } : inventory
      when "item.create"
        item = params.first.deep_stringify_keys.merge("itemid" => "5")
        inventory << item
        { "itemids" => ["5"] }
      when "trigger.get"
        remote_triggers.select do |trigger|
          ids_match = !params[:triggerids] || Array(params[:triggerids]).map(&:to_s).include?(trigger["triggerid"])
          tags_match = Array(params[:tags]).all? do |wanted|
            Array(trigger["tags"]).any? do |tag|
              tag["tag"] == wanted[:tag] &&
                (wanted[:operator] == 1 ? tag["value"] == wanted[:value] : tag["value"].include?(wanted[:value]))
            end
          end
          ids_match && tags_match
        end
      when "trigger.create"
        id = (301 + remote_triggers.length).to_s
        remote_triggers << params.deep_stringify_keys.merge("triggerid" => id)
        { "triggerids" => [id] }
      when "trigger.update"
        updates = params.is_a?(Array) ? params : [params]
        updates.each do |update|
          remote_triggers.find { |trigger| trigger["triggerid"] == update[:triggerid].to_s }
                         .merge!(update.deep_stringify_keys)
        end
        { "triggerids" => updates.map { |update| update[:triggerid].to_s } }
      when "problem.get"
        []
      else
        raise "unexpected request #{method}"
      end
    end
  end

  def full_definition
    definition.merge(
      status: true, speed: true, reachability_target: "192.0.2.2",
      low_traffic: { below_bps: 50, recovery_bps: 1000 },
      comments: "Provider A", event_name: "WAN event", opdata: "Current {ITEM.LASTVALUE1}",
      tags: [{ tag: "service", value: "WAN" }]
    )
  end

  it "previews all four trigger kinds with no writes and resolves references before applying" do
    plan = monitoring.plan_line(full_definition)
    expect(plan[:itemids]).to include(inbound: 1, outbound: 2, speed: 3, status: 4)
    expect(plan[:triggers].keys).to eq(%i[interface_status bandwidth low_traffic reachability])
    expect(plan[:triggers][:bandwidth]).to include(comments: "Provider A", event_name: "WAN event")
    expect(plan[:triggers][:bandwidth][:expression]).to include("last(/router/net.if.speed[1])>0")
    expect(plan[:triggers][:low_traffic][:expression]).to include(
      "avg(/router/net.if.in[1],5m)<50 and avg(/router/net.if.out[1],5m)<50"
    )
    expect(plan[:triggers][:low_traffic][:recovery_expression]).to include(
      "avg(/router/net.if.in[1],5m)>=1000 or avg(/router/net.if.out[1],5m)>=1000"
    )
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "creates status first, wires dependencies, and reuses the same trigger IDs on the next reconciliation" do
    first = monitoring.reconcile_line(full_definition)
    second = monitoring.reconcile_line(full_definition)
    expect(first[:triggerids]).to eq(interface_status: 301, bandwidth: 302, low_traffic: 303, reachability: 304)
    expect(second[:triggerids]).to eq(first[:triggerids])
    expect(first).not_to have_key(:triggerid)
    expect(remote_triggers.drop(1).map { |trigger| trigger["dependencies"] }).to all(eq([{ "triggerid" => 301 }]))
    expect(requests.count { |method, _params| method == "item.create" }).to eq(1)
    expect(requests.count { |method, _params| method == "trigger.create" }).to eq(4)
  end

  it "does not write anything when an explicitly requested status item is missing" do
    expect { monitoring.reconcile_line(full_definition.merge(status: { itemid: 999 })) }
      .to raise_error(ZabbixManager::Conflict, /status/)
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "rejects invalid low hysteresis, status booleans, IP key delimiters and reserved tags before discovery" do
    [
      { low_traffic: { below_bps: 1000, recovery_bps: 50 } },
      { status: "false" }, { reachability_target: "192.0.2.2,1]" },
      { tags: [{ tag: "managed_by", value: "someone_else" }] }
    ].each do |change|
      expect { monitoring.plan_line(definition.merge(change)) }.to raise_error(ZabbixManager::Invalid)
    end
    expect(requests).to be_empty
  end

  it "disables only obsolete owned kinds after all desired writes succeed" do
    monitoring.reconcile_line(full_definition)
    requests.clear
    result = monitoring.reconcile_line(definition)
    expect(result[:triggerids].keys).to eq([:bandwidth])
    expect(remote_triggers.find { |trigger| trigger["triggerid"] == "302" }["status"]).to eq(0)
    expect(remote_triggers.reject { |trigger| trigger["triggerid"] == "302" }.map { |trigger| trigger["status"] })
      .to all(eq(1))
    expect(inventory.map { |item| item["key_"] }).to include("icmpping[192.0.2.2]")
    expect(requests.map(&:first)).not_to include("item.delete", "item.update", "trigger.delete")
  end

  it "does not claim another owner's trigger even when its managed key collides" do
    remote_triggers << {
      "triggerid" => "999", "tags" => [
        { "tag" => "managed_by", "value" => "other" },
        { "tag" => "zabbix_manager_id", "value" => "interface:WAN:A:bandwidth" }
      ]
    }
    expect { monitoring.reconcile_line(definition) }.to raise_error(ZabbixManager::Conflict, /owner/)
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "preserves existing triggers when a later desired write is rejected" do
    monitoring.reconcile_line(full_definition)
    allow(client).to receive(:api_request).with(method: "trigger.update", params: hash_including(priority: 4))
                                          .and_raise(ZabbixManager::ApiError, "denied")
    expect { monitoring.reconcile_line(definition.merge(severity: 4)) }.to raise_error(ZabbixManager::ApiError)
    expect(remote_triggers.map { |trigger| trigger["status"] }).to all(eq(0))
  end

  it "lists and disables only a specific line's owned triggers" do
    monitoring.reconcile_line(definition)
    remote_triggers << { "triggerid" => "999", "tags" => [{ "tag" => "manual", "value" => "WAN" }] }
    result = monitoring.line_triggers(hostid: 101, line_id: "WAN:A")
    expect(result.pluck("triggerid")).to eq(["301"])
    expect(monitoring.disable_line(hostid: 101, line_id: "WAN:A")).to eq([301])
    expect(remote_triggers.last).not_to have_key("status")
  end

  it "scopes bounded problem retrieval to managed trigger IDs before applying the remote limit" do
    monitoring.reconcile_line(definition)
    monitoring.line_problems(hostid: 101, line_id: "WAN:A", time_from: 1_000_000, time_till: 1_001_000, limit: 10)
    expect(requests.last.first).to eq("problem.get")
    expect(requests.last.last).to include(objectids: ["301"], time_from: 1_000_000, time_till: 1_001_000, limit: 11)
    expect do
      monitoring.line_problems(hostid: 101, line_id: "WAN:A", time_from: 2, time_till: 1)
    end.to raise_error(ZabbixManager::Invalid, /after/)
  end

  it "uses legacy expression syntax consistently for all optional kinds on Zabbix 5.0" do
    allow(client).to receive(:api_version).and_return("5.0.48")
    plan = monitoring.plan_line(full_definition.except(:event_name))
    expect(plan[:triggers][:interface_status][:expression]).to eq("{router:net.if.status[1].last()}<>1")
    expect(plan[:triggers][:low_traffic][:expression]).to include("{router:net.if.in[1].avg(5m)}<50")
    expect(plan[:triggers][:reachability][:expression]).to eq("{router:icmpping[192.0.2.2].max(5m)}=0")
  end

  it "preflights native trigger metadata version requirements before any ICMP or trigger write" do
    [["4.0.50", :opdata, "4.4"], ["5.0.48", :event_name, "5.2"]].each do |version, field, required|
      allow(client).to receive(:api_version).and_return(version)
      input = definition.merge(reachability_target: "192.0.2.2", field => "Operator context")
      expect { monitoring.reconcile_line(input) }.to raise_error(ZabbixManager::Invalid, /#{field}.*#{required}/)
    end
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "allows explicit status and speed references without guessing custom names" do
    inventory[2].merge!("name" => "Link capacity", "key_" => "custom.speed")
    inventory[3].merge!("name" => "Link state", "key_" => "custom.state")
    plan = monitoring.plan_line(full_definition.merge(speed: { itemid: 3 }, status: { itemid: 4 }))
    expect(plan[:triggers][:bandwidth][:expression]).to include("last(/router/custom.speed)>0")
    expect(plan[:triggers][:interface_status][:expression]).to eq("last(/router/custom.state)<>1")
  end

  it "keeps optional false selectors off and accepts IPv6 without allowing item key injection" do
    plan = monitoring.plan_line(definition.merge(status: false, speed: false, reachability_target: "2001:db8::1"))
    expect(plan[:triggers].keys).to eq(%i[bandwidth reachability])
    expect(plan[:icmp_item][:attributes][:key_]).to eq("icmpping[2001:db8::1]")
  end

  it "rejects ambiguous speed discovery before creating an ICMP item or any trigger" do
    inventory << inventory[2].merge("itemid" => "8", "key_" => "net.if.speed[2]")
    expect { monitoring.reconcile_line(full_definition) }.to raise_error(ZabbixManager::Conflict, /one speed/)
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "refuses nonnumeric traffic, disabled references, and cross-host discovery" do
    original = inventory[0].dup
    [
      [{ "value_type" => "4" }, ZabbixManager::Invalid],
      [{ "status" => "1" }, ZabbixManager::Conflict],
      [{ "hostid" => "999" }, ZabbixManager::ProtocolError]
    ].each do |change, error|
      inventory[0] = original.merge(change)
      expect { monitoring.plan_line(definition) }.to raise_error(error)
    end
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "reuses an existing shared ICMP check without changing its name or retention" do
    inventory << { "hostid" => "101", "itemid" => "5", "key_" => "icmpping[192.0.2.2]", "type" => "3",
                   "name" => "Shared target", "value_type" => "3", "status" => "0", "history" => "7d" }
    result = monitoring.reconcile_line(full_definition)
    expect(result[:itemids][:reachability]).to eq(5)
    expect(inventory.last).to include("name" => "Shared target", "history" => "7d")
    expect(requests.map(&:first)).not_to include("item.create", "item.update")
  end

  it "refuses to enable a disabled shared ICMP check" do
    inventory << { "hostid" => "101", "itemid" => "5", "key_" => "icmpping[192.0.2.2]", "type" => "3",
                   "name" => "Shared target", "value_type" => "3", "status" => "1" }
    expect { monitoring.reconcile_line(full_definition) }.to raise_error(ZabbixManager::Conflict, /enabled/)
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "rejects duplicate input identities before discovery and ambiguous managed identities before writes" do
    expect { monitoring.reconcile_lines([definition, definition]) }.to raise_error(ZabbixManager::Invalid, /duplicate/)
    expect(requests).to be_empty
    monitoring.reconcile_line(definition)
    remote_triggers << remote_triggers.first.merge("triggerid" => "999")
    requests.clear
    expect { monitoring.reconcile_line(definition) }.to raise_error(ZabbixManager::Conflict, /same line managed key/)
    expect(requests.map(&:first)).to all(end_with(".get"))
  end

  it "does not treat missing ownership evidence as an empty managed inventory" do
    remote_triggers << { "triggerid" => "999", "tags" => nil }
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything).and_return(remote_triggers)
    expect { monitoring.disable_line(hostid: 101, line_id: "WAN:A") }
      .to raise_error(ZabbixManager::ProtocolError, /tags/)
  end

  it "never retires a different endpoint whose line ID shares a prefix" do
    monitoring.reconcile_line(full_definition.merge(line_id: "WAN:A:backup"))
    expect(monitoring.disable_line(hostid: 101, line_id: "WAN:A")).to eq([])
    expect(remote_triggers.map { |trigger| trigger["status"] }).to all(eq(0))
  end

  it "keeps a partially confirmed line unknown when a later create response is lost, without replay" do
    allow(client).to receive(:api_request)
      .with(method: "trigger.create", params: hash_including(expression: include(">90000000")))
      .and_raise(ZabbixManager::TransportError, "response lost")
    result = monitoring.reconcile_lines([full_definition]).first
    expect(result[:status]).to eq(:unknown)
    expect(remote_triggers.map { |trigger| trigger["description"] }).to eq(["Gi1/0/1 interface down"])
    expect(client).to have_received(:api_request)
      .with(method: "trigger.create", params: hash_including(expression: include(">90000000"))).once
    expect(requests.map(&:first)).not_to include("trigger.update", "trigger.delete")
  end

  it "exposes problem truncation and preserves native event IDs instead of inventing history" do
    monitoring.reconcile_line(definition)
    events = [
      { "eventid" => "500", "objectid" => "301", "clock" => "1000100" },
      { "eventid" => "499", "objectid" => "301", "clock" => "1000050" }
    ]
    allow(client).to receive(:api_request).with(method: "problem.get", params: anything).and_return(events)
    result = monitoring.line_problems(hostid: 101, line_id: "WAN:A", time_from: Time.at(1_000_000),
                                      time_till: Time.at(1_001_000), limit: 1)
    expect(result).to include(problems: [events.first], truncated: true, limit: 1)
    events.first["objectid"] = "999"
    expect do
      monitoring.line_problems(hostid: 101, line_id: "WAN:A", time_from: 1_000_000, time_till: 1_001_000)
    end.to raise_error(ZabbixManager::ProtocolError, /outside/)
  end

  it "returns an explicit empty problem page without querying all host problems" do
    expect(monitoring.line_problems(hostid: 101, line_id: "WAN:A", time_from: 0, time_till: 1))
      .to eq(problems: [], truncated: false, time_from: 0, time_till: 1, limit: 100)
    expect(requests.map(&:first)).not_to include("problem.get")
  end

  it "serializes overlapping reconciliations without nesting the resource stripe locks" do
    entered = Queue.new
    release = Queue.new
    original_create = nil
    allow(client).to receive(:api_request).with(method: "trigger.create", params: anything) do |method:, params:|
      unless original_create
        original_create = true
        entered << true
        release.pop
      end
      requests << [method, params]
      id = (301 + remote_triggers.length).to_s
      remote_triggers << params.deep_stringify_keys.merge("triggerid" => id)
      { "triggerids" => [id] }
    end
    first = Thread.new { monitoring.reconcile_line(full_definition) }
    entered.pop
    second = Thread.new { monitoring.reconcile_line(definition) }
    Timeout.timeout(2) { Thread.pass until second.status == "sleep" }
    release << true
    Timeout.timeout(2) { [first, second].each(&:value) }
    expect(remote_triggers.count { |trigger| trigger["status"] == 0 }).to eq(1)
    expect(remote_triggers.length).to eq(4)
    expect(client).not_to have_received(:with_upsert_lock).with(start_with("line:"))
  ensure
    release << true if release
    [first, second].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end
end
