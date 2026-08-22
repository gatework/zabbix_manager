# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::Mediatypes" do
  let(:mediatypes_mock) { ZabbixManager::Mediatypes.new(client) }
  let(:client) { double }

  describe ".method_name" do
    subject { mediatypes_mock.method_name }

    it { is_expected.to eq "mediatype" }
  end

  describe ".identify" do
    subject { mediatypes_mock.identify }

    it { is_expected.to eq "name" }
  end

  describe ".default_options" do
    subject { mediatypes_mock.default_options }

    let(:result) do
      { type: 0 }
    end

    it { is_expected.to eq result }
  end
end
