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

  def response(result, id: 1)
    JSON.generate(jsonrpc: "2.0", result: result, id: id)
  end

  def build_client(version: "7.4.0", **options)
    allow(transport).to receive(:request).and_return(response(version))
    described_class.new(**{ url: "https://zabbix.test/api_jsonrpc.php", api_token: "api-secret" }.merge(options))
  end

  describe "authentication strategy" do
    it "uses a Bearer header and omits auth from the JSON body for Zabbix 7" do
      client = build_client
      allow(transport).to receive(:request).and_return(response([], id: 2))

      client.api_request(method: "host.get", params: { output: %w[hostid host] })

      body, arguments = RSpec::Mocks.space.proxy_for(transport).messages_arg_list.last
      expect(JSON.parse(body)).not_to have_key("auth")
      expect(arguments).to eq(bearer_token: "api-secret")
    end

    it "keeps auth in the JSON body for Zabbix 6" do
      client = build_client(version: "6.0.48")
      allow(transport).to receive(:request).and_return(response([], id: 2))
      client.api_request(method: "host.get")
      payload = JSON.parse(RSpec::Mocks.space.proxy_for(transport).messages_arg_list.last.first)

      expect(payload["auth"]).to eq("api-secret")
    end

    it "does not create a user session when api_token is supplied" do
      expect_any_instance_of(described_class).not_to receive(:login)

      build_client
    end

    it "uses username for password login on Zabbix 6 and newer" do
      calls = []
      allow_any_instance_of(described_class).to receive(:api_request) do |_client, body|
        calls << body
        body[:method] == "apiinfo.version" ? "7.4.0" : "session-secret"
      end

      described_class.new(url: "https://zabbix.test/api_jsonrpc.php", username: "Admin", password: "password")

      expect(calls).to include(method: "user.login", params: { username: "Admin", password: "password" })
    end

    it "rejects ambiguous or incomplete credentials" do
      expect do
        described_class.new(url: "https://zabbix.test", api_token: "token", username: "Admin", password: "password")
      end.to raise_error(ArgumentError, /cannot be combined/)

      expect { described_class.new(url: "https://zabbix.test", username: "Admin") }
        .to raise_error(ArgumentError, /provide api_token/)
    end

    it "treats blank page credential fields as absent" do
      allow(transport).to receive(:request).and_return(response("7.4.0"), response("session-secret", id: 2))

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
      allow(transport).to receive(:request).and_return(response("6.0.48"), response("session-secret", id: 2))
      client = described_class.new(url: "https://zabbix.test/api_jsonrpc.php", username: "Admin", password: "password")
      allow(transport).to receive(:request).and_raise(Net::ReadTimeout)

      expect { client.logout }.to raise_error(Net::ReadTimeout)
      allow(transport).to receive(:request).and_return(response([], id: 4))
      client.api_request(method: "host.get")
      payload = JSON.parse(RSpec::Mocks.space.proxy_for(transport).messages_arg_list.last.first)
      expect(payload).not_to have_key("auth")
    end
  end

  describe "request diagnostics" do
    it "does not log rejected method text or contact the transport" do
      output = StringIO.new
      client = build_client(logger: Logger.new(output))
      output.truncate(0)
      output.rewind
      expect(transport).not_to receive(:request)

      expect { client.api_request(method: "unlabeled-secret") }.to raise_error(ZabbixManager::Invalid)

      expect(output.string).not_to include("unlabeled-secret")
    end

    ["host.\xff".dup.force_encoding("UTF-8"), "host.get".encode("UTF-16LE")].each do |method|
      it "rejects incompatible method encoding with a stable input error" do
        client = build_client
        expect(transport).not_to receive(:request)

        expect { client.api_request(method: method) }.to raise_error(ZabbixManager::Invalid)
      end
    end

    it "correlates started, completed and failed events with their JSON-RPC request IDs" do
      output = StringIO.new
      logger = Logger.new(output)
      logger.level = Logger::DEBUG
      client = build_client(logger: logger)
      output.truncate(0)
      output.rewind
      allow(transport).to receive(:request).and_return(response([], id: 2))
      client.api_request(method: "host.get")
      allow(transport).to receive(:request).and_raise(ZabbixManager::TransportError, "failed")
      expect { client.api_request(method: "host.get") }.to raise_error(ZabbixManager::TransportError)
      events = output.string.lines.map { |line| JSON.parse(line.delete_prefix("[zabbix_manager] ")) }

      expected = [["request.started", 2], ["request.completed", 2], ["request.started", 3], ["request.failed", 3]]
      expect(events.map { |event| event.values_at("event", "request_id") }).to eq(expected)
      expect(output.string).not_to include("api-secret")
    end

    it "skips tag construction and data serialization for a disabled log severity" do
      client = build_client(logger: Logger.new(StringIO.new), log_level: Logger::WARN)
      expect(client.logger).not_to receive(:tagged)
      expect(ZabbixManager::LogSanitizer).not_to receive(:sanitize)

      client.log(:debug, "disabled", password: "secret")
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
      expect(client.inspect).not_to include("api-secret")

      client.log(:debug, "custom", authorization: "Bearer secret", password: "secret")
      expect(output.string).not_to include("secret")
      expect(output.string).to include("[FILTERED]")
    end

    it "filters native SNMPv3 credentials and escaped secrets through the actual logger" do
      output = StringIO.new
      client = build_client(logger: Logger.new(output))
      details = { authpassphrase: "auth-secret", privpassphrase: "priv-secret" }
      diagnostic = JSON.generate(password: "left\"right-secret")

      client.log(:info, "custom", details: details, diagnostic: diagnostic,
                                  headers: JSON.generate(authorization: "head,tail-secret"))

      expect(output.string).to include("custom", "[FILTERED]")
      expect(output.string).not_to include("auth-secret", "priv-secret", "right-secret", "tail-secret")
      expect(details).to include(authpassphrase: "auth-secret", privpassphrase: "priv-secret")
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
      allow(transport).to receive(:request).and_return(response([], id: 2))

      client.api_request(method: "usermacro.create", params: { macro: "{$API_TOKEN}", value: "macro-secret" })

      expect(output.string).not_to include("macro-secret")
    end

    it "raises a stable error for invalid JSON-RPC responses" do
      client = build_client
      allow(transport).to receive(:request).and_return(JSON.generate(jsonrpc: "2.0", id: 2))

      expect { client.api_request(method: "host.get", params: {}) }
        .to raise_error(ZabbixManager::ProtocolError, /result or error/)
    end

    it "缺少 result 时只在异常中保留脱敏响应" do
      client = build_client
      allow(transport).to receive(:request).and_return(
        JSON.generate(jsonrpc: "2.0", id: 2, password: "response-secret")
      )

      expect { client.api_request(method: "host.get", params: {}) }
        .to raise_error(ZabbixManager::ProtocolError) { |error|
          expect(error.full_message).not_to include("response-secret")
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

      ids = []
      allow(transport).to receive(:request) do |body, **|
        id = JSON.parse(body).fetch("id")
        ids << id
        response([], id: id)
      end
      3.times { client.api_request(method: "host.get") }
      expect(ids).to eq([2, 3, 4])
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
  describe "protocol failures" do
    it "rejects a response belonging to another request" do
      client = build_client
      allow(transport).to receive(:request).and_return(response([]))
      expect { client.api_request(method: "host.get", params: {}) }
        .to raise_error(ZabbixManager::TransportError, /response/)
    end

    it "does not expose malformed remote content through exception causes" do
      client = build_client
      allow(transport).to receive(:request).and_return('secret-from-remote')
      expect { client.api_request(method: "host.create", params: {}) }
        .to(raise_error { |error| expect(error.full_message).not_to include("secret-from-remote") })
    end

    [nil, [], true, "unexpected", 42].each do |value|
      it "rejects non-object response #{value.inspect} as an uncertain transport result" do
        client = build_client
        allow(transport).to receive(:request).and_return(JSON.generate(value))
        expect { client.api_request(method: "host.create", params: {}) }
          .to raise_error(ZabbixManager::TransportError)
      end
    end

    it "does not turn successful mutations into failures when logging is unavailable" do
      logger = Logger.new(StringIO.new)
      client = build_client(logger: logger)
      allow(transport).to receive(:request).and_return(JSON.generate(jsonrpc: "2.0", result: true, id: 2))
      allow(client.logger).to receive(:info).and_raise(IOError, "closed log")
      expect(client.api_request(method: "host.create", params: {})).to be(true)
    end
  end
end

RSpec.describe "client configuration and protocol boundaries" do
  let(:transport) do
    instance_double(ZabbixManager::HttpTransport, close: true, uri: URI("https://zabbix.test"),
                                                  safe_url: "https://zabbix.test")
  end

  before do
    allow(ZabbixManager::HttpTransport).to receive(:new).and_return(transport)
    allow(transport).to receive(:request) do |body, **|
      request = JSON.parse(body)
      JSON.generate(jsonrpc: "2.0", id: request.fetch("id"), result: "7.4.0")
    end
  end

  def connect(**options)
    ZabbixManager::Client.new(url: "https://zabbix.test", api_token: "credential", **options)
  end

  it "uses ActiveSupport logging without modifying the injected logger's level" do
    source = Logger.new(StringIO.new, level: :warn)
    client = connect(logger: source, log_level: :debug)
    expect(client.logger).to respond_to(:tagged)
    expect(client.logger.level).to eq(Logger::DEBUG)
    expect(source.level).to eq(Logger::WARN)
  end

  it "builds an ActiveSupport logger only when requested" do
    expect(connect.logger).to be_nil
    expect(connect(log_level: :fatal).logger).to be_a(ActiveSupport::Logger)
  end

  it "rejects invalid request shape before sending" do
    client = connect
    expect(transport).not_to receive(:request)
    [false, nil, 1, "arbitrary"].each do |params|
      expect { client.api_request(method: "host.get", params: params) }.to raise_error(ZabbixManager::Invalid)
    end
    expect { client.api_request(method: "host.get\nsecret") }.to raise_error(ZabbixManager::Invalid)
  end

  it "accepts false and null results instead of treating them as missing" do
    client = connect
    [false, nil].each do |value|
      allow(transport).to receive(:request) do |body, **|
        JSON.generate(jsonrpc: "2.0", id: JSON.parse(body).fetch("id"), result: value)
      end
      expect(client.api_request(method: "host.get")).to eq(value)
    end
  end

  it "rejects contradictory and malformed error responses" do
    client = connect
    [{ result: [], error: {} }, { error: false }, { error: [] },
     { error: { code: "bad", message: "secret" } }].each do |data|
      allow(transport).to receive(:request) do |body, **|
        JSON.generate({ jsonrpc: "2.0", id: JSON.parse(body).fetch("id") }.merge(data))
      end
      expect { client.api_request(method: "host.create") }.to raise_error(ZabbixManager::ProtocolError)
    end
  end

  it "excludes arbitrary remote text from API errors and stored diagnostic data" do
    client = connect
    allow(transport).to receive(:request) do |body, **|
      JSON.generate(jsonrpc: "2.0", id: JSON.parse(body).fetch("id"),
                    error: { code: -32602, message: "credential echoed here", data: "credential also here" })
    end
    expect { client.api_request(method: "host.create") }.to raise_error(ZabbixManager::ApiError) { |error|
      expect(error.full_message).not_to include("credential")
      expect(error.response).to eq("jsonrpc" => "2.0", "id" => 2, "error" => { "code" => -32602 })
    }
  end
end
