# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Version-specific resource fields" do
  let(:client) { instance_double(ZabbixManager::Client, api_version: version) }

  [["5.2.7", "alias"], ["5.4.0", "username"], ["7.0.0", "username"]].each do |version, field|
    context "with Zabbix #{version}" do
      let(:version) { version }

      it "uses the supported user identity" do
        expect(ZabbixManager::Users.new(client).identify).to eq(field)
      end
    end
  end

  [["6.4.21", "host"], ["7.0.0", "name"]].each do |version, field|
    context "with Zabbix #{version}" do
      let(:version) { version }

      it "queries the supported proxy name field" do
        expect(client).to receive(:api_request).with(
          method: "proxy.get", params: { output: ["proxyid", field], filter: { field.to_sym => "Proxy 1" } }
        ).and_return([{ "proxyid" => "1" }])

        expect(ZabbixManager::Proxies.new(client).get_proxy_id("Proxy 1")).to eq("1")
      end
    end
  end
end
