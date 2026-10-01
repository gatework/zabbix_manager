# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Users do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.0.0") }
  let(:users) { described_class.new(client) }

  it "replaces all media using user.update" do
    media = [{ mediatypeid: 1, sendto: "ops@example.test", active: 0 }]
    expect(client).to receive(:api_request).with(
      method: "user.update",
      params: [{ userid: 1, medias: media }, { userid: 2, medias: media }]
    ).and_return("userids" => %w[1 2])

    expect(users.update_medias(userids: [1, 2], media: media)).to eq(1)
  end
end
