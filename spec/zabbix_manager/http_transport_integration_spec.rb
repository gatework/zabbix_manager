# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::HttpTransport, "over local sockets" do
  let(:listener) { TCPServer.new("127.0.0.1", 0) }
  let(:connections) { [] }
  let(:workers) { [] }
  let(:transport) do
    described_class.new(url: "http://127.0.0.1:#{listener.addr[1]}/api_jsonrpc.php", no_proxy: true, timeout: 2)
  end

  after do
    transport.close
    connections.each { |socket| socket.close unless socket.closed? }
    listener.close
    workers.each { |worker| worker.kill.join if worker.alive? }
  end

  def serve(&block)
    workers << Thread.new do
      socket = listener.accept
      connections << socket
      yield(socket)
    end
    workers.last
  end

  def read_post(socket)
    request_line = socket.gets
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip
    end
    [request_line, headers, socket.read(Integer(headers.fetch("content-length")))]
  end

  def write_response(socket)
    socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n{}")
  end

  it "sends both JSON-RPC requests through one persistent connection" do
    received = []
    worker = serve do |socket|
      2.times do
        received << read_post(socket)
        write_response(socket)
      end
    end

    2.times { expect(transport.request('{"method":"host.get"}', bearer_token: "test-token")).to eq("{}") }

    expect(worker.join(2)).to eq(worker)
    worker.value
    expect(connections.length).to eq(1)
    expect(received.length).to eq(2)
    expect(received.map(&:first)).to eq(["POST /api_jsonrpc.php HTTP/1.1\r\n"] * 2)
    expect(received.map { |request| request[1]["authorization"] }).to eq(["Bearer test-token"] * 2)
    expect(received.map(&:last)).to eq(['{"method":"host.get"}'] * 2)
  end

  it "does not resend a POST after the server accepts its body and drops the response" do
    received = []
    worker = serve do |socket|
      received << read_post(socket)
      socket.close
      if IO.select([listener], nil, nil, 0.1)
        duplicate = listener.accept
        connections << duplicate
        received << read_post(duplicate)
        duplicate.close
      end
    end

    expect { transport.request('{"method":"host.create"}') }.to raise_error(ZabbixManager::TransportError)

    expect(worker.join(2)).to eq(worker)
    worker.value
    expect(received.map(&:last)).to eq(['{"method":"host.create"}'])
  end

  context "响应资源预算" do
    let(:transport) do
      described_class.new(url: "http://127.0.0.1:#{listener.addr[1]}/api_jsonrpc.php",
                          no_proxy: true, timeout: 1, request_timeout: 0.12, max_response_bytes: 8)
    end

    it "逐字节滴流也不能无限刷新整体期限" do
      serve do |socket|
        read_post(socket)
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n")
        8.times {
          sleep(0.04)
          socket.write("x")
        }
      rescue IOError, SystemCallError
        nil
      end
      expect { transport.request("{}") }.to raise_error(ZabbixManager::TransportError, /deadline|timeout/i)
    end

    it "拒绝超过字节上限的分块响应，并在下一请求重新建立连接" do
      serve do |socket|
        read_post(socket)
        socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n")
      end
      expect { transport.request("{}") }.to raise_error(ZabbixManager::TransportError, /size|bytes/i)
      serve { |socket|
        read_post(socket)
        write_response(socket)
      }
      expect(transport.request("{}")).to eq("{}")
      expect(connections.length).to eq(2)
    end
  end

  context "with HTTPS" do
    let(:certificate) do
      OpenSSL::X509::Certificate.new.tap do |cert|
        cert.version = 2
        cert.serial = 1
        cert.subject = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
        cert.issuer = cert.subject
        cert.public_key = private_key.public_key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        cert.sign(private_key, OpenSSL::Digest.new("SHA256"))
      end
    end
    let(:private_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:verify_ssl) { false }
    let(:transport) do
      described_class.new(
        url: "https://127.0.0.1:#{listener.addr[1]}/api_jsonrpc.php",
        no_proxy: true, verify_ssl: verify_ssl, timeout: 2
      )
    end

    def serve_tls
      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key = private_key
      serve do |socket|
        tls = OpenSSL::SSL::SSLSocket.new(socket, context)
        tls.sync_close = true
        connections << tls
        tls.accept
        read_post(tls)
        write_response(tls)
      rescue OpenSSL::SSL::SSLError => error
        error
      end
    end

    it "honors the project default allowing a self-signed peer" do
      worker = serve_tls

      expect(transport.request("{}")).to eq("{}")
      expect(worker.join(2)).to eq(worker)
      expect(worker.value).not_to be_a(Exception)
    end

    context "with certificate verification enabled" do
      let(:verify_ssl) { true }

      it "rejects an untrusted certificate before sending JSON-RPC data" do
        worker = serve_tls

        expect { transport.request("{}") }.to raise_error(ZabbixManager::TransportError, /OpenSSL::SSL::SSLError/)
        expect(worker.join(2)).to eq(worker)
        expect(worker.value).to be_a(OpenSSL::SSL::SSLError)
      end
    end
  end
end
