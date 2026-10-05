# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::UserMacros do
  let(:client) { instance_double(ZabbixManager::Client) }
  let(:macros) { described_class.new(client) }

  it "queries a host macro within its explicit host boundary" do
    expect(client).to receive(:api_request).with(
      method: "usermacro.get", params: { hostids: 1, filter: { macro: "{$TOKEN}" } }
    ).and_return([{ "hostmacroid" => "10" }])

    expect(macros.get_id("hostid" => 1, "macro" => "{$TOKEN}")).to eq(10)
  end

  it "rejects a host macro lookup without its host" do
    expect(client).not_to receive(:api_request)
    expect { macros.get_id(macro: "{$TOKEN}") }.to raise_error(KeyError, /hostid/)
  end

  it "does not add a host filter to global macro lookups" do
    expect(client).to receive(:api_request).with(
      method: "usermacro.get", params: { globalmacro: true, filter: { macro: "{$TOKEN}" } }
    ).and_return([{ "globalmacroid" => "20" }])

    expect(macros.get_id_global(macro: "{$TOKEN}")).to eq(20)
  end

  it "returns nil for a missing global macro" do
    allow(client).to receive(:api_request).and_return([])
    expect(macros.get_id_global(macro: "{$MISSING}")).to be_nil
  end

  it "rejects ambiguous global macro identities" do
    allow(client).to receive(:api_request).and_return([{ "globalmacroid" => "20" }, { "globalmacroid" => "21" }])
    expect { macros.get_id_global(macro: "{$TOKEN}") }.to raise_error(ZabbixManager::Conflict)
  end

  it "updates an existing host macro using its real ID and retains caller data" do
    data = { "hostid" => 1, "macro" => "{$TOKEN}", "value" => "new" }
    expect(client).to receive(:api_request).with(
      method: "usermacro.get", params: { hostids: 1, filter: { macro: "{$TOKEN}" } }
    ).and_return([{ "hostmacroid" => "10" }])
    expect(client).to receive(:api_request).with(
      method: "usermacro.update", params: { hostid: 1, macro: "{$TOKEN}", value: "new", hostmacroid: 10 }
    ).and_return("hostmacroids" => ["10"])

    expect(macros.create_or_update(data)).to eq(10)
    expect(data).to eq("hostid" => 1, "macro" => "{$TOKEN}", "value" => "new")
  end

  it "creates a missing global macro" do
    expect(client).to receive(:api_request).with(
      method: "usermacro.get", params: { globalmacro: true, filter: { macro: "{$TOKEN}" } }
    ).and_return([])
    expect(client).to receive(:api_request).with(
      method: "usermacro.createglobal", params: { macro: "{$TOKEN}", value: "new" }
    ).and_return("globalmacroids" => ["20"])

    expect(macros.get_or_create_global(macro: "{$TOKEN}", value: "new")).to eq(20)
  end

  it "sends a flat list of IDs for bulk host macro deletion" do
    expect(client).to receive(:api_request)
      .with(method: "usermacro.delete", params: %w[10 11]).and_return("hostmacroids" => %w[10 11])
    expect(macros.delete([10, 11])).to eq(10)
  end

  it "creates a missing host macro within its explicit host" do
    expect(client).to receive(:api_request).with(
      method: "usermacro.get", params: { hostids: 1, filter: { macro: "{$TOKEN}" } }
    ).and_return([])
    expect(client).to receive(:api_request).with(
      method: "usermacro.create", params: { hostid: 1, macro: "{$TOKEN}", value: "new" }
    ).and_return("hostmacroids" => ["10"])
    expect(macros.get_or_create(hostid: 1, macro: "{$TOKEN}", value: "new")).to eq(10)
  end

  it "updates a global macro using its global ID" do
    expect(client).to receive(:api_request).with(
      method: "usermacro.get", params: { globalmacro: true, filter: { macro: "{$TOKEN}" } }
    ).and_return([{ "globalmacroid" => "20" }])
    expect(client).to receive(:api_request).with(
      method: "usermacro.updateglobal", params: { globalmacroid: 20, macro: "{$TOKEN}", value: "new" }
    ).and_return("globalmacroids" => ["20"])
    expect(macros.create_or_update_global(macro: "{$TOKEN}", value: "new")).to eq(20)
  end

  it "deletes global macros using their global IDs" do
    expect(client).to receive(:api_request)
      .with(method: "usermacro.deleteglobal", params: %w[20
                                                         21]).and_return("globalmacroids" => %w[20 21])
    expect(macros.delete_global([20, 21])).to eq(20)
  end
end
