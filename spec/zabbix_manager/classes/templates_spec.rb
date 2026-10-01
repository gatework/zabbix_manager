# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::Templates" do
  let(:templates_mock) { ZabbixManager::Templates.new(client) }
  let(:client) { double(options: {}) }

  describe ".method_name" do
    subject { templates_mock.method_name }

    it { is_expected.to eq "template" }
  end

  describe ".identify" do
    subject { templates_mock.identify }

    it { is_expected.to eq "host" }
  end

  describe ".get_ids_by_host" do
    subject { templates_mock.get_ids_by_host(data) }

    let(:data) { { scriptid: 222, hostid: 333 } }
    let(:result) { [{ "templateid" => 1 }, { "templateid" => 2 }] }
    let(:ids) { [1, 2] }

    before do
      allow(client).to receive(:api_request).with(
        method: "template.get",
        params: data
      ).and_return(result)
    end

    it { is_expected.to eq ids }
  end

  describe ".get_or_create" do
    subject { templates_mock.get_or_create(data) }

    let(:data) { { host: 1234 } }
    let(:result) { [{ "testkey" => "111", "testidentify" => 1 }] }
    let(:id) { nil }
    let(:id_through_create) { 222 }

    before do
      allow(templates_mock).to receive(:get_id).with(host: data[:host]).and_return(id)
      allow(templates_mock).to receive(:create).with(data).and_return(id_through_create)
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

  describe ".get_template_ids" do
    it "returns a flat collection of template references" do
      allow(client).to receive(:api_request).with(
        method: "template.get",
        params: { output: "extend", filter: { host: %w[linux network] } }
      ).and_return([{ "templateid" => "10" }, { "templateid" => "20" }])

      expect(templates_mock.get_template_ids(%w[linux network])).to eq(
        [{ templateid: "10" }, { templateid: "20" }]
      )
    end
  end
end
