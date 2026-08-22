# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Triggers do
  let(:client) do
    instance_double(ZabbixManager::Client, options: { debug: false, uncertain_write_delays: [0] })
  end
  let(:triggers) { described_class.new(client) }

  before do
    allow(client).to receive(:with_upsert_lock).and_yield
  end

  it "uses the singular trigger key when dumping by ID" do
    allow(client).to receive(:api_request)
      .with(
        method: "trigger.get",
        params: hash_including(filter: { triggerid: 301 })
      )
      .and_return([])

    expect(triggers.dump_by_id(triggerid: 301)).to eq([])
  end

  it "creates a missing host-scoped trigger" do
    allow(client).to receive(:api_request)
      .with(method: "trigger.get", params: hash_including(hostids: 101))
      .and_return([])
    allow(client).to receive(:api_request)
      .with(method: "trigger.create", params: hash_including(description: "WAN loss high"))
      .and_return("triggerids" => ["301"])

    expect(
      triggers.upsert_for_host(hostid: 101, description: "WAN loss high", expression: "last(/r/loss)>5")
    ).to eq(301)
  end

  it "updates an existing trigger without rewriting expressions client-side" do
    allow(client).to receive(:api_request)
      .with(method: "trigger.get", params: hash_including(hostids: 101))
      .and_return([{ "triggerid" => "301" }])
    allow(client).to receive(:api_request)
      .with(method: "trigger.update", params: hash_including(triggerid: "301", expression: "last(/r/loss)>5"))
      .and_return("triggerids" => ["301"])

    expect(
      triggers.upsert_for_host(hostid: 101, description: "WAN loss high", expression: "last(/r/loss)>5")
    ).to eq(301)
  end

  it "uses a stable managed key instead of a mutable trigger description" do
    allow(client).to receive(:api_request).with(
      method: "trigger.get",
      params: {
        hostids: 101,
        tags: [{ tag: "zabbix_manager_id", value: "interface:line-1:bandwidth", operator: 1 }],
        output: ["triggerid", "description"],
        selectTags: "extend"
      }
    ).and_return([
                   { "triggerid" => "44", "description" => "Old label",
                     "tags" => [{ "tag" => "service", "value" => "wan" }] }
                 ])
    allow(client).to receive(:api_request).with(
      method: "trigger.update",
      params: hash_including(
        triggerid: "44",
        description: "New label",
        tags: include(
          { tag: "service", value: "wan" },
          { tag: "zabbix_manager_id", value: "interface:line-1:bandwidth" }
        )
      )
    ).and_return("triggerids" => ["44"])

    expect(
      triggers.upsert_for_host(
        hostid: 101,
        managed_key: "interface:line-1:bandwidth",
        description: "New label",
        expression: "last(/router/key)>1",
        tags: [{ tag: "managed_by", value: "zabbix_manager" }]
      )
    ).to eq(44)
  end

  it "has no experimental fixture methods" do
    expect(triggers).not_to respond_to(:mojo_data)
  end

  it "拒绝采用多个同名历史触发器" do
    allow(client).to receive(:api_request).and_return([
                                                        { "triggerid" => "1" }, { "triggerid" => "2" }
                                                      ])

    expect do
      triggers.find_for_host(hostid: 101, description: "WAN high")
    end.to raise_error(ZabbixManager::Conflict, /multiple triggers/)
  end

  it "批量更新触发器状态" do
    allow(client).to receive(:api_request).with(
      method: "trigger.get",
      params: { hostids: 101, triggerids: %w[1 2], output: ["triggerid"] }
    ).and_return([{ "triggerid" => "1" }, { "triggerid" => "2" }])
    allow(client).to receive(:api_request).with(
      method: "trigger.update",
      params: [{ triggerid: "1", status: 1 }, { triggerid: "2", status: 1 }]
    ).and_return("triggerids" => %w[1 2])

    expect(triggers.set_status(hostid: 101, triggerids: [1, 2], enabled: false)).to eq([1, 2])
  end

  it "通过当前 trigger.update 接口完整替换依赖集合" do
    allow(client).to receive(:api_request).with(
      method: "trigger.get",
      params: { hostids: 101, triggerids: ["9"], output: ["triggerid"] }
    ).and_return([{ "triggerid" => "9" }])
    allow(client).to receive(:api_request).with(
      method: "trigger.get",
      params: { hostids: 101, triggerids: %w[7 8], output: ["triggerid"] }
    ).and_return([{ "triggerid" => "7" }, { "triggerid" => "8" }])
    allow(client).to receive(:api_request).with(
      method: "trigger.update",
      params: { triggerid: "9", dependencies: [{ triggerid: "7" }, { triggerid: "8" }] }
    ).and_return("triggerids" => ["9"])

    expect(triggers.replace_dependencies(hostid: 101, triggerid: 9, depends_on: [7, 8])).to eq(9)
  end

  it "拒绝触发器依赖自身" do
    expect(client).not_to receive(:api_request)

    expect do
      triggers.replace_dependencies(hostid: 101, triggerid: 9, depends_on: [9])
    end.to raise_error(ZabbixManager::Invalid, /itself/)
  end

  it "追加依赖时保留并去重已有触发器依赖" do
    allow(client).to receive(:api_request).with(
      method: "trigger.get",
      params: { hostids: 101, triggerids: ["9"], output: ["triggerid"] }
    ).and_return([{ "triggerid" => "9" }])
    allow(client).to receive(:api_request).with(
      method: "trigger.get",
      params: { hostids: 101, triggerids: %w[7 8], output: ["triggerid"] }
    ).and_return([{ "triggerid" => "7" }, { "triggerid" => "8" }])
    allow(client).to receive(:api_request).with(
      method: "trigger.get",
      params: { triggerids: "9", output: "extend", selectDependencies: ["triggerid"] }
    ).and_return([{ "triggerid" => "9", "dependencies" => [{ "triggerid" => "7" }] }])
    allow(client).to receive(:api_request).with(
      method: "trigger.update",
      params: { triggerid: "9", dependencies: [{ triggerid: "7" }, { triggerid: "8" }] }
    ).and_return("triggerids" => ["9"])

    expect(triggers.add_dependencies(hostid: 101, triggerid: 9, depends_on: [7, 8])).to eq(9)
    expect(client).to have_received(:with_upsert_lock).with("trigger-dependencies:9")
  end

  it "创建响应丢失时按管理键回读而不重放写请求" do
    lookup = {
      hostids: 101,
      tags: [{ tag: "zabbix_manager_id", value: "interface:line-1:bandwidth", operator: 1 }],
      output: ["triggerid", "description"],
      selectTags: "extend"
    }
    allow(client).to receive(:api_request).with(method: "trigger.get", params: lookup)
                                          .and_return([], [{ "triggerid" => "44" }])
    allow(client).to receive(:api_request).with(method: "trigger.create", params: anything)
                                          .and_raise(ZabbixManager::TransportError, "response lost")

    result = triggers.upsert_for_host(
      hostid: 101, managed_key: "interface:line-1:bandwidth",
      description: "WAN high", expression: "last(/router/key)>1"
    )

    expect(result).to eq(44)
    expect(client).to have_received(:api_request).with(method: "trigger.create", params: anything).once
  end

  it "创建响应丢失且无法回读时返回结果不确定异常" do
    allow(client).to receive(:api_request).with(method: "trigger.get", params: anything).and_return([])
    allow(client).to receive(:api_request).with(method: "trigger.create", params: anything)
                                          .and_raise(ZabbixManager::TransportError, "response lost")

    expect do
      triggers.upsert_for_host(
        hostid: 101, managed_key: "interface:line-1:bandwidth",
        description: "WAN high", expression: "last(/router/key)>1"
      )
    end.to raise_error(ZabbixManager::ResultUnknown, /must not|before retrying|result is unknown/)
    expect(client).to have_received(:api_request).with(method: "trigger.create", params: anything).once
  end
end
