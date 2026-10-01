# Ruby Zabbix Api Module

[![Gem Version](http://img.shields.io/gem/v/zabbix_manager.svg)][gem]

[gem]: https://rubygems.org/gems/zabbix_manager

A Ruby client for the [Zabbix API][Zabbix API], with reusable device, interface and circuit monitoring workflows.

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

### Environment configuration

Environment loading is explicit. `connect` uses only its keyword arguments; `from_env` reads exactly four variables:

| Variable | Option |
| --- | --- |
| `ZABBIX_URL` | `url` |
| `ZABBIX_API_TOKEN` | `api_token` |
| `ZABBIX_USERNAME` | `username` |
| `ZABBIX_PASSWORD` | `password` |

```ruby
zabbix = ZabbixManager.from_env(verify_ssl: true)
```

Explicit keyword arguments override environment values, including `nil` to clear an inherited credential. Set either an API token or a username/password pair. Unknown options and non-boolean flags are rejected before connecting. Timeouts, logging and locking remain ordinary keyword options.

The HTTP transport uses Ruby's standard proxy discovery (`http_proxy`/`HTTP_PROXY`, `no_proxy`/`NO_PROXY`, with CGI protection). `no_proxy: true` disables proxies; `proxy: "http://proxy.example:8080"` selects an explicit HTTP proxy. HTTPS proxy URLs are rejected because this transport does not encrypt the connection to the proxy itself.

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

Pass a Ruby Logger or ActiveSupport logger to receive connection, request completion, duration, and failure events:

```ruby
zabbix = ZabbixManager.connect(
  url: "https://zabbix.example.com/api_jsonrpc.php",
  api_token: ENV.fetch("ZABBIX_API_TOKEN"),
  logger: Rails.logger
)
```

Logging uses `ActiveSupport::Logger` and `ActiveSupport::TaggedLogging`; structured credential filtering uses `ActiveSupport::ParameterFilter`. Pass `log_level: :info` to create a logger on standard error, or inject your application's logger. Logging is disabled unless one of these options is supplied, and logging failures do not change API outcomes.

Passwords, API tokens, authorization values, cookies, and session IDs are filtered. Request parameters and response bodies are not logged. API exceptions expose the server error code and request ID, without remote messages or data that might echo arbitrary secrets. Malformed or mismatched JSON-RPC responses and invalid mutation ID receipts raise `ProtocolError < TransportError`: a write may already have happened, so it must not be blindly replayed.

HTTPS certificate verification is disabled by default as required by this project. Set `verify_ssl: true` (and optionally `ca_file:`) to enable peer verification.

Zabbix 7 API-token requests need the `Authorization` header, so they cannot share that header with HTTP Basic authentication. The client rejects that combination instead of silently overwriting either credential.

Timeouts can be set together with `timeout:` or independently with `open_timeout:`, `read_timeout:`, and `write_timeout:`. `keep_alive_timeout:` controls persistent connection reuse. `request_timeout:` bounds the complete network operation, including a continuously progressing response, and defaults to `timeout:`. Waiting for another request on the same client is outside that budget. `max_response_bytes:` limits the decompressed response body (64 MiB by default). Exceeding either limit closes the connection and raises `TransportError`; mutations are never automatically replayed.

### Device and interface monitoring

`monitoring` provides device and line workflows using native Zabbix APIs only. There are no SQL operations, Rails models or persistence dependencies. Item identity is the stable pair `hostid + key_`; managed triggers use a dedicated `zabbix_manager_id` tag. Missing objects are created and existing ones are updated. Optional line checks removed from a definition are disabled after the remaining desired checks succeed; objects are never automatically deleted.

For a line inventory that already has interface traffic items discovered by Zabbix, use `reconcile_line`. It locates the host and unique inbound/outbound items, then creates or updates the selected checks. Use canonical fields `host` (or `host_candidates`), `interface_name`, `capacity_mbps`, and a stable, non-secret endpoint `line_id`. Convert external inventory column names before calling the library.

The complete workflows and return values are documented in [device monitoring](examples/device_monitoring.md), [line monitoring](examples/line_monitoring.md), and [traffic queries](examples/traffic.md). Public method comments document input, output, failures and remote side effects.

```ruby
zabbix.monitoring.reconcile_line(
  line_id: "line-42",
  description: "Example upstream circuit",
  capacity_mbps: 200,
  host_candidates: ["edge-switch-01", "192.0.2.10"],
  interface_name: "Ten-GigabitEthernet1/0/49",
  isp: "Example ISP",
  high_water: 0.90,
  recovery_water: 0.80,
  problem_window: "5m",
  recovery_window: "15m",
  severity: 4
)
```

The lookup accepts full and abbreviated interface names such as `Ten-GigabitEthernet1/0/49` and `Te1/0/49`. It refuses zero or multiple direction matches instead of selecting an item by response order. Trigger ownership comes from the managed identity tag; matching descriptions alone never adopt unrelated triggers.

Use `reconcile_lines(lines)` for imports. It reuses host and item discovery results within the batch, avoiding a full `item.get` scan for every line.

For a device-and-line batch, use `reconcile_network`. The whole input is structurally validated before the first device write. Devices are reconciled first, then lines, and the return value contains per-entry results plus a summary. Template linking and low-level discovery are asynchronous in Zabbix: retry discovery after the required items become available. Inspect any `:unknown` write outcome before repeating that entry.

```ruby
result = zabbix.monitoring.reconcile_network(
  devices: [
    {
      host: "edge-router-01",
      name: "Example edge router",
      groups: ["Network devices"],
      snmp: { ip: "192.0.2.10", community: ENV.fetch("SNMP_COMMUNITY") }
    }
  ],
  lines: [
    {
      line_id: "line-42", host: "edge-router-01",
      interface_name: "Ten-GigabitEthernet1/0/49", capacity_mbps: 200,
      high_water: 0.90, recovery_water: 0.80
    }
  ]
)

result.fetch(:summary)
```

```ruby
receipt = zabbix.monitoring.reconcile_device(
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
hostid = receipt.fetch(:hostid)
snmp_interface = zabbix.host_interfaces.for_host(hostid).find do |interface|
  interface["type"] == "2" && interface["main"] == "1"
end

zabbix.monitoring.reconcile_interface(
  host: { hostid: hostid, host: "router-01" },
  interface: { name: "GigabitEthernet1/0/1", interfaceid: snmp_interface.fetch("interfaceid") },
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

The library does not guess that SNMP discard/error counters equal packet-loss percentage. Supply an actual packet-loss item key (for example an ICMP loss item) and its item definition. Raw HC-octet traffic items must expose `bps` units and include change-per-second plus multiplier-8 preprocessing; otherwise line reconciliation refuses to build a dimensionally incorrect trigger. Thresholds use separate high and recovery values to avoid alert flapping. Line `high_water` and `recovery_water` are ratios greater than zero and at most one; percentages such as `90` are rejected. Interface threshold recovery is inclusive (`<=`), so a zero recovery threshold remains attainable.

Reconciliation is a sequence of remote API calls, not a transaction. Single-object methods raise immediately; batch methods return a sanitized error for each failed entry unless `fail_fast: true` is passed. Batch results distinguish `ok`, `error`, and `unknown`; summaries count each status. Transport failures during device reconciliation are conservatively `unknown`, since that workflow includes both lookup and write calls. Successful earlier remote writes are not rolled back if a later operation fails. After an uncertain outcome has been resolved, a retry can converge already-created items by stable keys. If a trigger create loses its response, readback must confirm both its managed identity and requested attributes. If that cannot be confirmed, `ResultUnknown` is raised and must not be automatically retried. A definite API rejection is propagated. The readback schedule can be set with `uncertain_write_delays:` (up to 60 seconds total). Trigger upserts and dependency read/modify/write operations are serialized within one client process. For multiple workers, inject a callable `upsert_lock` adapter that runs the block under an application-level distributed lock.

```ruby
ZabbixManager.connect(
  url: "https://zabbix.example.com/api_jsonrpc.php",
  api_token: ENV.fetch("ZABBIX_API_TOKEN"),
  upsert_lock: ->(key, &work) { MonitoringLock.with(key, &work) }
)
```

Invalid caller input raises `ZabbixManager::Invalid`, ambiguous remote ownership raises `ZabbixManager::Conflict`, Zabbix JSON-RPC failures raise `ZabbixManager::ApiError`, HTTP/network failures raise `ZabbixManager::TransportError`, and uncertain remote writes raise `ZabbixManager::ResultUnknown`. The focused item/interface/trigger deletion, status and dependency helpers require `hostid:` and verify existing ownership before writing. Custom trigger expressions and raw resource methods accept trusted Zabbix definitions; the host lookup context does not replace application authorization. Dependencies default to the same host; cross-host dependencies require `allow_cross_host_dependencies: true`. Do not pass untrusted page parameters directly to `query`, raw resource methods, or custom expressions.

### High-frequency API modules

`traffic.series` reads explicit item IDs; `traffic.for_interface` discovers both interface directions. Both expose missing data and query truncation, preserve numeric precision, and keep raw history separate from hourly trends. They never substitute zero or a stale last value for missing samples.

Multiword resource accessors use Ruby snake_case: `host_groups`, `host_interfaces`, `http_tests`, `media_types`, `proxy_groups`, `user_groups`, `user_macros`, `value_maps`, and `discovery_rules`.

The focused modules expose explicit operations:

* `hosts.reconcile`, `hosts.resolve`, `hosts.find_by_id`, `hosts.find_by_candidates`, `hosts.set_status`
* `monitoring.reconcile_device`, `monitoring.reconcile_devices`, `monitoring.reconcile_network`
* `monitoring.plan_line`, `monitoring.reconcile_line`, `monitoring.line_triggers`, `monitoring.line_problems`, `monitoring.disable_line`
* `hosts.link_templates`, `hosts.replace_templates`, `hosts.unlink_templates`
* `user_groups.replace_users`, `user_groups.replace_host_group_permissions`
* `host_interfaces.for_host`, `host_interfaces.reconcile_for_host`, `host_interfaces.delete_many`
* `items.for_host`, `items.upsert_by_key`, `items.upsert_many`, `items.set_status`, `items.delete_many`
* `triggers.for_host`, `triggers.upsert_for_host`, `triggers.add_dependencies`, `triggers.replace_dependencies`, `triggers.set_status`, `triggers.delete_many`


## Supported Ruby Versions
The minimum Ruby version is **3.4**. CI runs Ruby 3.4 and 4.0.

## Dependencies

* net-http
* active_support
* json
* logger

## Contributing

* Fork the project.
* Base your work on the master branch.
* Make your feature addition or bug fix, write tests, write documentation/examples.
* Run `bundle exec rake` and `bundle exec ruby script/verify_package.rb`.
* Make a pull request.

## CI and release

`script/verify_package.rb` checks the complete library inventory, installs into an isolated gem directory, exercises authentication and a resource request over a local HTTP socket, then saves that exact verified archive under `pkg/`. It also works when invoked outside the checkout.

Development tools are declared once in `Gemfile`, without historical version pins. `Gemfile.lock` records the versions verified together. Runtime dependencies declare only the minimum API version needed by the library; update the lockfile and run the gates when changing dependencies.


Pull requests and pushes to `master` run RSpec, documentation coverage, RuboCop, whitespace checks, and a built-Gem install smoke test. A `v<gem-version>` tag repeats the project gate, validates the tag/version, builds and installs a release candidate, then publishes that exact file through RubyGems Trusted Publishing. Configure the RubyGems trusted publisher for repository `gatework/zabbix_manager`, workflow `release.yml`, and environment `release` before pushing a release tag.

## Zabbix documentation

* [Zabbix Project Homepage][Zabbix]
* [Zabbix API docs][Zabbix API]

[Zabbix]: https://www.zabbix.com
[Zabbix API]: https://www.zabbix.com/documentation/current/en/manual/api

### Upgrading to 6.0

Version 6.0 requires Ruby 3.4 or newer. Use keyword connection and query arguments, snake_case resource accessors, the explicit exception classes, and the current monitoring result shapes shown above. Legacy aliases and the former `Basic` API are removed.
