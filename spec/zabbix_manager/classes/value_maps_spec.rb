# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::ValueMaps do
  let(:client) { instance_double(ZabbixManager::Client, options: {}) }
  let(:value_maps) { described_class.new(client) }

  it "uses the Zabbix value map identity fields" do
    expect(value_maps.method_name).to eq("valuemap")
    expect(value_maps.identify).to eq("name")
    expect(value_maps.key).to eq("valuemapid")
  end

  it "returns an existing map by name" do
    allow(value_maps).to receive(:get_id).with(name: "Interface status").and_return(101)

    expect(value_maps.get_or_create(name: "Interface status", mappings: [])).to eq(101)
  end

  it "updates an existing map with the singular valuemapid" do
    data = { name: "Interface status", mappings: [{ value: "1", newvalue: "up" }] }
    allow(value_maps).to receive(:get_id).with(name: "Interface status").and_return(101)
    allow(value_maps).to receive(:update).with(data.merge(valuemapid: 101)).and_return(101)

    expect(value_maps.create_or_update(data)).to eq(101)
  end
end
