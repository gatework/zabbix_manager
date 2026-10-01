# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Resource do
  let(:client) { instance_double(ZabbixManager::Client) }
  let(:groups) { ZabbixManager::HostGroups.new(client) }

  it "merges defaults into string-keyed attributes without mutating input" do
    data = { "name" => "Email", "type" => 1 }
    expect(client).to receive(:api_request)
      .with(method: "mediatype.create", params: [{ name: "Email", type: 1 }])
      .and_return("mediatypeids" => ["8"])

    expect(ZabbixManager::MediaTypes.new(client).create(data)).to eq(8)
    expect(data).to eq("name" => "Email", "type" => 1)
  end

  it "passes a flat list of IDs for deletion" do
    expect(client).to receive(:api_request)
      .with(method: "hostgroup.delete", params: %w[1 2]).and_return("groupids" => %w[1 2])
    expect(groups.delete([1, 2])).to eq(1)
  end

  it "does not rewrite unchanged numeric attributes returned as API strings" do
    expect(client).to receive(:api_request)
      .with(method: "hostgroup.get", params: { filter: { groupid: 1 }, output: "extend" })
      .and_return([{ "groupid" => "1", "name" => "Routers", "flags" => "0" }])

    expect(groups.update("groupid" => 1, "name" => "Routers", "flags" => 0)).to eq(1)
  end

  it "forwards raw parameters and responses without single-object assumptions" do
    params = { groupids: [1, 2], countOutput: true }
    expect(client).to receive(:api_request).with(method: "hostgroup.get", params: params).and_return("2")
    expect(groups.get_raw(params)).to eq("2")
  end

  it "uses both parts of a composite resource identity for complete-data queries" do
    expect(client).to receive(:api_request).with(
      method: "httptest.get", params: { filter: { name: "Home", hostid: 1 }, output: "extend" }
    ).and_return([])
    expect(ZabbixManager::HttpTests.new(client).get_full_data("name" => "Home", "hostid" => 1)).to eq([])
  end

  it "does not accept a substring identity match" do
    allow(client).to receive(:api_request).and_return([{ "groupid" => "1", "name" => "Core Routers" }])
    expect(groups.get_id(name: "Routers")).to be_nil
  end

  it "rejects ambiguous exact identities" do
    result = [{ "groupid" => "1", "name" => "Routers" }, { "groupid" => "2", "name" => "Routers" }]
    allow(client).to receive(:api_request).and_return(result)
    expect { groups.get_id(name: "Routers") }.to raise_error(ZabbixManager::Conflict)
  end

  it "rejects duplicate names instead of losing objects in all" do
    result = [{ "groupid" => "1", "name" => "Routers" }, { "groupid" => "2", "name" => "Routers" }]
    allow(client).to receive(:api_request).and_return(result)
    expect { groups.all }.to raise_error(ZabbixManager::Conflict)
  end

  it "returns identity-to-ID mappings for all" do
    allow(client).to receive(:api_request).and_return([{ "groupid" => "1", "name" => "Routers" }])
    expect(groups.all).to eq("Routers" => "1")
  end

  it "creates an absent object through the actual API boundary" do
    expect(client).to receive(:api_request)
      .with(method: "hostgroup.get", params: { filter: { name: "Routers" }, output: %w[groupid name] })
      .and_return([])
    expect(client).to receive(:api_request)
      .with(method: "hostgroup.create", params: [{ name: "Routers" }]).and_return("groupids" => ["1"])

    expect(groups.get_or_create(name: "Routers")).to eq(1)
  end

  it "propagates an uncertain write without retrying it" do
    expect(client).to receive(:api_request).once.and_raise(ZabbixManager::ResultUnknown, "unknown")
    expect { groups.create(name: "Routers") }.to raise_error(ZabbixManager::ResultUnknown)
  end
end
