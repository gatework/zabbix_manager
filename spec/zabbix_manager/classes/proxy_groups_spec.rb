# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::ProxyGroups do
  let(:client) { instance_double(ZabbixManager::Client) }
  let(:groups) { described_class.new(client) }

  it "uses the native underscore ID field for lookup and mutation receipts" do
    allow(client).to receive(:api_request).with(
      method: "proxygroup.get", params: { filter: { name: "HQ" }, output: %w[proxy_groupid name] }
    ).and_return([{ "proxy_groupid" => "5", "name" => "HQ" }])
    allow(client).to receive(:api_request).with(method: "proxygroup.create", params: [{ name: "Branch" }])
                                          .and_return("proxy_groupids" => ["6"])
    allow(client).to receive(:api_request).with(method: "proxygroup.delete", params: ["6"])
                                          .and_return("proxy_groupids" => ["6"])

    expect(groups.get_id(name: "HQ")).to eq(5)
    expect(groups.create(name: "Branch")).to eq(6)
    expect(groups.delete(6)).to eq(6)
  end

  it "rejects an invalid ID instead of returning a success with zero" do
    allow(client).to receive(:api_request).with(method: "proxygroup.create", params: [{ name: "Branch" }])
                                          .and_return("proxy_groupids" => ["invalid"])

    expect { groups.create(name: "Branch") }.to raise_error(ZabbixManager::ProtocolError)
  end
end
