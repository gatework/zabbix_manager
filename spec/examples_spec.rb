# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "support/native_api_fixture"

RSpec.describe "Executable business examples" do
  root = File.expand_path("..", __dir__)
  documents = %w[device_monitoring line_monitoring traffic]

  let(:api) { NativeApiFixture.new }
  let(:zbx) { ZabbixManager.connect(url: "https://example.invalid/api_jsonrpc.php", api_token: "example-token") }

  before { allow(ZabbixManager::HttpTransport).to receive(:new).and_return(api) }

  around do |example|
    previous_community = ENV["SNMP_COMMUNITY"]
    previous_stdout, previous_stderr = $stdout, $stderr
    ENV["SNMP_COMMUNITY"] = "example-community"
    @output, @warnings = StringIO.new, StringIO.new
    $stdout, $stderr = @output, @warnings
    example.run
  ensure
    previous_community.nil? ? ENV.delete("SNMP_COMMUNITY") : ENV["SNMP_COMMUNITY"] = previous_community
    $stdout, $stderr = previous_stdout, previous_stderr
  end

  def host(name)
    api.hosts.find { |entry| entry["host"] == name }
  end

  def owned_triggers(hostid)
    api.triggers.select do |trigger|
      trigger["hostid"] == hostid.to_s && trigger["tags"].any? do |tag|
        tag == { "tag" => "managed_by", "value" => "zabbix_manager" }
      end
    end
  end

  def check_device(index, context)
    case index
    when 0
      expect(host("router-01")).to include("name" => "Example edge router", "monitored_by" => "2",
                                           "proxy_groupid" => "30")
      expect(host("router-01")["groups"]).to contain_exactly({ "groupid" => "900" }, { "groupid" => "20" })
      expect(api.interfaces.find { |entry| entry["interfaceid"] == "301" }).to include("ip" => "192.0.2.10")
      expect(api.macros).to include(hash_including("macro" => "{$SNMP_COMMUNITY}", "value" => "example-community",
                                                   "type" => "1"), hash_including("macro" => "{$OTHER_SECRET}"))
      expect(context.local_variable_get(:receipt)).to include(hostid: 101, enabled: true)
    when 1
      expect(host("router-01")["tags"]).to contain_exactly(
        { "tag" => "operator",
          "value" => "noc" }, { "tag" => "service", "value" => "core" }
      )
      expect(context.local_variable_get(:second)[:managed]).to include(tag_names: ["service"], group_ids: ["20"])
    when 2
      created = host("agent-01")
      expect(created).to include("groups" => [{ "groupid" => "20" }], "templates" => [{ "templateid" => "10001" }])
      expect(api.interfaces).to include(hash_including("hostid" => created.fetch("hostid"), "type" => "1"))
      expect(api.writes.count { |request| request["method"] == "host.create" }).to eq(1)
    when 3
      expect(context.local_variable_get(:receipt)).to include(hostid: nil, enabled: false)
      expect(api.writes).to be_empty
    when 4
      expect(context.local_variable_get(:results).pluck(:status)).to eq(%i[ok ok])
      expect(host("router-01")["name"]).to eq("Updated display name")
      expect(host("retired-router")).to be_nil
    end
  end

  def check_line(index, context)
    manual = api.triggers.find { |trigger| trigger["triggerid"] == "599" }
    expect(manual["status"]).to eq("0")
    case index
    when 0
      result = context.local_variable_get(:result)
      expect(result[:triggerids].keys).to contain_exactly(:interface_status, :bandwidth, :low_traffic, :reachability)
      expect(result[:itemids]).to include(inbound: 201, outbound: 202, status: 203, speed: 204)
      expect(api.items).to include(hash_including("key_" => "icmpping[192.0.2.2]", "hostid" => "101", "type" => "3"))
      dependencies = [{ "triggerid" => result[:triggerids][:interface_status].to_s }]
      owned_triggers(101).reject { |trigger| trigger["triggerid"] == "501" }.each do |trigger|
        expect(trigger["dependencies"]).to eq(dependencies)
      end
      expect(owned_triggers(101).pluck("status")).to eq(%w[0 0 0 0])
    when 1
      expect(context.local_variable_get(:plan)[:itemids]).to include(status: 203, speed: 204)
      expect(api.writes).to be_empty
    when 2
      expect(owned_triggers(101).find { |trigger| trigger["triggerid"] == "502" }["status"]).to eq("0")
      expect(owned_triggers(101).reject { |trigger| trigger["triggerid"] == "502" }.pluck("status")).to eq(%w[1 1 1])
      expect(owned_triggers(102).size).to eq(1)
      expect(api.writes.count { |request| request["method"] == "trigger.create" }).to eq(1)
    when 3
      expect(context.local_variable_get(:problems)[:problems].size).to eq(2)
      expect(api.writes).to be_empty
      query = api.requests.find { |request| request["method"] == "problem.get" }
      expect(query["params"]["objectids"]).to contain_exactly("501", "502", "503", "504")
    when 4
      expect(context.local_variable_get(:disabled_ids)).to contain_exactly(501, 502, 503, 504)
      expect(owned_triggers(101).pluck("status")).to eq(%w[1 1 1 1])
      expect(api.writes.map { |request| request["method"] }).to eq(["trigger.update"])
    end
  end

  def check_traffic(index, context)
    snapshot = context.local_variable_get(:snapshot)
    expect(snapshot[:series].pluck(:itemid)).to eq(%w[201 202])
    expect(snapshot[:series].pluck(:status)).to eq(%i[ok ok])
    expect(snapshot[:series].pluck(:record_count)).to eq([2, 2])
    expect(snapshot[:series].pluck(:truncated)).to eq([false, false])
    expect(api.writes).to be_empty
    if index == 2
      expect(snapshot[:series].pluck(:sample_count)).to eq([180, 180])
      expect(snapshot[:series].pluck(:peak_value)).to eq([BigDecimal("3000000"), BigDecimal("3000000")])
      expect(api.requests.count { |request| request["method"] == "trend.get" }).to eq(2)
    else
      expect(snapshot[:series].pluck(:current_value)).to eq([2_000_000, BigDecimal("1500000")])
      expect(api.requests.count { |request| request["method"] == "history.get" }).to eq(2)
    end
    expect(snapshot[:series].pluck(:direction)).to eq(%i[inbound outbound]) if [1, 3].include?(index)
    expect(JSON.parse(@output.string).fetch("series").last["current_value"]).to eq("1500000.0") if index == 4
  end

  documents.each do |document|
    path = File.join(root, "examples", "#{document}.md")
    fences = File.read(path).scan(/^```ruby\n(.*?)^```/m).flatten
    raise "Expected five independent Ruby examples in #{document}" unless fences.length == 5

    fences.each_with_index do |source, index|
      it "executes #{document}.md Ruby fence #{index + 1} through the native API" do
        manager = zbx
        context = Object.new.instance_eval { binding }
        context.local_variable_set(:zbx, manager)
        # These tracked documentation fences are executable project code, not external user input.
        eval(source, context, path, File.read(path).split(source).first.count("\n") + 1) # rubocop:disable Security/Eval

        expect(@output.string).not_to be_empty
        expect(@warnings.string).to be_empty
        expect(@output.string).not_to include("example-community", "unrelated-secret")
        case document
        when "device_monitoring" then check_device(index, context)
        when "line_monitoring" then check_line(index, context)
        when "traffic" then check_traffic(index, context)
        end
      ensure
        manager&.close
      end
    end
  end
  it "executes the README device and interface workflow using the returned host and SNMP interface IDs" do
    path = File.join(root, "README.md")
    text = File.read(path)
    source = text.scan(/^```ruby\n(.*?)^```/m).flatten.find do |fence|
      fence.include?("receipt = zabbix.monitoring.reconcile_device")
    end
    expect(source).not_to be_nil
    manager = zbx
    context = Object.new.instance_eval { binding }
    context.local_variable_set(:zabbix, manager)
    original_item_ids = api.items.pluck("itemid")
    original_trigger_ids = api.triggers.pluck("triggerid")
    # Execute this tracked README code against the same real facade as the business examples.
    result = eval(source, context, path, text.split(source).first.count("\n") + 1) # rubocop:disable Security/Eval

    expect(context.local_variable_get(:hostid)).to eq(101)
    expect(context.local_variable_get(:snmp_interface)).to include("interfaceid" => "301", "hostid" => "101")
    created_items = api.items.reject { |item| original_item_ids.include?(item["itemid"]) }
    expect(created_items.size).to eq(5)
    created_items.each { |item| expect(item).to include("hostid" => "101", "interfaceid" => "301") }
    expect(result[:itemids].values.map(&:to_s)).to match_array(created_items.pluck("itemid"))
    created_triggers = api.triggers.reject { |trigger| original_trigger_ids.include?(trigger["triggerid"]) }
    expect(created_triggers.size).to eq(3)
    expect(result[:triggerids].keys).to contain_exactly(:bandwidth, :errors, :packet_loss)
    expect(result[:triggerids].values.map(&:to_s)).to match_array(created_triggers.pluck("triggerid"))
    created_triggers.each do |trigger|
      expect(trigger).to include("hostid" => "101")
      expect(trigger["tags"]).to include(hash_including("tag" => "zabbix_manager_id", "value" => /interface:301:/))
      expect(trigger["expression"]).to include("/router-01/")
    end
    expect(@output.string + @warnings.string).not_to include("example-community", "unrelated-secret")
  ensure
    manager&.close
  end

  it "fails on unexpected API methods instead of silently accepting incomplete fixtures" do
    expect { zbx.query(method: "unexpected.get") }.to raise_error(RuntimeError, /Unexpected native API method/)
  ensure
    zbx.close
  end
end
