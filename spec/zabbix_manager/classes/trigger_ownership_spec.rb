# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Managed trigger ownership" do
  let(:client) { instance_double(ZabbixManager::Client, options: {}) }
  let(:triggers) { ZabbixManager::Triggers.new(client) }
  let(:managed_key) { "interface:wan:loss" }
  let(:definition) do
    { hostid: 1, managed_key: managed_key, description: "Loss", expression: "last(/router/loss)>1",
      tags: [{ tag: "managed_by", value: "zabbix_manager" }] }
  end

  before { allow(client).to receive(:with_upsert_lock).and_yield }

  it "refuses to take over a managed key owned by another controller" do
    record = { "triggerid" => "1", "tags" => [
      { "tag" => "zabbix_manager_id", "value" => managed_key },
      { "tag" => "managed_by", "value" => "other" }
    ] }
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything).and_return([record])
    expect(client).not_to receive(:api_request).with(method: "trigger.update", params: anything)

    expect { triggers.upsert_for_host(definition) }.to raise_error(ZabbixManager::Conflict, /owner/)
  end

  it "refuses an API result outside the requested managed key" do
    record = { "triggerid" => "1", "tags" => [{ "tag" => "zabbix_manager_id", "value" => "different" }] }
    allow(client).to receive(:api_request).and_return([record])
    expect do
      triggers.find_managed_for_host(hostid: 1, managed_key: managed_key)
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "distinguishes malformed tags from an ownership conflict" do
    allow(client).to receive(:api_request).and_return([{ "triggerid" => "1", "tags" => [nil] }])
    expect do
      triggers.find_managed_for_host(hostid: 1, managed_key: managed_key, managed_by: "zabbix_manager")
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "rechecks the explicit line ID before updating a managed trigger" do
    record = { "triggerid" => "1", "tags" => [
      { "tag" => "zabbix_manager_id", "value" => managed_key },
      { "tag" => "managed_by", "value" => "zabbix_manager" },
      { "tag" => "line_id", "value" => "other" }
    ] }
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything).and_return([record])
    expect(client).not_to receive(:api_request).with(method: "trigger.update", params: anything)
    attributes = definition.merge(tags: definition[:tags] + [{ tag: "line_id", value: "wan" }])

    expect { triggers.upsert_for_host(attributes) }.to raise_error(ZabbixManager::Conflict)
  end
end
