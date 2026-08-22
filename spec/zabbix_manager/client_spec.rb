# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe ZabbixManager::Client do
  let(:transport) {
 instance_double(ZabbixManager::HttpTransport, close: true, safe_url: "https://zabbix.test/api_jsonrpc.php")
  }

  before do
    allow(ZabbixManager::HttpTransport).to receive(:new).and_return(transport)
    allow(transport).to receive(:uri).and_return(URI("https://zabbix.test/api_jsonrpc.php"))
  end

  def response(result)
    JSON.generate(jsonrpc: "2.0", result: result, id: 1)
  end

  def build_client(version: "7.4.0", **options)
    allow(transport).to receive(:request).and_return(response(version))
    described_class.new({ url: "https://zabbix.test/api_jsonrpc.php", api_token: "api-secret" }.merge(options))
  end

  describe "authentication strategy" do
    it "uses a Bearer header and omits auth from the JSON body for Zabbix 7" do
      client = build_client
      allow(transport).to receive(:request).and_return(response([]))

      client.api_request(method: "host.get", params: { output: %w[hostid host] })

      body, arguments = RSpec::Mocks.space.proxy_for(transport).messages_arg_list.last
      expect(JSON.parse(body)).not_to have_key("auth")
      expect(arguments).to eq(bearer_token: "api-secret")
    end

    it "keeps auth in the JSON body for Zabbix 6" do
      client = build_client(version: "6.0.48")
      payload = JSON.parse(client.message_json(method: "host.get", params: {}))

      expect(payload["auth"]).to eq("api-secret")
    end

    it "does not create a user session when api_token is supplied" do
      expect_any_instance_of(described_class).not_to receive(:auth)

      build_client
    end

    it "uses username for password login on Zabbix 6 and newer" do
      calls = []
      allow_any_instance_of(described_class).to receive(:api_request) do |_client, body|
        calls << body
        body[:method] == "apiinfo.version" ? "7.4.0" : "session-secret"
      end

      described_class.new(url: "https://zabbix.test/api_jsonrpc.php", user: "Admin", password: "password")

      expect(calls).to include(method: "user.login", params: { username: "Admin", password: "password" })
    end

    it "rejects ambiguous or incomplete credentials" do
      expect do
        described_class.new(url: "https://zabbix.test", api_token: "token", user: "Admin", password: "password")
      end.to raise_error(ArgumentError, /cannot be combined/)

      expect { described_class.new(url: "https://zabbix.test", user: "Admin") }
        .to raise_error(ArgumentError, /provide api_token/)
    end

    it "treats blank page credential fields as absent" do
      allow(transport).to receive(:request).and_return(response("7.4.0"), response("session-secret"))

      client = described_class.new(
        url: "https://zabbix.test/api_jsonrpc.php", api_token: "", username: "Admin", password: "password"
      )

      expect(client.options[:api_token]).to be_nil
      expect(client.options[:password]).to eq(ZabbixManager::LogSanitizer::REDACTED)
    end

    it "requires HTTPS for API tokens unless explicitly allowed" do
      allow(transport).to receive(:uri).and_return(URI("http://zabbix.test/api_jsonrpc.php"))

      expect { build_client }.to raise_error(ArgumentError, /requires HTTPS/)
      expect { build_client(allow_insecure_http: true) }.not_to raise_error
    end

    it "rejects HTTP Basic auth with Zabbix 7 because both require the Authorization header" do
      expect { build_client(http_user: "proxy-user", http_password: "proxy-password") }
        .to raise_error(ArgumentError, /cannot be combined/)
    end

    it "does not send user.logout for an API token" do
      client = build_client

      expect(client.logout).to be(true)
      expect(transport).to have_received(:request).once
      expect(transport).to have_received(:close)
    end

    it "clears a user session locally even when remote logout fails" do
      allow(transport).to receive(:request).and_return(response("6.0.48"), response("session-secret"))
      client = described_class.new(url: "https://zabbix.test/api_jsonrpc.php", user: "Admin", password: "password")
      allow(transport).to receive(:request).and_raise(Net::ReadTimeout)

      expect { client.logout }.to raise_error(Net::ReadTimeout)
      expect(JSON.parse(client.message_json(method: "host.get", params: {}))).not_to have_key("auth")
    end
  end

  describe "version compatibility" do
    it "accepts Zabbix 4 through 7 and caches the detected version" do
      client = build_client(version: "7.4.0")

      expect(client.api_version).to eq("7.4.0")
      expect(transport).to have_received(:request).once
    end

    it "rejects unsupported future versions unless explicitly ignored" do
      expect { build_client(version: "8.0.0") }.to raise_error(ZabbixManager::ApiError, /not supported/)
      expect { build_client(version: "8.0.0", ignore_version: true) }.not_to raise_error
    end
  end

  describe "logging and errors" do
    it "redacts credentials from options, logs, and formatted requests" do
      output = StringIO.new
      logger = Logger.new(output)
      logger.level = Logger::DEBUG
      client = build_client(logger: logger, password: nil)

      expect(client.options[:api_token]).to eq(ZabbixManager::LogSanitizer::REDACTED)
      expect(client.sanitized_options[:api_token]).to eq(ZabbixManager::LogSanitizer::REDACTED)
      expect(client.inspect).not_to include("api-secret")
      formatted = client.pretty_body(JSON.generate(method: "x", params: { password: "secret", token: "secret" }))
      expect(formatted).not_to include("secret")

      client.log(:debug, "custom", authorization: "Bearer secret", password: "secret")
      expect(output.string).not_to include("secret")
      expect(output.string).to include("[FILTERED]")
    end

    it "从检查摘要中移除 URL 和代理地址的 userinfo 与查询串" do
      client = build_client(
        url: "https://api-user:api-pass@zabbix.test/api_jsonrpc.php?token=url-secret",
        proxy: "http://proxy-user:proxy-pass@proxy.test:8080/?token=proxy-secret"
      )

      expect(client.inspect).not_to match(/api-pass|proxy-pass|url-secret|proxy-secret/)
    end

    it "does not include arbitrary request parameters in debug logs or formatted errors" do
      output = StringIO.new
      logger = Logger.new(output)
      logger.level = Logger::DEBUG
      client = build_client(logger: logger)
      allow(transport).to receive(:request).and_return(response([]))

      client.api_request(method: "usermacro.create", params: { macro: "{$API_TOKEN}", value: "macro-secret" })
      formatted = client.pretty_body(JSON.generate(method: "host.create", params: { tls_psk: "psk-secret" }))

      expect(output.string).not_to include("macro-secret")
      expect(formatted).not_to include("psk-secret")
    end

    it "raises a stable error for invalid JSON-RPC responses" do
      client = build_client
      allow(transport).to receive(:request).and_return(JSON.generate(jsonrpc: "2.0", id: 2))

      expect { client.api_request(method: "host.get", params: {}) }
        .to raise_error(ZabbixManager::ApiError, /missing result/)
    end

    it "缺少 result 时只在异常中保留脱敏响应" do
      client = build_client
      allow(transport).to receive(:request).and_return(
        JSON.generate(jsonrpc: "2.0", id: 2, password: "response-secret")
      )

      expect { client.api_request(method: "host.get", params: {}) }
        .to raise_error(ZabbixManager::ApiError) { |error|
 expect(error.response.inspect).not_to include("response-secret")
            }
    end

    it "redacts sensitive request fields in API errors" do
      client = build_client
      error = { code: -32602, message: "Invalid params.", data: "bad request" }
      allow(transport).to receive(:request).and_return(JSON.generate(jsonrpc: "2.0", error: error, id: 2))

      expect do
        client.api_request(method: "user.update", params: { password: "do-not-log" })
      end.to raise_error(ZabbixManager::ApiError) { |exception|
        expect(exception.message).not_to include("do-not-log")
      }
    end

    it "stores only a sanitized API error response" do
      client = build_client
      error = { code: -32602, message: "Invalid params.", data: "password: secret value" }
      allow(transport).to receive(:request).and_return(JSON.generate(jsonrpc: "2.0", error: error, id: 2))

      expect do
        client.api_request(method: "user.update", params: {})
      end.to raise_error(ZabbixManager::ApiError) { |exception|
        expect(exception.response.inspect).not_to include("secret value")
      }
    end
  end

  describe "request IDs" do
    it "generates monotonic IDs safely within the client" do
      client = build_client

      expect([client.id, client.id, client.id]).to eq([2, 3, 4])
    end
  end

  describe "upsert coordination" do
    it "把业务键交给可注入的跨进程锁适配器" do
      keys = []
      lock = lambda do |key, &block|
        keys << key
        block.call
      end
      client = build_client(upsert_lock: lock)

      result = client.with_upsert_lock("trigger:101:line-1") { :ok }

      expect(result).to eq(:ok)
      expect(keys).to eq(["trigger:101:line-1"])
    end

    it "拒绝无界或无效的结果不确定回查时间表" do
      expect { build_client(uncertain_write_delays: [-1, 70]) }
        .to raise_error(ZabbixManager::Invalid, /uncertain_write_delays/)
    end
  end
end
