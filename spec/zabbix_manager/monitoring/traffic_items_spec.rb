# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Monitoring::TrafficItems do
  def item(id, name, key, **attributes)
    { "itemid" => id.to_s, "name" => name, "key_" => key, "units" => "bps" }.merge(attributes.stringify_keys)
  end

  it "matches Linux and Juniper interface names exactly" do
    %w[eth0 ge-0/0/1].each do |interface|
      items = [item(1, "#{interface} inbound", "net.if.in[a]"),
               item(2, "#{interface} outbound", "net.if.out[a]")]
      expect(described_class.new(items).for_interface(interface)[:inbound][:itemid]).to eq("1")
    end
  end

  it "refuses contradictory direction evidence instead of using one item twice" do
    items = [item(1, "Gi1/0/1 outbound", "net.if.in[a]")]
    expect { described_class.new(items).for_interface("Gi1/0/1") }
      .to raise_error(ZabbixManager::Conflict)
  end

  it "refuses duplicate item identities even when their metadata disagree" do
    items = [item(1, "eth0 inbound", "net.if.in[a]"), item(1, "eth0 outbound", "net.if.out[a]")]
    expect { described_class.new(items).for_interface("eth0") }
      .to raise_error(ZabbixManager::Conflict)
  end

  it "rejects raw counter pipelines with unproven scaling" do
    base = { key_: "ifHCInOctets[1]", units: "bps" }
    [
      [{ type: 10 }, { type: 1, params: 8 }, { type: 1, params: 100 }],
      [{ type: 10 }, { type: 1, params: 8 }, { type: 21, params: "return value * 100" }]
    ].each do |steps|
      expect { described_class.validate_bps!(base.merge(preprocessing: steps)) }
        .to raise_error(ZabbixManager::Invalid, /preprocessing/)
    end
  end

  it "rejects byte counters labeled as bits without conversion" do
    counter = { key_: "net.if.in[eth0]", units: "bps", type: 0 }
    expect { described_class.validate_bps!(counter) }
      .to raise_error(ZabbixManager::Invalid, /preprocessing/)
  end

  it "accepts standard SNMP walk extraction before counter conversion" do
    counter = {
      key_: "net.if.in[ifHCInOctets.49]", units: "bps",
      preprocessing: [
        { type: 28, params: "1.3.6.1.2.1.31.1.1.1.6.49\n0" },
        { type: 10 }, { type: 1, params: "8" }
      ]
    }
    expect { described_class.validate_bps!(counter) }.not_to raise_error
  end

  it "validates raw counters inside Zabbix SNMP get syntax" do
    counter = { key_: "traffic.in[1]", units: "bps", snmp_oid: "get[1.3.6.1.2.1.31.1.1.1.6.49]" }
    expect { described_class.validate_bps!(counter) }.to raise_error(ZabbixManager::Invalid, /preprocessing/)
    counter[:preprocessing] = [{ type: 10 }, { type: 1, params: "8" }]
    expect { described_class.validate_bps!(counter) }.not_to raise_error
  end
end
