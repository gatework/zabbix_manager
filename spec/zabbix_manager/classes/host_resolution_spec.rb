# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Hosts, "monitoring host resolution" do
  subject(:hosts) { described_class.new(client) }

  let(:client) { instance_double(ZabbixManager::Client) }
  let(:host) { { "hostid" => "42", "host" => "edge-01", "name" => "Edge router" } }

  it "resolves a name without changing the caller's candidates" do
    candidates = [" edge-01 ", "edge-01", "192.0.2.1"]
    allow(hosts).to receive(:find_by_candidates).with(["edge-01", "192.0.2.1"]).and_return(host)

    expect(hosts.resolve(candidates)).to eq(hostid: "42", host: "edge-01", name: "Edge router")
    expect(candidates.first).to eq(" edge-01 ")
  end

  it "accepts a single name" do
    allow(hosts).to receive(:find_by_candidates).with(["edge-01"]).and_return(host)
    expect(hosts.resolve("edge-01")).to include(hostid: "42", host: "edge-01")
  end

  it "checks explicit IDs against the current technical name" do
    allow(hosts).to receive(:find_by_id).with(42).and_return(host)
    expect(hosts.resolve(hostid: 42, host: "edge-01")).to include(hostid: "42")
    expect { hosts.resolve(hostid: 42, host: "another-host") }
      .to raise_error(ZabbixManager::Conflict, /technical host/)
  end

  it "rejects a mismatched remote ID" do
    allow(hosts).to receive(:find_by_id).with(41).and_return(host)
    expect { hosts.resolve(hostid: 41, host: "edge-01") }.to raise_error(ZabbixManager::Conflict)
  end

  it "validates local references before querying" do
    expect(client).not_to receive(:api_request)
    [nil, [], [""], [false], 42, { hostid: 0, host: "edge-01" }, { hostid: 42 }].each do |reference|
      expect { hosts.resolve(reference) }.to raise_error(ZabbixManager::Invalid)
    end
  end

  it "distinguishes an unavailable host from a malformed remote identity" do
    allow(hosts).to receive(:find_by_candidates).and_return(nil)
    expect { hosts.resolve("edge-01") }.to raise_error(ZabbixManager::ApiError, /not found/)

    allow(hosts).to receive(:find_by_candidates).and_return("hostid" => "0", "host" => "edge-01")
    expect { hosts.resolve("edge-01") }.to raise_error(ZabbixManager::ProtocolError, /invalid host/)
  end
end
