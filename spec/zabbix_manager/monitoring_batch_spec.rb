# frozen_string_literal: true

require "spec_helper"

RSpec.describe ZabbixManager::Monitoring, "batch controls" do
  let(:client) { instance_double(ZabbixManager::Client) }
  let(:manager) { instance_double(ZabbixManager, client: client) }
  let(:monitoring) { described_class.new(manager) }

  it "rejects truthy strings and nil consistently before any batch work" do
    expect(client).not_to receive(:api_request)
    ["false", "true", nil, 0].each do |flag|
      expect { monitoring.reconcile_devices([], fail_fast: flag) }
        .to raise_error(ZabbixManager::Invalid, /fail_fast/)
      expect { monitoring.reconcile_lines([], fail_fast: flag) }
        .to raise_error(ZabbixManager::Invalid, /fail_fast/)
      expect { monitoring.reconcile_network(devices: [], lines: [], fail_fast: flag) }
        .to raise_error(ZabbixManager::Invalid, /fail_fast/)
    end
  end

  it "keeps explicit empty work distinct from any attempted remote operation" do
    expect(client).not_to receive(:api_request)
    result = monitoring.reconcile_network(devices: [], lines: [], fail_fast: true)
    expect(result).to include(devices: [], lines: [])
    expect(result[:summary].values).to all(eq(total: 0, succeeded: 0, failed: 0, unknown: 0))
  end
end
