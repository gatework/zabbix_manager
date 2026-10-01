# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::UserGroups do
  let(:client) { instance_double(ZabbixManager::Client, api_version: version) }
  let(:version) { "7.4.0" }
  let(:groups) { described_class.new(client) }

  it "uses the official user group resource identity" do
    expect(groups.method_name).to eq("usergroup")
    expect(groups.key).to eq("usrgrpid")
    expect(groups.identify).to eq("name")
  end

  [
    ["4.0.0", :rights, :userids],
    ["5.0.0", :rights, :userids],
    ["5.4.0", :rights, :userids],
    ["6.0.0", :rights, :users],
    ["6.2.0", :hostgroup_rights, :users],
    ["7.0.0", :hostgroup_rights, :users],
    ["7.4.0", :hostgroup_rights, :users]
  ].each do |release, rights_field, membership_field|
    context "with Zabbix #{release}" do
      let(:version) { release }

      it "uses the version's host group rights field" do
        expect(client).to receive(:api_request).with(
          method: "usergroup.update",
          params: { usrgrpid: "4", rights_field => [{ id: "9", permission: 3 }] }
        ).and_return("usrgrpids" => ["4"])

        expect(groups.replace_host_group_permissions(user_group_id: 4, host_group_ids: [9], permission: 3)).to eq(4)
      end

      it "uses the version's membership schema and returns every updated group" do
        membership = membership_field == :users ?
          { users: [{ userid: "12" }] } : { userids: ["12"] }
        expect(client).to receive(:api_request).with(
          method: "usergroup.update", params: [membership.merge(usrgrpid: "4"), membership.merge(usrgrpid: "5")]
        ).and_return("usrgrpids" => %w[4 5])

        expect(groups.replace_users(user_group_ids: [4, 5], user_ids: [12])).to eq([4, 5])
      end
    end
  end

  it "allows explicit empty rights and memberships without changing unrelated properties" do
    expect(client).to receive(:api_request).with(
      method: "usergroup.update", params: { usrgrpid: "4", hostgroup_rights: [] }
    ).and_return("usrgrpids" => ["4"])
    expect(client).to receive(:api_request).with(
      method: "usergroup.update", params: [{ usrgrpid: "4", users: [] }]
    ).and_return("usrgrpids" => ["4"])

    expect(groups.replace_host_group_permissions(user_group_id: 4, host_group_ids: [])).to eq(4)
    expect(groups.replace_users(user_group_ids: [4], user_ids: [])).to eq([4])
  end

  it "does not interpret nil or false as instructions to clear rights or membership" do
    expect(client).not_to receive(:api_request)
    [nil, false, {}].each do |invalid|
      expect { groups.replace_host_group_permissions(user_group_id: 4, host_group_ids: invalid) }
        .to raise_error(ZabbixManager::Invalid)
      expect { groups.replace_users(user_group_ids: [4], user_ids: invalid) }
        .to raise_error(ZabbixManager::Invalid)
    end
  end

  it "validates permission levels and every identifier before changing any group" do
    expect(client).not_to receive(:api_request)
    [nil, false, 1, 4, 2.5].each do |permission|
      expect { groups.replace_host_group_permissions(user_group_id: 4, host_group_ids: [9], permission: permission) }
        .to raise_error(ZabbixManager::Invalid)
    end
    expect { groups.replace_host_group_permissions(user_group_id: 4, host_group_ids: [9, 0]) }
      .to raise_error(ZabbixManager::Invalid)
    expect { groups.replace_users(user_group_ids: [4, 0], user_ids: [12]) }.to raise_error(ZabbixManager::Invalid)
    expect { groups.replace_users(user_group_ids: [], user_ids: [12]) }.to raise_error(ZabbixManager::Invalid)
  end

  it "rejects incomplete or mismatched write receipts" do
    [{ "usrgrpids" => [] }, { "usrgrpids" => ["9"] }, { "usrgrpids" => ["4"] }].each do |receipt|
      allow(client).to receive(:api_request).and_return(receipt)
      expect { groups.replace_users(user_group_ids: [4, 5], user_ids: [12]) }
        .to raise_error(ZabbixManager::ProtocolError)
    end
  end

  it "does not retain obsolete convenience names" do
    expect(groups).not_to respond_to(:permissions, :update_users)
  end
end
