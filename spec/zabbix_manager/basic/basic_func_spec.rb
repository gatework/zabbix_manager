# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Basic do
  let(:client) { instance_double(ZabbixManager::Client, options: { debug: false }) }
  let(:basic) { described_class.new(client) }

  describe "#log" do
    it "delegates debug output to the credential-filtering client logger" do
      allow(client).to receive(:options).and_return(debug: true)
      allow(client).to receive(:log)

      basic.log("password=secret")

      expect(client).to have_received(:log).with(:debug, "domain.operation", message: "password=secret")
    end

    it "drops inspected request data from legacy debug operation messages" do
      allow(client).to receive(:options).and_return(debug: true)
      allow(client).to receive(:log)

      basic.log('[DEBUG] Call create with parameters: { value: "secret" }')

      expect(client).to have_received(:log).with(:debug, "domain.operation", message: "[DEBUG] Call create")
    end
  end

  describe "comparison normalization" do
    it "normalizes nested values while retaining caller data" do
      input = { hostid: 10, count: 2, nested: [{ enabled: true }] }

      expect(basic.normalize_hash(input)).to eq(count: "2", nested: [{ enabled: "true" }])
      expect(input).to eq(hostid: 10, count: 2, nested: [{ enabled: true }])
    end

    it "treats remote hashes with extra fields as matching requested attributes" do
      expect(basic.hash_equals?({ name: "router", status: 0 }, { name: "router" })).to be(true)
      expect(basic.hash_equals?({ name: "router", status: 0 }, { name: "switch" })).to be(false)
    end
  end

  describe "#parse_keys" do
    before { allow(basic).to receive(:keys).and_return("hostids") }

    it "returns the first created ID" do
      expect(basic.parse_keys("hostids" => ["10101"])).to eq(10_101)
    end
  end
end
