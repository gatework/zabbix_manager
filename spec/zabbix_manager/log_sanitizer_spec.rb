# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::LogSanitizer do
  it "redacts nested credentials without mutating business fields" do
    input = {
      password: "password-secret",
      nested: [{ api_token: "token-secret", community: "snmp-secret", key_: "system.cpu.load" }]
    }

    result = described_class.sanitize(input)

    expect(result[:password]).to eq("[FILTERED]")
    expect(result[:nested][0][:api_token]).to eq("[FILTERED]")
    expect(result[:nested][0][:community]).to eq("[FILTERED]")
    expect(result[:nested][0][:key_]).to eq("system.cpu.load")
    expect(input[:password]).to eq("password-secret")
  end

  it "redacts complete Basic credentials and quoted secrets containing spaces" do
    value = 'Authorization: Basic YWxwaGE6YmV0YQ==, password: "alpha beta"'

    sanitized = described_class.sanitize(value)

    expect(sanitized).not_to include("YWxwaGE6YmV0YQ==")
    expect(sanitized).not_to include("alpha beta")
    expect(sanitized.scan("[FILTERED]").length).to eq(2)
  end
end
