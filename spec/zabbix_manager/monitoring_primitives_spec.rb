# frozen_string_literal: true

require "spec_helper"

RSpec.describe "monitoring primitives" do
  let(:client) { instance_double(ZabbixManager::Client) }

  before do
    allow(client).to receive(:with_upsert_lock).and_yield
  end

  it "updates an existing item located by host and key" do
    items = ZabbixManager::Items.new(client)
    allow(client).to receive(:api_request)
      .with(method: "item.get", params: hash_including(hostids: 101, filter: { key_: "net.if.in[1]" }))
      .and_return([{ "itemid" => "202", "hostid" => "101", "key_" => "net.if.in[1]" }])
    allow(client).to receive(:api_request)
      .with(method: "item.update", params: hash_including(itemid: "202", key_: "net.if.in[1]"))
      .and_return("itemids" => ["202"])

    expect(items.upsert_by_key(hostid: 101, key_: "net.if.in[1]", name: "Inbound")).to eq(202)
  end

  it "creates a new item when the stable key is absent" do
    items = ZabbixManager::Items.new(client)
    allow(client).to receive(:api_request).with(method: "item.get", params: anything).and_return([])
    allow(client).to receive(:api_request)
      .with(method: "item.create", params: hash_including(hostid: 101, key_: "net.if.in[1]"))
      .and_return("itemids" => ["203"])

    expect(
      items.upsert_by_key(hostid: 101, interfaceid: 12, key_: "net.if.in[1]", name: "Inbound", type: 0)
    ).to eq(203)
  end

  it "updates an existing host-scoped trigger" do
    triggers = ZabbixManager::Triggers.new(client)
    allow(client).to receive(:api_request)
      .with(method: "trigger.get", params: hash_including(hostids: 101,
                                                          filter: { description: "WAN loss high" }))
      .and_return([{ "triggerid" => "301" }])
    allow(client).to receive(:api_request)
      .with(method: "trigger.update", params: hash_including(triggerid: "301",
                                                             expression: "last(/r/key)>5"))
      .and_return("triggerids" => ["301"])

    expect(
      triggers.upsert_for_host(hostid: 101, description: "WAN loss high", expression: "last(/r/key)>5")
    ).to eq(301)
  end
end
