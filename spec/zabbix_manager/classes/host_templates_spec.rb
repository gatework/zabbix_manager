# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Host template associations" do
  let(:client) { instance_double(ZabbixManager::Client) }
  let(:hosts) { ZabbixManager::Hosts.new(client) }

  { link_templates: "host.massadd", replace_templates: "host.massupdate" }.each do |operation, method|
    it "uses #{method} to #{operation}" do
      expect(client).to receive(:api_request).with(
        method: method, params: { hosts: [{ hostid: "1" }], templates: [{ templateid: "2" }] }
      ).and_return("hostids" => ["1"])
      expect(hosts.public_send(operation, host_ids: [1], template_ids: [2])).to eq([1])
    end
  end

  it "unlinks only the selected templates from the selected hosts" do
    expect(client).to receive(:api_request).with(
      method: "host.massremove", params: { hostids: ["1"], templateids: ["2"] }
    ).and_return("hostids" => ["1"])
    expect(hosts.unlink_templates(host_ids: [1], template_ids: [2])).to eq([1])
  end

  it "allows an explicit empty replacement to clear all host template associations" do
    expect(client).to receive(:api_request).with(
      method: "host.massupdate", params: { hosts: [{ hostid: "1" }], templates: [] }
    ).and_return("hostids" => ["1"])
    expect(hosts.replace_templates(host_ids: [1], template_ids: [])).to eq([1])
  end

  it "rejects empty link requests before writing" do
    expect(client).not_to receive(:api_request)
    expect { hosts.link_templates(host_ids: [1], template_ids: []) }.to raise_error(ZabbixManager::Invalid)
  end

  it "rejects receipts confirming a different host" do
    allow(client).to receive(:api_request).and_return("hostids" => ["9"])
    expect { hosts.replace_templates(host_ids: [1], template_ids: [2]) }
      .to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects fractional screen widths before making an API request" do
    expect(client).not_to receive(:api_request)
    expect do
      ZabbixManager::Screens.new(client).get_or_create_for_host(screen_name: "WAN", graphids: [1], hsize: 1.5)
    end.to raise_error(ZabbixManager::Invalid, /hsize/)
  end
end
