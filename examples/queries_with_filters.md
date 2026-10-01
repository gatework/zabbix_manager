# Queries with zabbix_manager

These examples use an initialized manager named `zbx`.

## Query by identity

`get_id` requires an exact, unique match. Missing objects return `nil`; ambiguous
matches raise `ZabbixManager::Conflict`.

```ruby
zbx.hosts.get_id(host: "zabbix-server")
zbx.hosts.get_full_data(host: "zabbix-server")
zbx.host_groups.all # { "Linux servers" => "2", ... }
```

Resources scoped to a host need the host in their identity:

```ruby
zbx.http_tests.get_or_create(name: "Home", hostid: 101, steps: [
  { name: "Home", url: "https://example.test", no: 1 }
])
```

## Use API query parameters

`get_raw` sends the parameters directly to the resource's `.get` API method.
`query` is useful for methods without a dedicated resource wrapper.

```ruby
zbx.hosts.get_raw(groupids: [1, 2, 3], output: %w[hostid host name])
zbx.query(method: "host.get", params: {
  groupids: [zbx.host_groups.get_id(name: "Linux servers")],
  output: %w[hostid host]
})
```

## Request diagnostics

Configure `log_level: :debug` when constructing the manager. Logs contain request
metadata and timing. Request parameters, response bodies, and credentials are
not included. See the [connection examples](README.md#connect).
