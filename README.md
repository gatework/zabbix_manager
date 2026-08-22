# Ruby Zabbix Api Module

[![Gem Version](http://img.shields.io/gem/v/zabbix_manager.svg)][gem]

[gem]: https://rubygems.org/gems/zabbix_manager

Most codes borrowed from zabbixapi, but fit for my everyday works well!
Simple and lightweight ruby module for working with [Zabbix][Zabbix] via the [Zabbix API][Zabbix API]

## Installation
```sh
# latest
gem install zabbix_manager

# specific version
gem install zabbix_manager -v 4.2.0
```

## Documentation
[http://rdoc.info/gems/zabbix_manager][documentation]

[documentation]: http://rdoc.info/gems/zabbix_manager

## Examples

### API token (Zabbix 7.x)

The token can come from an application settings page or another secret store. Pass it directly to the client; do not copy it into request parameters or logs.

```ruby
require "zabbix_manager"

zabbix = ZabbixManager.connect(
  url: "https://zabbix.example.com/api_jsonrpc.php",
  api_token: ENV.fetch("ZABBIX_API_TOKEN")
)

hosts = zabbix.hosts.get_raw(output: %w[hostid host])
zabbix.close
```

Zabbix 7.x requests use the `Authorization: Bearer` header. Earlier supported servers use the JSON-RPC `auth` property. Supplying `api_token` skips `user.login`, and `logout` only closes the local connection because an API token is not a Zabbix user session. API tokens are rejected on plain HTTP unless `allow_insecure_http: true` is explicitly set.

### Username and password

```ruby
zabbix = ZabbixManager.connect(
  url: "https://zabbix.example.com/api_jsonrpc.php",
  username: ENV.fetch("ZABBIX_USERNAME"),
  password: ENV.fetch("ZABBIX_PASSWORD")
)

begin
  zabbix.query(method: "host.get", params: { output: %w[hostid host] })
ensure
  zabbix.logout
end
```

A client keeps one persistent `Net::HTTP` session and serializes access to it, so repeated API calls reuse the same TCP/TLS connection. Use one client per process or worker when parallel request throughput matters; a client deliberately permits only one in-flight request. Call `close` when the client is no longer needed. A failed HTTP request closes the connection; the next request establishes a fresh session without automatically replaying the failed JSON-RPC mutation.

### Logging and HTTPS

Pass any Ruby Logger-compatible object to receive connection, request completion, duration, and failure events:

```ruby
zabbix = ZabbixManager.connect(
  url: "https://zabbix.example.com/api_jsonrpc.php",
  api_token: ENV.fetch("ZABBIX_API_TOKEN"),
  logger: Rails.logger
)
```

Passwords, API tokens, authorization values, cookies, and session IDs are filtered. Request parameters and response bodies are not logged; debug events contain only operation metadata.

HTTPS certificate verification is disabled by default as required by this project. Set `verify_ssl: true` (and optionally `ca_file:`) to enable peer verification.

Zabbix 7 API-token requests need the `Authorization` header, so they cannot share that header with HTTP Basic authentication. The client rejects that combination instead of silently overwriting either credential.

Timeouts can be set together with `timeout:` or independently with `open_timeout:`, `read_timeout:`, and `write_timeout:`. `keep_alive_timeout:` controls persistent connection reuse.

### Device and interface monitoring

`monitoring` provides idempotent workflows for frequent device and line updates. Item identity is the stable pair `hostid + key_`; managed triggers use a dedicated `zabbix_manager_id` tag. Missing remote objects are created and existing ones are updated. Omitted objects are never deleted.

For a line inventory that already has interface traffic items discovered by Zabbix, use `reconcile_line`. It accepts the field names from the historical `add_line_monitors.rb` importer, locates the host and the unique inbound/outbound items, then creates or updates one combined trigger. Use a stable, non-secret `line_id` so interface renames update the same trigger.

```ruby
zabbix.monitoring.reconcile_line(
  line_id: "line-42",
  description: "Example upstream circuit",
  capacity: 200, # Mbps
  device1: "edge-switch-01",
  ipaddr1: "192.0.2.10",
  iface1: "Ten-GigabitEthernet1/0/49",
  isp: "Example ISP",
  high_water: 0.90,
  recovery_water: 0.80,
  problem_window: "5m",
  recovery_window: "15m",
  severity: 4
)
```

The lookup accepts full and abbreviated interface names such as `Ten-GigabitEthernet1/0/49` and `Te1/0/49`. It refuses zero or multiple direction matches instead of selecting an item by response order. Existing triggers from the importer can be adopted when their description and `category=line_bandwidth` tag match.

Use `reconcile_lines(lines)` for imports. It reuses host and item discovery results within the batch, avoiding a full `item.get` scan for every line.

For a device-and-line batch, use `reconcile_network`. The whole input is structurally validated before the first device write. Devices are reconciled first, then lines, and the return value contains per-entry results plus a summary. Template linking and low-level discovery are asynchronous in Zabbix: if a new device's traffic items are not available yet, its line result is an error and the same batch can be safely rerun later.

```ruby
result = zabbix.monitoring.reconcile_network(
  devices: [
    {
      host: "edge-router-01",
      name: "Example edge router",
      groups: [{ groupid: 20 }],
      interfaces: [{
        type: 2, main: 1, useip: 1, ip: "192.0.2.10", dns: "", port: "161",
        details: { version: 2, community: ENV.fetch("SNMP_COMMUNITY") }
      }]
    }
  ],
  lines: [
    {
      line_id: "line-42", device: "edge-router-01",
      interface_name: "Ten-GigabitEthernet1/0/49", capacity_mbps: 200,
      high_water: 0.90, recovery_water: 0.80
    }
  ]
)

result.fetch(:summary)
```

```ruby
hostid = zabbix.monitoring.reconcile_device(
  host: "router-01",
  name: "Core router 01",
  groups: [{ groupid: 20 }],
  interfaces: [{
    type: 2,
    main: 1,
    useip: 1,
    ip: "192.0.2.1",
    dns: "",
    port: "161",
    details: { version: 2, community: ENV.fetch("SNMP_COMMUNITY") }
  }]
)

zabbix.monitoring.reconcile_interface(
  host: { hostid: hostid, host: "router-01" },
  interface: { name: "GigabitEthernet1/0/1", interfaceid: 12 },
  items: {
    inbound_bps: {
      key_: "if.hc.in.bps[1]", name: "WAN inbound", type: 20, value_type: 0,
      snmp_oid: "get[1.3.6.1.2.1.31.1.1.1.6.1]", delay: "1m", units: "bps",
      preprocessing: [
        { type: 10, params: "", error_handler: 0, error_handler_params: "" },
        { type: 1, params: "8", error_handler: 0, error_handler_params: "" }
      ]
    },
    outbound_bps: {
      key_: "if.hc.out.bps[1]", name: "WAN outbound", type: 20, value_type: 0,
      snmp_oid: "get[1.3.6.1.2.1.31.1.1.1.10.1]", delay: "1m", units: "bps",
      preprocessing: [
        { type: 10, params: "", error_handler: 0, error_handler_params: "" },
        { type: 1, params: "8", error_handler: 0, error_handler_params: "" }
      ]
    },
    in_errors: {
      key_: "if.in.errors.rate[1]", name: "WAN input errors", type: 20, value_type: 0,
      snmp_oid: "get[1.3.6.1.2.1.2.2.1.14.1]", delay: "1m",
      preprocessing: [{ type: 10, params: "", error_handler: 0, error_handler_params: "" }]
    },
    out_errors: {
      key_: "if.out.errors.rate[1]", name: "WAN output errors", type: 20, value_type: 0,
      snmp_oid: "get[1.3.6.1.2.1.2.2.1.20.1]", delay: "1m",
      preprocessing: [{ type: 10, params: "", error_handler: 0, error_handler_params: "" }]
    },
    packet_loss: {
      key_: "icmppingloss[198.51.100.1]", name: "WAN packet loss",
      type: 3, value_type: 0, delay: "1m", units: "%"
    }
  },
  thresholds: {
    bandwidth: { capacity_bps: 1_000_000_000, high_percent: 80, recovery_percent: 70 },
    errors: { high: 100, recovery: 20, function: "max", window: "5m" },
    packet_loss: { high: 5, recovery: 2 }
  }
)
```

The library does not guess that SNMP discard/error counters equal packet-loss percentage. Supply an actual packet-loss item key (for example an ICMP loss item) and its item definition. Raw HC-octet traffic items must expose `bps` units and include change-per-second plus multiplier-8 preprocessing; otherwise line reconciliation refuses to build a dimensionally incorrect trigger. Thresholds use separate high and recovery values to avoid alert flapping.

Reconciliation is a sequence of remote API calls, not a transaction. Single-object methods raise immediately; batch methods return a sanitized error for each failed entry unless `fail_fast: true` is passed. A retry safely converges already-created items by stable keys. If a trigger create loses its response and cannot be confirmed by readback, `ResultUnknown` is raised and must not be automatically retried. The readback schedule can be set with `uncertain_write_delays:` (up to 60 seconds total). The trigger upsert is serialized within one client process. For multiple workers, inject a callable `upsert_lock` adapter that runs the block under an application-level distributed lock.

```ruby
ZabbixManager.connect(
  url: "https://zabbix.example.com/api_jsonrpc.php",
  api_token: ENV.fetch("ZABBIX_API_TOKEN"),
  upsert_lock: ->(key, &work) { MonitoringLock.with(key, &work) }
)
```

Invalid caller input raises `ZabbixManager::Invalid`, ambiguous remote ownership raises `ZabbixManager::Conflict`, Zabbix JSON-RPC failures raise `ZabbixManager::ApiError`, HTTP/network failures raise `ZabbixManager::TransportError`, and uncertain remote writes raise `ZabbixManager::ResultUnknown`. Destructive/status/dependency methods require `hostid:` and verify ownership before writing. Dependencies default to the same host; cross-host dependencies require `allow_cross_host_dependencies: true`. Do not pass untrusted page parameters directly to raw `query` calls.

### High-frequency API modules

The focused modules expose explicit current operations instead of compatibility aliases:

* `hosts.reconcile`, `hosts.find_by_id`, `hosts.find_by_candidates`, `hosts.set_status`
* `hostinterfaces.for_host`, `hostinterfaces.reconcile_for_host`, `hostinterfaces.delete_many`
* `items.for_host`, `items.upsert_by_key`, `items.upsert_many`, `items.set_status`, `items.delete_many`
* `triggers.for_host`, `triggers.upsert_for_host`, `triggers.add_dependencies`, `triggers.replace_dependencies`, `triggers.set_status`, `triggers.delete_many`


## Supported Ruby Versions
This library aims to support and is [tested against][github-ci] the following Ruby
versions:

* Ruby 2.7 and newer

If something doesn't work on one of these versions, it's a bug.

This library may inadvertently work (or seem to work) on other Ruby versions,
however support will only be provided for the versions listed above.

If you would like this library to support another Ruby version or
implementation, you may volunteer to be a maintainer. Being a maintainer
entails making sure all tests run and pass on that implementation. When
something breaks on your implementation, you will be responsible for providing
patches in a timely fashion. If critical issues for a particular implementation
exist at the time of a major release, support for that Ruby version may be
dropped.

## Dependencies

* net/http
* active_support
* json
* logger

## Contributing

* Fork the project.
* Base your work on the master branch.
* Make your feature addition or bug fix, write tests, write documentation/examples.
* Commit, do not mess with rakefile, version.
* Make a pull request.

## CI and release

Pull requests and pushes to `master` run RSpec, documentation coverage, RuboCop, whitespace checks, and a built-Gem install smoke test. A `v<gem-version>` tag repeats the project gate, validates the tag/version, builds and installs a release candidate, then publishes that exact file through RubyGems Trusted Publishing. Configure the RubyGems trusted publisher for repository `gatework/zabbix_manager`, workflow `release.yml`, and environment `release` before pushing a release tag.

## Zabbix documentation

* [Zabbix Project Homepage][Zabbix]
* [Zabbix API docs][Zabbix API]

[Zabbix]: https://www.zabbix.com
[Zabbix API]: https://www.zabbix.com/documentation/current/en/manual/api
