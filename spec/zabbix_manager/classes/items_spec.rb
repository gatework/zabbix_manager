# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::Items" do
  let(:items_mock) { ZabbixManager::Items.new(client) }
  let(:client) { double }

  describe ".method_name" do
    subject { items_mock.method_name }

    it { is_expected.to eq "item" }
  end

  describe ".identify" do
    subject { items_mock.identify }

    it { is_expected.to eq "name" }
  end

  describe ".default_options" do
    subject { items_mock.default_options }

    let(:result) do
      {
        delay: "1m",
        history: "1h",
        status: 0,
        value_type: 3
      }
    end

    it { is_expected.to eq result }
  end

  describe ".get_or_create" do
    subject { items_mock.get_or_create(data) }

    let(:data) { { name: "batman", hostid: 1234 } }
    let(:result) { [{ "testkey" => "111", "testidentify" => 1 }] }
    let(:id) { nil }
    let(:id_through_create) { 222 }

    before do
      allow(items_mock).to receive(:get_id).with(name: data[:name], hostid: data[:hostid]).and_return(id)
      allow(items_mock).to receive(:create).with(data).and_return(id_through_create)
    end

    context "when ID already exist" do
      let(:id) { "111" }

      it "returns the existing ID" do
        expect(subject).to eq id
      end
    end

    context "when id does not exist" do
      it "returns the newly created ID" do
        expect(subject).to eq id_through_create
      end
    end
  end

  describe ".create_or_update" do
    subject { items_mock.create_or_update(data) }

    let(:data) { { name: "batman", hostid: "1234" } }
    let(:result) { [{ "testkey" => "111", "testidentify" => 1 }] }
    let(:key) { "testkey" }
    let(:identify) { "testidentify" }
    let(:itemid) { nil }
    let(:id_through_create) { 222 }
    let(:update_data) { { name: data[:name], hostid: data[:hostid], itemid: itemid } }

    before do
      allow(items_mock).to receive(:identify).and_return(identify)
      allow(items_mock).to receive(:get_id)
        .with(name: data[:name], hostid: data[:hostid]).and_return(itemid)
      allow(items_mock).to receive(:create).with(data).and_return(id_through_create)
      allow(items_mock).to receive(:update).with(update_data).and_return(itemid)
    end

    context "when Item ID already exist" do
      let(:itemid) { 1234 }

      it "updates an object returns the Item ID" do
        expect(subject).to eq itemid
      end
    end

    context "when Item ID does not exist" do
      it "creates an object returns the newly created object ID" do
        expect(subject).to eq id_through_create
      end
    end
  end

  describe "高频批量操作" do
    it "创建监控项时合并默认值并校验 type" do
      allow(client).to receive(:api_request).with(
        method: "item.get",
        params: { hostids: 101, output: "extend", selectPreprocessing: "extend", filter: { key_: "system.uptime" } }
      ).and_return([])
      allow(client).to receive(:api_request).with(
        method: "item.create",
        params: hash_including(hostid: 101, key_: "system.uptime", type: 0, value_type: 3, delay: "1m")
      ).and_return("itemids" => ["11"])

      expect(
        items_mock.upsert_by_key(
          hostid: 101, interfaceid: 12, key_: "system.uptime", name: "Uptime", type: 0
        )
      ).to eq(11)
    end

    it "通过主机接口幂等创建 DNS 解析监控项" do
      allow(client).to receive(:api_request).with(
        method: "item.get",
        params: {
          hostids: 101,
          output: "extend", selectPreprocessing: "extend",
          filter: { key_: "net.dns.record[,resolver.example.test,A,2,2]" }
        }
      ).and_return([])
      allow(client).to receive(:api_request).with(
        method: "item.create",
        params: hash_including(
          hostid: 101,
          interfaceid: 12,
          key_: "net.dns.record[,resolver.example.test,A,2,2]",
          type: 0
        )
      ).and_return("itemids" => ["13"])

      expect(
        items_mock.upsert_dns_item(
          hostid: 101, interfaceid: 12, dns_name: "resolver.example.test"
        )
      ).to eq(13)
    end

    it "拒绝能够改变 DNS item key 结构的名称" do
      expect(client).not_to receive(:api_request)

      expect do
        items_mock.upsert_dns_item(hostid: 101, interfaceid: 12, dns_name: "invalid,name")
      end.to raise_error(ArgumentError, /unsupported item key delimiters/)
    end

    it "在写入前拒绝重复的 hostid 和 key_" do
      expect(client).not_to receive(:api_request)
      item = { hostid: 10_101, key_: "net.if.in[1]", name: "Inbound" }

      expect { items_mock.upsert_many([item, item.dup]) }
        .to raise_error(ArgumentError, /duplicate hostid \+ key_/)
    end

    it "批量更新监控项状态" do
      allow(client).to receive(:api_request).with(
        method: "item.get",
        params: { hostids: 101, itemids: %w[11 12], output: ["itemid"] }
      ).and_return([{ "itemid" => "11" }, { "itemid" => "12" }])
      allow(client).to receive(:api_request).with(
        method: "item.update",
        params: [{ itemid: "11", status: 1 }, { itemid: "12", status: 1 }]
      ).and_return("itemids" => %w[11 12])

      expect(items_mock.set_status(hostid: 101, itemids: [11, 12], enabled: false)).to eq([11, 12])
    end
  end
end
