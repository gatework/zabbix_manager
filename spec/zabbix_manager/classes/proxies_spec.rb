# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::Proxies" do
  let(:proxies_mock) { ZabbixManager::Proxies.new(client) }
  let(:client) { double(api_version: "6.4.0") }

  describe ".method_name" do
    subject { proxies_mock.method_name }

    it { is_expected.to eq "proxy" }
  end

  describe ".identify" do
    subject { proxies_mock.identify }

    it { is_expected.to eq "host" }
  end

  describe ".isreadable" do
    subject { proxies_mock.isreadable(data) }

    let(:data) { { testidentify: 222 } }
    let(:result) { true }
    let(:identify) { "testidentify" }
    let(:method_name) { "testmethod" }

    before do
      allow(proxies_mock).to receive(:identify).and_return(identify)
      allow(proxies_mock).to receive(:method_name).and_return(method_name)
      allow(client).to receive(:api_request).with(
        method: "proxy.isreadable",
        params: data
      ).and_return(result)
    end

    it { is_expected.to be(true).or be(false) }
  end

  describe ".iswritable" do
    subject { proxies_mock.iswritable(data) }

    let(:data) { { testidentify: 222 } }
    let(:result) { true }
    let(:identify) { "testidentify" }
    let(:method_name) { "testmethod" }

    before do
      allow(proxies_mock).to receive(:identify).and_return(identify)
      allow(proxies_mock).to receive(:method_name).and_return(method_name)
      allow(client).to receive(:api_request).with(
        method: "proxy.iswritable",
        params: data
      ).and_return(result)
    end

    it { is_expected.to be(true).or be(false) }
  end
end
