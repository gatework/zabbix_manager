# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Group and macro identity preflight" do
  let(:client) { instance_double(ZabbixManager::Client) }
  let(:groups) { ZabbixManager::HostGroups.new(client) }
  let(:macros) { ZabbixManager::UserMacros.new(client) }

  it "validates every existing group ID before creating any missing group" do
    allow(client).to receive(:api_request).with(method: "hostgroup.get", params: anything)
                                          .and_return([{ "name" => "Existing", "groupid" => "invalid" }])
    expect(client).not_to receive(:api_request).with(method: "hostgroup.create", params: anything)

    expect { groups.get_or_create_host_groups(%w[Missing Existing]) }.to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects duplicate names before selecting a group" do
    records = [{ "name" => "Core", "groupid" => "1" }, { "name" => "Core", "groupid" => "2" }]
    allow(client).to receive(:api_request).and_return(records)

    expect { groups.get_or_create_host_groups("Core") }.to raise_error(ZabbixManager::Conflict)
  end

  it "rejects groups outside the requested names" do
    allow(client).to receive(:api_request).and_return([{ "name" => "Other", "groupid" => "1" }])

    expect { groups.get_hostgroup_ids("Core") }.to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects malformed group collections using the shared protocol contract" do
    allow(client).to receive(:api_request).and_return(nil)

    expect { groups.get_or_create_host_groups("Core") }.to raise_error(ZabbixManager::ProtocolError)
    expect { groups.get_hostgroup_ids("Core") }.to raise_error(ZabbixManager::ProtocolError)
  end

  it "does not query an empty requested group collection" do
    expect(client).not_to receive(:api_request)

    expect(groups.get_or_create_host_groups([])).to eq([])
  end

  it "rejects another host's macro before updating it" do
    record = { "hostmacroid" => "10", "hostid" => "2", "macro" => "{$TOKEN}" }
    allow(client).to receive(:api_request).with(method: "usermacro.get", params: anything).and_return([record])
    expect(client).not_to receive(:api_request).with(method: "usermacro.update", params: anything)

    expect do
      macros.create_or_update(hostid: 1, macro: "{$TOKEN}", value: "new")
    end.to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects another macro's host identity" do
    record = { "hostmacroid" => "10", "hostid" => "1", "macro" => "{$OTHER}" }
    allow(client).to receive(:api_request).and_return([record])

    expect { macros.get_id(hostid: 1, macro: "{$TOKEN}") }.to raise_error(ZabbixManager::ProtocolError)
  end

  it "rejects another global macro before updating it" do
    record = { "globalmacroid" => "20", "macro" => "{$OTHER}" }
    allow(client).to receive(:api_request).with(method: "usermacro.get", params: anything).and_return([record])
    expect(client).not_to receive(:api_request).with(method: "usermacro.updateglobal", params: anything)

    expect do
      macros.create_or_update_global(macro: "{$TOKEN}", value: "new")
    end.to raise_error(ZabbixManager::ProtocolError)
  end
end
