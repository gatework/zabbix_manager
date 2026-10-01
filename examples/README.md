# Examples

Ruby 3.4 or later is required. Resource fields and methods depend on the Zabbix
server version; use its matching API reference. Applications and screens are
legacy server resources, not substitutes for modern tags and dashboards.

## Connect

Use an API token or explicit username/password credentials. Environment values
are read by the manager only for the documented connection settings.

```ruby
require "zabbix_manager"

zbx = ZabbixManager.new(
  url: "https://zabbix.example.test/api_jsonrpc.php",
  api_token: ENV.fetch("ZABBIX_API_TOKEN"),
  log_level: :info
)
```

```ruby
zbx = ZabbixManager.new(
  url: "https://zabbix.example.test/api_jsonrpc.php",
  username: "operator",
  password: ENV.fetch("ZABBIX_PASSWORD")
)
```

Close the transport when finished. `logout` also invalidates a username/password
session; API tokens remain managed by Zabbix.

```ruby
begin
  zbx.host_groups.all
ensure
  zbx.close
end
```

## Business workflows

These workflows use native Zabbix APIs only, without SQL or application models.
They share the same connection and return ordinary Ruby hashes.

- [Device monitoring](device_monitoring.md): named groups/templates, SNMP secret macros, proxy routing, ownership and batches.
- [Line monitoring](line_monitoring.md): preview, high/low traffic, interface status, ICMP, dependencies and retirement.
- [Traffic queries](traffic.md): history/trends, direction discovery, numeric precision and explicit missing/truncated data.

## Resource examples

- [Actions](Actions.md)
- [Applications](Applications.md)
- [Configurations](Configurations.md)
- [Discovery rules](discovery_rules.md)
- [Graphs](Graphs.md)
- [Host groups](host_groups.md)
- [Hosts](Hosts.md)
- [Web scenarios](http_tests.md)
- [Items](Items.md)
- [Maintenance](Maintenance.md)
- [Media types](media_types.md)
- [Problems](Problems.md)
- [Proxies](Proxies.md)
- [Screens](Screens.md)
- [Templates](Templates.md)
- [Triggers](Triggers.md)
- [User groups](user_groups.md)
- [User macros](user_macros.md)
- [Users](Users.md)
- [Value maps](value_maps.md)
- [Queries and filters](queries_with_filters.md)
