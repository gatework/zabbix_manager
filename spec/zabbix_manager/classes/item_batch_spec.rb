# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Items, "batch preflight" do
  let(:client) { instance_double(ZabbixManager::Client) }
  let(:items) { described_class.new(client) }
  let(:requests) { [] }
  let(:existing) { [] }

  def definition(key, hostid: 101)
    { hostid: hostid, key_: key, name: key, type: 3, value_type: 3 }
  end

  before do
    allow(client).to receive(:api_request) do |method:, params:|
      requests << [method, params.deep_dup]
      case method
      when "item.get"
        existing.select do |item|
          Array(params[:hostids]).map(&:to_s).include?(item["hostid"]) &&
            Array(params.dig(:filter, :key_)).include?(item["key_"])
        end
      when "item.create" then { "itemids" => [requests.length.to_s] }
      when "item.update" then { "itemids" => [params.fetch(:itemid)] }
      else raise "unexpected request #{method}"
      end
    end
  end

  it "reads each host once and preserves write order for mixed existing and new items" do
    existing << { "hostid" => "101", "itemid" => "90", "key_" => "second", "type" => "3", "value_type" => "3" }
    definitions = [definition("first"), definition("third", hostid: 102), definition("second")]

    ids = items.upsert_many(definitions)

    reads = requests.select { |method, _params| method == "item.get" }
    writes = requests.reject { |method, _params| method == "item.get" }
    expect(reads.length).to eq(2)
    expect(writes.map { |_method, params| params[:key_] }).to eq(%w[first third second])
    expect(ids.last).to eq(90)
    expect(writes.first(2).map(&:first)).to eq(%w[item.create item.create])
    expect(writes.last.first).to eq("item.update")
  end

  it "snapshots caller definitions before the effective configuration callback" do
    definitions = [definition(+"first"), definition(+"second")]

    items.upsert_many(definitions) { definitions.last[:key_].clear }

    writes = requests.reject { |method, _params| method == "item.get" }
    expect(writes.map { |_method, params| params[:key_] }).to eq(%w[first second])
    expect(definitions.last[:key_]).to eq("")
  end

  [nil, {}, [nil], [{ "itemid" => "9", "hostid" => "999", "key_" => "first" }],
   [{ "itemid" => "9", "hostid" => "101", "key_" => "unexpected" }]].each do |rows|
    it "rejects malformed or out-of-scope preflight responses #{rows.inspect} without writes" do
      allow(client).to receive(:api_request).with(method: "item.get", params: anything).and_return(rows)
      expect(client).not_to receive(:api_request).with(method: "item.create", params: anything)
      expect(client).not_to receive(:api_request).with(method: "item.update", params: anything)

      expect { items.upsert_many([definition("first"), definition("second")]) }
        .to raise_error(ZabbixManager::ProtocolError)
    end
  end

  it "rejects a remote item ID reused across host groups before any write" do
    existing.concat([101, 102].map { |hostid| { "hostid" => hostid.to_s, "itemid" => "9", "key_" => "first" } })
    expect(client).not_to receive(:api_request).with(method: "item.update", params: anything)

    expect { items.upsert_many([definition("first"), definition("first", hostid: 102)]) }
      .to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects duplicate remote keys before any write" do
    existing.concat([9, 10].map { |id| { "hostid" => "101", "itemid" => id.to_s, "key_" => "first" } })
    expect(client).not_to receive(:api_request).with(method: "item.create", params: anything)

    expect { items.upsert_many([definition("first"), definition("second")]) }
      .to raise_error(ZabbixManager::Conflict)
  end
end

RSpec.describe "Single-host resource boundaries" do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.4.0") }

  [[], [101, 202], {}, 1.5, true, 0, -1, "invalid"].each do |hostid|
    it "rejects #{hostid.inspect} before ownership queries or writes" do
      allow(client).to receive(:with_upsert_lock).and_yield
      expect(client).not_to receive(:api_request)
      items = ZabbixManager::Items.new(client)
      triggers = ZabbixManager::Triggers.new(client)
      interfaces = ZabbixManager::HostInterfaces.new(client)
      operations = [
        -> { items.delete_many(hostid: hostid, itemids: [1]) },
        -> { items.set_status(hostid: hostid, itemids: [1], enabled: true) },
        -> { triggers.delete_many(hostid: hostid, triggerids: [1]) },
        -> { triggers.set_status(hostid: hostid, triggerids: [1], enabled: true) },
        -> { triggers.replace_dependencies(hostid: hostid, triggerid: 1, depends_on: []) },
        -> { interfaces.delete_many(hostid: hostid, interfaceids: [1]) },
        -> { interfaces.reconcile_for_host(hostid: hostid, interfaces: []) }
      ]

      operations.each { |operation| expect(&operation).to raise_error(ZabbixManager::Invalid, /hostid/) }
    end
  end
end
