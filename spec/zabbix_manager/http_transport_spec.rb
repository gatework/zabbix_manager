# frozen_string_literal: true

require "spec_helper"

module HttpTransportSpecSupport
  class FakePersistentHttp
    attr_accessor :open_timeout, :read_timeout, :write_timeout, :keep_alive_timeout, :max_retries,
                  :use_ssl, :verify_mode, :ca_file
    attr_reader :requests, :start_count, :finish_count

    def initialize(response)
      @response = response
      @requests = []
      @started = false
      @start_count = 0
      @finish_count = 0
    end

    def started?
      @started
    end

    def start
      @started = true
      @start_count += 1
    end

    def finish
      @started = false
      @finish_count += 1
    end

    def request(request)
      @requests << request
      @response
    end
  end
end

RSpec.describe ZabbixManager::HttpTransport do
  let(:response) do
    Net::HTTPOK.new("1.1", "200", "OK").tap do |value|
      value.instance_variable_set(:@read, true)
      value.instance_variable_set(:@body, "{}")
    end
  end
  let(:http) { HttpTransportSpecSupport::FakePersistentHttp.new(response) }

  before do |example|
    allow(Net::HTTP).to receive(:new).and_return(http) unless example.metadata[:real_http]
  end

  it "reuses one started HTTP session across requests" do
    transport = described_class.new(url: "http://zabbix.test/api_jsonrpc.php", no_proxy: true)

    2.times { transport.request("{}") }

    expect(http.start_count).to eq(1)
    expect(http.requests.length).to eq(2)
  end

  it "closes the reusable session explicitly" do
    transport = described_class.new(url: "http://zabbix.test/api_jsonrpc.php", no_proxy: true)
    transport.request("{}")

    transport.close

    expect(http.finish_count).to eq(1)
  end

  it "keeps HTTPS certificate verification disabled by default" do
    transport = described_class.new(url: "https://zabbix.test/api_jsonrpc.php", no_proxy: true)

    transport.request("{}")

    expect(http.use_ssl).to be(true)
    expect(http.verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
  end

  it "allows callers to opt into certificate verification" do
    transport = described_class.new(
      url: "https://zabbix.test/api_jsonrpc.php",
      no_proxy: true,
      verify_ssl: true,
      ca_file: "/tmp/zabbix-ca.pem"
    )

    transport.request("{}")

    expect(http.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
    expect(http.ca_file).to eq("/tmp/zabbix-ca.pem")
  end

  it "places API tokens only in the Authorization header" do
    transport = described_class.new(url: "http://zabbix.test/api_jsonrpc.php", no_proxy: true)

    transport.request("{}", bearer_token: "api-secret")

    expect(http.requests.last["Authorization"]).to eq("Bearer api-secret")
  end

  it "abandons an inherited connection after fork without closing the parent's socket" do
    replacement = HttpTransportSpecSupport::FakePersistentHttp.new(response)
    allow(Net::HTTP).to receive(:new).and_return(http, replacement)
    transport = described_class.new(url: "http://zabbix.test/api_jsonrpc.php", no_proxy: true)
    transport.request("{}")
    transport.instance_variable_set(:@pid, Process.pid - 1)

    transport.request("{}")

    expect(http.finish_count).to eq(0)
    expect(replacement.start_count).to eq(1)
  end

  it "把超时和套接字故障统一包装为传输异常且不重放请求" do
    allow(http).to receive(:request).and_raise(Net::ReadTimeout)
    transport = described_class.new(url: "https://zabbix.test/api_jsonrpc.php", no_proxy: true)

    expect { transport.request("{}") }
      .to raise_error(ZabbixManager::TransportError, /Net::ReadTimeout/)
    expect(http).to have_received(:request).once
  end

  it "把畸形 HTTP 协议响应统一包装为传输异常" do
    allow(http).to receive(:request).and_raise(Net::HTTPBadResponse, "wrong status line")
    transport = described_class.new(url: "https://zabbix.test/api_jsonrpc.php", no_proxy: true)

    expect { transport.request("{}") }
      .to raise_error(ZabbixManager::TransportError, /Net::HTTPBadResponse/)
  end

  it "does not expose the underlying network error in exception causes" do
    allow(http).to receive(:request).and_raise(Net::HTTPBadResponse, "password=remote-secret")
    transport = described_class.new(url: "https://zabbix.test/api_jsonrpc.php", no_proxy: true)

    expect { transport.request("{}") }.to raise_error(ZabbixManager::TransportError) { |error|
      expect(error.full_message).not_to include("remote-secret")
      expect(error.cause).to be_nil
    }
  end

  it "does not close a session inherited from another process" do
    transport = described_class.new(url: "http://zabbix.test/api_jsonrpc.php", no_proxy: true)
    transport.request("{}")
    transport.instance_variable_set(:@pid, Process.pid - 1)

    expect(transport.close).to be(true)
    expect(http.finish_count).to eq(0)
  end

  it "does not mask a failed request when TLS cleanup also fails" do
    allow(http).to receive(:request).and_raise(Net::ReadTimeout)
    allow(http).to receive(:finish).and_raise(OpenSSL::SSL::SSLError, "cleanup-secret")
    transport = described_class.new(url: "https://zabbix.test/api_jsonrpc.php", no_proxy: true)

    expect { transport.request("{}") }.to raise_error(ZabbixManager::TransportError, /Net::ReadTimeout/)
  end

  it "rejects competing Authorization headers before opening a connection" do
    transport = described_class.new(
      url: "https://zabbix.test/api_jsonrpc.php", no_proxy: true,
      http_user: "web-user", http_password: "web-password"
    )

    expect { transport.request("{}", bearer_token: "api-secret") }
      .to raise_error(ZabbixManager::Invalid, /Basic.*Bearer/)
    expect(http.start_count).to eq(0)
  end

  it "sets explicit timeout values and disables transparent retries" do
    transport = described_class.new(
      url: "http://zabbix.test/api_jsonrpc.php", no_proxy: true,
      timeout: "5", open_timeout: 2, write_timeout: 3, keep_alive_timeout: 10
    )

    transport.request("{}")

    expect([http.open_timeout, http.read_timeout, http.write_timeout, http.keep_alive_timeout]).to eq([2, 5, 3, 10])
    expect(http.max_retries).to eq(0)
  end

  [Float::INFINITY, -1, 0, Float::NAN, "invalid", nil].each do |value|
    it "rejects an invalid timeout #{value.inspect}" do
      expect { described_class.new(url: "http://zabbix.test", timeout: value) }
        .to raise_error(ZabbixManager::Invalid, /timeout/)
    end
  end

  %i[verify_ssl no_proxy].each do |key|
    it "requires a boolean #{key} value" do
      expect { described_class.new(url: "https://zabbix.test", key => "false") }
        .to raise_error(ZabbixManager::Invalid, /#{key}/)
    end
  end

  it "rejects malformed URLs without retaining their credentials" do
    expect { described_class.new(url: "https://web-user:private-secret@broken host") }
      .to raise_error(ZabbixManager::Invalid) { |error|
        expect(error.full_message).not_to include("private-secret")
      }
  end

  describe "proxy configuration", :real_http do
    before do
      allow(ENV).to receive(:[]).and_call_original
      %w[http_proxy HTTP_PROXY no_proxy NO_PROXY REQUEST_METHOD CGI_HTTP_PROXY].each do |name|
        allow(ENV).to receive(:[]).with(name).and_return(nil)
      end
    end

    let(:url) { "http://192.0.2.10/api_jsonrpc.php" }

    it "disables environment proxy detection when no_proxy is true" do
      allow(ENV).to receive(:[]).with("http_proxy").and_return("http://proxy.test:8080")
      transport = described_class.new(url: url, no_proxy: true)

      expect(transport.send(:build_http).proxy?).to be(false)
    end

    it "delegates default proxy discovery and no_proxy exclusions to the standard library" do
      allow(ENV).to receive(:[]).with("http_proxy").and_return("http://proxy.test:8080")
      transport = described_class.new(url: url)

      expect(transport.send(:build_http).proxy_address).to eq("proxy.test")
      allow(ENV).to receive(:[]).with("no_proxy").and_return("192.0.2.10")
      expect(described_class.new(url: url).send(:build_http).proxy?).to be(false)
    end

    it "does not use a CGI Proxy header as an outbound proxy" do
      allow(ENV).to receive(:include?).with("REQUEST_METHOD").and_return(true)
      allow(ENV).to receive(:reject).and_return("HTTP_PROXY" => "http://untrusted.test:8080")
      allow(ENV).to receive(:[]).with("HTTP_PROXY").and_return("http://untrusted.test:8080")
      transport = described_class.new(url: url)

      expect(transport.send(:build_http).proxy?).to be(false)
    end

    it "decodes explicit proxy credentials without changing literal plus signs" do
      transport = described_class.new(url: url, proxy: "http://user%40example:pass%3Aword+extra@proxy.test:8080")
      connection = transport.send(:build_http)

      expect(connection.proxy_address).to eq("proxy.test")
      expect(connection.proxy_port).to eq(8080)
      expect(connection.proxy_user).to eq("user@example")
      expect(connection.proxy_pass).to eq("pass:word+extra")
    end

    ["https://proxy.test", "socks5://proxy.test", "http://proxy.test/?token=secret", false].each do |value|
      it "rejects an unsupported proxy #{value.inspect}" do
        expect { described_class.new(url: url, proxy: value) }
          .to raise_error(ZabbixManager::Invalid, /proxy/)
      end
    end

    it "also rejects encrypted proxy URLs discovered from the environment" do
      allow(ENV).to receive(:[]).with("http_proxy").and_return("https://user:proxy-secret@proxy.test")

      expect { described_class.new(url: url) }.to raise_error(ZabbixManager::Invalid, /proxy/)
    end

    it "does not expose credentials from a malformed environment proxy" do
      allow(ENV).to receive(:[]).with("http_proxy").and_return("http://user:proxy-secret@bad host")

      expect { described_class.new(url: url) }.to raise_error(ZabbixManager::Invalid) { |error|
        expect(error.full_message).not_to include("proxy-secret")
      }
    end
  end
end
