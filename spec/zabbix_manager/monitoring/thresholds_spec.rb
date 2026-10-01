# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Monitoring::Thresholds do
  let(:client) { instance_double(ZabbixManager::Client, api_version: "7.4.0") }
  let(:thresholds) { described_class.new(client) }
  let(:host) { { hostid: 1, host: "Router One" } }
  let(:interface) { { name: "eth0" } }
  let(:items) { { packet_loss: { key_: "icmppingloss[192.0.2.1]", units: "%" } } }

  def prepare(config)
    thresholds.prepare_triggers(host: host, interface: interface, items: items,
                                thresholds: { packet_loss: config })
  end

  it "can recover a zero-loss threshold when packet loss reaches zero" do
    trigger = prepare(high: 5, recovery: 0).fetch(:packet_loss)
    expect(trigger[:recovery_expression]).to eq("avg(/Router One/icmppingloss[192.0.2.1],5m)<=0")
  end

  it "rejects non-finite and physically impossible loss thresholds" do
    [Float::INFINITY, Float::NAN, 101].each do |high|
      expect { prepare(high: high, recovery: 0) }.to raise_error(ZabbixManager::Invalid)
    end
  end

  it "preserves sub-micro thresholds instead of rounding them to zero" do
    trigger = prepare(high: 0.0000002, recovery: 0.0000001).fetch(:packet_loss)
    expect(trigger[:expression]).to end_with(">0.0000002")
  end

  it "rejects overrides of trigger identity and management tags" do
    described_class::MANAGED_TAGS.each do |name|
      expect { prepare(high: 5, recovery: 2, tags: [{ tag: name, value: "other" }]) }
        .to raise_error(ZabbixManager::Invalid, /reserved/)
    end
  end

  it "retains extension tags without mutating the caller's definitions" do
    config = { high: 5, recovery: 2, tags: [{ "tag" => "site", "value" => "edge" }] }
    original = Marshal.load(Marshal.dump(config))
    trigger = prepare(config).fetch(:packet_loss)
    expect(trigger[:tags]).to include(tag: "site", value: "edge")
    expect(config).to eq(original)
  end

  it "rejects unknown configuration fields and threshold names" do
    expect { prepare(high: 5, recovery: 2, prioirty: 3) }.to raise_error(ZabbixManager::Invalid, /prioirty/)
    expect do
      thresholds.prepare_triggers(host: host, interface: interface, items: items,
                                  thresholds: { temperature: { high: 5, recovery: 2 } })
    end.to raise_error(ZabbixManager::Invalid, /unsupported threshold/)
  end

  it "validates hash, array, metric, and tag shapes at the domain boundary" do
    [nil, false, 1, []].each do |config|
      expect { prepare(config) }.to raise_error(ZabbixManager::Invalid, /hash/)
    end
    [nil, false, {}, [nil]].each do |metrics|
      expect { prepare(high: 5, recovery: 2, metrics: metrics) }.to raise_error(ZabbixManager::Invalid)
    end
    [nil, false, {}, [nil], [{ tag: "site", value: false }]].each do |tags|
      expect { prepare(high: 5, recovery: 2, tags: tags) }.to raise_error(ZabbixManager::Invalid)
    end
  end

  it "supports last without a duration argument and validates the version" do
    expect(prepare(high: 5, recovery: 2, function: "last")[:packet_loss][:expression])
      .to eq("last(/Router One/icmppingloss[192.0.2.1])>5")
    allow(client).to receive(:api_version).and_return("unknown")
    expect { prepare(high: 5, recovery: 2) }.to raise_error(ZabbixManager::Invalid, /version/)
  end

  it "rejects host delimiters before expressions are generated" do
    host[:host] = "router/key)>0 or last("
    expect { prepare(high: 5, recovery: 2) }.to raise_error(ZabbixManager::Invalid, /host.host/)
  end

  it "accepts quoted item parameters while refusing unterminated quotes" do
    items[:packet_loss][:key_] = 'loss["edge,router"]'
    expect(prepare(high: 5, recovery: 2)[:packet_loss][:expression]).to include('loss["edge,router"]')
    items[:packet_loss][:key_] = 'loss["edge,router]'
    expect { prepare(high: 5, recovery: 2) }.to raise_error(ZabbixManager::Invalid, /key_/)
  end

  it "rejects an oversized managed identity before item reconciliation" do
    interface[:name] = "x" * 200
    expect { prepare(high: 5, recovery: 2) }.to raise_error(ZabbixManager::Invalid, /managed_key/)
  end
end
