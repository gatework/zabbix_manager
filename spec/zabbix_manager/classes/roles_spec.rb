# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::Roles" do
  let(:roles_mock) { ZabbixManager::Roles.new(client) }
  let(:client) { double }

  describe ".method_name" do
    subject { roles_mock.method_name }

    it { is_expected.to eq "role" }
  end

  describe ".identify" do
    subject { roles_mock.identify }

    it { is_expected.to eq "name" }
  end

  describe ".key" do
    subject { roles_mock.key }

    it { is_expected.to eq "roleid" }
  end

  describe ".keys" do
    subject { roles_mock.keys }

    it { is_expected.to eq "roleids" }
  end

  describe ".rules" do
    it "passes the Zabbix role rules object through and returns the role id" do
      rules = { ui: [{ name: "monitoring.hosts", status: "1" }] }
      allow(client).to receive(:api_request).with(
        method: "role.update",
        params: { roleid: 12, rules: rules }
      ).and_return("roleids" => ["12"])

      expect(roles_mock.rules(roleid: 12, rules: rules)).to eq(12)
    end
  end
end
