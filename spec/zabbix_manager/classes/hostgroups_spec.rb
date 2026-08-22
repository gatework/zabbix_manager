# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::HostGroups" do
  let(:actions_mock) { ZabbixManager::HostGroups.new(client) }
  let(:client) { double }

  describe ".method_name" do
    subject { actions_mock.method_name }

    it { is_expected.to eq "hostgroup" }
  end

  describe ".identify" do
    subject { actions_mock.identify }

    it { is_expected.to eq "name" }
  end

  describe ".key" do
    subject { actions_mock.key }

    it { is_expected.to eq "groupid" }
  end

  describe ".get_or_create_hostgroups" do
    it "looks up all names once and creates only missing groups" do
      allow(client).to receive(:api_request).with(
        method: "hostgroup.get",
        params: { output: %w[groupid name], filter: { name: %w[Core Edge] } }
      ).and_return([{ "groupid" => "10", "name" => "Core" }])
      allow(client).to receive(:api_request).with(
        method: "hostgroup.create", params: { name: "Edge" }
      ).and_return("groupids" => ["11"])

      expect(actions_mock.get_or_create_hostgroups(["Core", "Edge", "Core"])).to eq(
        [{ groupid: "10" }, { groupid: "11" }]
      )
    end
  end
end
