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

  it "redacts native SNMPv3 passphrases without changing the caller's configuration" do
    details = { authpassphrase: "auth-secret", privpassphrase: "priv-secret", securityname: "operator" }
    input = { interfaces: [{ details: details }] }

    result = described_class.sanitize(input)

    expect(result[:interfaces].first[:details]).to eq(
      authpassphrase: "[FILTERED]", privpassphrase: "[FILTERED]", securityname: "operator"
    )
    expect(details).to include(authpassphrase: "auth-secret", privpassphrase: "priv-secret")
  end

  it "redacts native SNMPv3 field names in diagnostic text" do
    result = described_class.sanitize('authpassphrase="auth-secret", privpassphrase=priv-secret')

    expect(result).not_to include("auth-secret", "priv-secret")
    expect(result.scan("[FILTERED]").length).to eq(2)
  end

  it "redacts complete quoted JSON credentials containing escaped quotes and backslashes" do
    input = JSON.generate(password: "left\"right-secret", api_token: "path\\token-secret", name: "kept")

    result = described_class.sanitize(input)

    expect(JSON.parse(result)).to eq("password" => "[FILTERED]", "api_token" => "[FILTERED]", "name" => "kept")
    expect(input).to include("right-secret", "token-secret")
  end

  it "redacts quoted credentials spanning multiple lines" do
    result = described_class.sanitize("password: \"first\nlast-secret\", name: kept")

    expect(result).to eq('password: "[FILTERED]", name: kept')
  end

  ["head,tail-secret", "head}tail-secret", "head]tail-secret", 'Bearer head,tail-secret',
   'Basic head;tail-secret'].each do |secret|
    it "redacts the whole quoted authorization value #{secret.inspect} before handling raw headers" do
      input = JSON.generate(authorization: secret, name: "kept")

      result = described_class.sanitize(input)

      expect(JSON.parse(result)).to eq("authorization" => "[FILTERED]", "name" => "kept")
      expect(described_class.sanitize(result)).to eq(result)
    end
  end
  it "keeps raw credential placeholders stable through repeated sanitization" do
    input = "Authorization: Bearer token-secret, password=other-secret, name=kept"

    result = described_class.sanitize(input)

    expect(result).to eq("Authorization: [FILTERED], password=[FILTERED], name=kept")
    expect(described_class.sanitize(result)).to eq(result)
  end
  %w[password authorization].each do |key|
    it "redacts an entire raw #{key} whose secret starts with the placeholder text" do
      input = "#{key}=[FILTERED]tail-secret, name=kept"

      result = described_class.sanitize(input)

      expect(result).to eq("#{key}=[FILTERED], name=kept")
      expect(described_class.sanitize(result)).to eq(result)
    end
  end
end
