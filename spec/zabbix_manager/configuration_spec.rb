# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Configuration do
  let(:settings) { { url: "https://zabbix.test/api_jsonrpc.php", api_token: "secret" } }

  it "rejects unknown or obsolete options instead of silently ignoring mistakes" do
    %i[verfy_ssl user debug].each do |key|
      expect { described_class.parse(settings.merge(key => true)) }.to raise_error(ZabbixManager::Invalid, /key/)
    end
  end

  it "requires booleans rather than treating false strings as true" do
    %i[verify_ssl allow_insecure_http no_proxy ignore_version].each do |key|
      ["false", 1, nil].each do |value|
        expect { described_class.parse(settings.merge(key => value)) }
          .to raise_error(ZabbixManager::Invalid, /true or false/)
      end
    end
  end

  it "rejects non-string credentials instead of coercing them into a header" do
    [false, 123, ["secret"], { token: "secret" }].each do |token|
      expect { described_class.parse(settings.merge(api_token: token)) }
        .to raise_error(ZabbixManager::Invalid, /String/)
    end
  end

  it "rejects API tokens that cannot be sent safely in a Bearer header before opening a connection" do
    ["secret\r\nInjected: value", "secret\0", "secret".encode("UTF-16LE")].each do |token|
      expect(ZabbixManager::HttpTransport).not_to receive(:new)
      expect { ZabbixManager::Client.new(**settings.merge(api_token: token)) }
        .to raise_error(ZabbixManager::Invalid, /api_token/)
    end
  end

  it "retains Unicode username and password credentials" do
    options = settings.merge(api_token: nil, username: "管理员", password: "密码")
    expect(described_class.parse(options).values_at(:username, :password)).to eq(%w[管理员 密码])
  end

  it "copies connection strings and schedules before storing them" do
    token = +"secret"
    delays = [0, 1]
    parsed = described_class.parse(settings.merge(api_token: token, uncertain_write_delays: delays))
    token.replace("changed")
    delays << 30
    expect(parsed[:api_token]).to eq("secret")
    expect(parsed[:uncertain_write_delays]).to eq([0, 1])
    expect(token).not_to be_frozen
    expect(delays).not_to be_frozen
  end

  it "rejects non-finite and unbounded readback schedules" do
    [[Float::INFINITY], [Float::NAN], [-1], [61], [], nil, 1].each do |schedule|
      expect { described_class.parse(settings.merge(uncertain_write_delays: schedule)) }
        .to raise_error(ZabbixManager::Invalid, /uncertain_write_delays/)
    end
  end

  it "limits environment imports to connection identity and honors explicit overrides" do
    env = {
      "ZABBIX_URL" => "https://env.test", "ZABBIX_API_TOKEN" => "env-secret",
      "ZABBIX_USERNAME" => "env-user", "ZABBIX_PASSWORD" => "env-password",
      "ZABBIX_VERIFY_SSL" => "false", "ZABBIX_TIMEOUT" => "900"
    }
    options = described_class.from_env(env, api_token: nil, username: "override")
    expect(options).to eq(url: "https://env.test", api_token: nil, username: "override", password: "env-password")
  end

  it "keeps manager environment loading explicit" do
    expect(ZabbixManager::Client).to receive(:new).with(url: "https://env.test", api_token: "token",
                                                        username: nil, password: nil).and_return(double)
    ZabbixManager.from_env(env: { "ZABBIX_URL" => "https://env.test", "ZABBIX_API_TOKEN" => "token" })
  end

  it "does not show secrets when inspected" do
    expect(described_class.new(settings).inspect).not_to include("secret")
  end
  it "rejects a logger without a severity setter when log_level is specified" do
    logger = Object.new
    %i[debug info warn formatter formatter=].each { |name| logger.define_singleton_method(name) { |*| nil } }

    expect { described_class.parse(settings.merge(logger: logger, log_level: Logger::INFO)) }
      .to raise_error(ZabbixManager::Invalid, /logger/)
  end
end
