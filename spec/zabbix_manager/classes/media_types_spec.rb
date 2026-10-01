# frozen_string_literal: true

require "spec_helper"

describe "ZabbixManager::MediaTypes" do
  let(:media_types_mock) { ZabbixManager::MediaTypes.new(client) }
  let(:client) { double }

  describe ".method_name" do
    subject { media_types_mock.method_name }

    it { is_expected.to eq "mediatype" }
  end

  describe ".identify" do
    subject { media_types_mock.identify }

    it { is_expected.to eq "name" }
  end

  describe ".default_options" do
    subject { media_types_mock.default_options }

    let(:result) do
      { type: 0 }
    end

    it { is_expected.to eq result }
  end
end
