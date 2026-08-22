# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::HostInterfaces do
  let(:client) { instance_double(ZabbixManager::Client, options: { debug: false }) }
  let(:interfaces) { described_class.new(client) }

  before { allow(client).to receive(:with_upsert_lock).and_yield }

  it "使用稳定端点身份创建缺失接口" do
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.get", params: { hostids: 10_101, output: "extend" }).and_return([])
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.create", params: hash_including(hostid: 10_101, ip: "192.0.2.10"))
      .and_return("interfaceids" => ["12"])

    result = interfaces.reconcile_for_host(
      hostid: 10_101,
      interfaces: [{
        type: 2, main: 1, useip: 1, ip: "192.0.2.10", port: "161",
        details: { version: 2, community: "{$SNMP_COMMUNITY}" }
      }]
    )

    expect(result).to eq([12])
  end

  it "在任何写入前拒绝重复接口" do
    interface = { type: 2, main: 1, useip: 1, ip: "192.0.2.10", port: "161" }
    expect(client).not_to receive(:api_request)

    expect do
      interfaces.reconcile_for_host(hostid: 10_101, interfaces: [interface, interface.dup])
    end.to raise_error(ArgumentError, /duplicate desired interface/)
  end

  it "批量删除明确指定的主机接口" do
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.get", params: { hostids: 10_101, output: "extend" })
      .and_return([{ "interfaceid" => "12" }, { "interfaceid" => "13" }])
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.delete", params: %w[12 13])
      .and_return("interfaceids" => %w[12 13])

    expect(interfaces.delete_many(hostid: 10_101, interfaceids: [12, 13])).to eq([12, 13])
  end

  it "接受单个接口 Hash 并补齐未使用的 DNS 端点" do
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.get", params: { hostids: 10_101, output: "extend" }).and_return([])
    allow(client).to receive(:api_request).with(
      method: "hostinterface.create",
      params: { hostid: 10_101, type: 1, main: 1, useip: 1, ip: "192.0.2.10", dns: "", port: "10050" }
    ).and_return("interfaceids" => ["12"])

    expect(
      interfaces.reconcile_for_host(
        hostid: 10_101, interfaces: { type: 1, main: 1, useip: 1, ip: "192.0.2.10", port: "10050" }
      )
    ).to eq([12])
  end

  it "主接口标志变化时更新原接口而不是重复创建" do
    existing = {
      "interfaceid" => "12", "type" => "1", "main" => "0", "useip" => "1",
      "ip" => "192.0.2.10", "dns" => "", "port" => "10050"
    }
    allow(client).to receive(:api_request)
      .with(method: "hostinterface.get", params: { hostids: 10_101, output: "extend" }).and_return([existing])
    allow(client).to receive(:api_request).with(
      method: "hostinterface.update", params: hash_including(interfaceid: "12", main: 1)
    ).and_return("interfaceids" => ["12"])

    result = interfaces.reconcile_for_host(
      hostid: 10_101,
      interfaces: { type: 1, main: 1, useip: 1, ip: "192.0.2.10", dns: "", port: "10050" }
    )

    expect(result).to eq([12])
  end
end
