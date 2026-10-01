# frozen_string_literal: true

# Small stateful JSON-RPC transport for executing the published business examples.
# It implements only their native API requests; unexpected methods fail the test.
class NativeApiFixture
  attr_reader :requests, :hosts, :interfaces, :macros, :items, :triggers

  def initialize
    @requests = []
    @hosts = [host("101", "router-01"), host("102", "router-02")]
    @interfaces = [snmp_interface("301", "101", "192.0.2.1"), snmp_interface("302", "102", "192.0.2.2")]
    @macros = [{ "hostmacroid" => "401", "hostid" => "101", "macro" => "{$OTHER_SECRET}",
                 "value" => "unrelated-secret", "type" => "1" }]
    @items = traffic_items("101", "Gi1/0/1", 201) + traffic_items("102", "Gi1/0/2", 211)
    @triggers = %w[interface_status bandwidth low_traffic reachability].each_with_index.map do |kind, index|
      { "triggerid" => (501 + index).to_s, "hostid" => "101", "description" => "Existing #{kind}",
        "status" => "0", "value" => "0", "expression" => "last(/router-01/net.if.status[Gi1/0/1])=0",
        "dependencies" => [], "tags" => [
          { "tag" => "managed_by", "value" => "zabbix_manager" },
          { "tag" => "line_id", "value" => "line-42:A" },
          { "tag" => "zabbix_manager_id", "value" => "interface:line-42:A:#{kind}" }
        ] }
    end
    @triggers << { "triggerid" => "599", "hostid" => "101", "description" => "Manual operator trigger",
                   "status" => "0", "value" => "1", "tags" => [], "dependencies" => [] }
  end

  def request(body, bearer_token: nil)
    message = JSON.parse(body)
    raise "fixture token is required" unless message["method"] == "apiinfo.version" || bearer_token == "example-token"

    @requests << message.slice("method", "params").deep_dup
    result = dispatch(message.fetch("method"), message.fetch("params"))
    JSON.generate(jsonrpc: "2.0", id: message.fetch("id"), result: result)
  end

  def uri
    URI("https://example.invalid/api_jsonrpc.php")
  end

  def safe_url
    uri.to_s
  end

  def close
    true
  end

  def writes
    requests.reject { |request| request["method"].end_with?(".get") || request["method"] == "apiinfo.version" }
  end

  private

  def dispatch(method, params)
    case method
    when "apiinfo.version" then "7.4.0"
    when "host.get" then get_hosts(params)
    when "hostgroup.get" then select([{ "groupid" => "20", "name" => "Network devices" }], params, "groupid")
    when "template.get" then select([{ "templateid" => "10001", "host" => "Generic SNMP" }], params, "templateid")
    when "proxygroup.get" then select([{ "proxy_groupid" => "30", "name" => "Branch proxies" }], params,
                                      "proxy_groupid")
    when "host.create" then create_host(params)
    when "host.update" then update(@hosts, "hostid", params)
    when "hostinterface.get" then select(@interfaces, params, "interfaceid")
    when "hostinterface.create" then create(@interfaces, "interfaceid", params)
    when "hostinterface.update" then update(@interfaces, "interfaceid", params)
    when "usermacro.get" then select(@macros, params, "hostmacroid")
    when "usermacro.create" then create(@macros, "hostmacroid", params)
    when "usermacro.update" then update(@macros, "hostmacroid", params)
    when "item.get" then select(@items, params, "itemid")
    when "item.create" then create(@items, "itemid", params)
    when "trigger.get" then select(@triggers, params, "triggerid")
    when "trigger.create" then create_trigger(params)
    when "trigger.update" then update(@triggers, "triggerid", params)
    when "history.get" then history(params)
    when "trend.get" then trends(params)
    when "problem.get" then problems(params)
    else raise "Unexpected native API method: #{method}"
    end
  end

  def host(id, name)
    { "hostid" => id, "host" => name, "name" => name, "status" => "0",
      "groups" => [{ "groupid" => "900" }], "templates" => [{ "templateid" => "90001" }],
      "tags" => [{ "tag" => "operator", "value" => "noc" }] }
  end

  def snmp_interface(id, hostid, ip)
    { "interfaceid" => id, "hostid" => hostid, "type" => "2", "main" => "1", "useip" => "1",
      "ip" => ip, "dns" => "", "port" => "161", "details" => { "version" => "2", "community" => "{$OTHER_SECRET}" } }
  end

  def traffic_items(hostid, interface, first_id)
    %w[in out status speed].each_with_index.map do |kind, index|
      { "itemid" => (first_id + index).to_s, "hostid" => hostid, "name" => "#{interface} #{kind}",
        "key_" => "net.if.#{kind}[#{interface}]", "type" => "20", "status" => "0",
        "value_type" => kind == "out" ? "0" : "3", "units" => %w[in out speed].include?(kind) ? "bps" : "",
        "snmp_oid" => "", "preprocessing" => [] }
    end
  end

  def select(records, params, id_key)
    rows = records.select do |record|
      scope = %w[hostid itemid triggerid].all? do |field|
        !params.key?("#{field}s") || Array(params["#{field}s"]).map(&:to_s).include?(record[field].to_s)
      end
      filters = params.fetch("filter", {}).all? do |field, values|
        Array(values).map(&:to_s).include?(record[field].to_s)
      end
      tags = params.fetch("tags", []).all? do |filter|
        record.fetch("tags", []).any? do |tag|
          tag["tag"] == filter["tag"] && (filter["operator"].to_i == 1 ? tag["value"] == filter["value"] :
            tag["value"].include?(filter["value"]))
        end
      end
      scope && filters && tags && (!params["monitored"] || record["status"] == "0")
    end
    rows = rows.first(params["limit"]) if params["limit"]
    rows.map { |record| project(record, params, id_key) }
  end

  def project(record, params, id_key)
    output = params.fetch("output", "extend")
    row = output == "extend" ? record.deep_dup : record.slice(id_key, *output).deep_dup
    { "selectTags" => "tags", "selectDependencies" => "dependencies",
      "selectPreprocessing" => "preprocessing" }.each do |option, field|
      row[field] = record.fetch(field, []).deep_dup if params.key?(option)
    end
    row
  end

  def get_hosts(params)
    select(@hosts, params, "hostid").map do |row|
      stored = @hosts.find { |entry| entry["hostid"] == row["hostid"] }
      { "selectGroups" => ["groups", "groups"], "selectHostGroups" => ["hostgroups", "groups"],
        "selectParentTemplates" => ["parentTemplates", "templates"] }.each do |option, (output, source)|
        row[output] = stored.fetch(source).deep_dup if params.key?(option)
      end
      if params.key?("selectInterfaces")
        row["interfaces"] = @interfaces.select { |interface| interface["hostid"] == row["hostid"] }.deep_dup
      end
      row
    end
  end

  def create_host(params)
    attributes = params.deep_dup
    interfaces = attributes.delete("interfaces") || []
    macros = attributes.delete("macros") || []
    result = create(@hosts, "hostid", attributes)
    hostid = result.fetch("hostids").first
    interfaces.each { |interface| create(@interfaces, "interfaceid", interface.merge("hostid" => hostid)) }
    macros.each { |macro| create(@macros, "hostmacroid", macro.merge("hostid" => hostid)) }
    result
  end

  def create_trigger(params)
    attributes = params.deep_dup
    hostname = attributes.fetch("expression")[%r{/(router-[\w-]+)/}, 1]
    owner = @hosts.find { |entry| entry["host"] == hostname } || raise("trigger expression has no fixture host")
    create(@triggers, "triggerid", attributes.merge("hostid" => owner.fetch("hostid")))
  end

  def create(records, id_key, params)
    ids = Array.wrap(params).map do |attributes|
      id = ((records.map { |row| row[id_key].to_i }.max || 0) + 1).to_s
      records << native(attributes).merge(id_key => id)
      id
    end
    { "#{id_key}s" => ids }
  end

  def update(records, id_key, params)
    ids = Array.wrap(params).map do |attributes|
      id = attributes.fetch(id_key).to_s
      existing = records.find { |entry| entry[id_key] == id } || raise("missing fixture #{id_key} #{id}")
      existing.merge!(native(attributes))
      id
    end
    { "#{id_key}s" => ids }
  end

  def native(attributes)
    attributes.deep_transform_values { |value| value.is_a?(Numeric) ? value.to_s : value }
  end

  def history(params)
    id = params.fetch("itemids").first.to_s
    item = @items.find { |entry| entry["itemid"] == id } || raise("unknown history item")
    raise "wrong history type" unless params.fetch("history").to_s == item.fetch("value_type")

    [params.fetch("time_till") - 60, params.fetch("time_till") - 120].each_with_index.map do |clock, index|
      value = id == "201" ? [2_000_000, 1_000_000][index] : [1_500_000, 500_000][index]
      { "itemid" => id, "clock" => clock.to_s, "ns" => "0", "value" => value.to_s }
    end
  end

  def trends(params)
    raise "trend.get has no sorting parameters" if params.key?("sortfield") || params.key?("sortorder")

    [2, 1].map do |offset|
      { "itemid" => params.fetch("itemids").first.to_s,
        "clock" => (params.fetch("time_till") / 3600 * 3600 - offset * 3600).to_s,
        "num" => (offset * 60).to_s, "value_min" => "500000", "value_avg" => "1000000.5",
        "value_max" => "3000000" }
    end
  end

  def problems(params)
    ids = params.fetch("objectids")
    raise "problem query must constrain the managed trigger IDs" if ids.empty? || ids.include?("599")

    ids.first(2).each_with_index.map do |id, index|
      { "eventid" => (701 + index).to_s, "objectid" => id.to_s, "clock" => (params.fetch("time_till") - 60).to_s,
        "name" => "Example line problem", "severity" => "4", "tags" => [] }
    end.first(params.fetch("limit"))
  end
end
