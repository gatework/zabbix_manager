# frozen_string_literal: true

require "spec_helper"

module HttpTransportSpecSupport
  class FakePersistentHttp
    attr_accessor :open_timeout, :read_timeout, :write_timeout, :keep_alive_timeout, :use_ssl, :verify_mode, :ca_file
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

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
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
end
