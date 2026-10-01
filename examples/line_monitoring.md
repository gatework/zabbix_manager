# Line monitoring

Use the shared `zbx` connection from [Connect](README.md#connect). A definition
describes one monitored interface endpoint. The module discovers existing items
and manages its own triggers through native Zabbix APIs; it does not query SQL
or persist an application circuit model.

## Preview and reconcile one endpoint

```ruby
line = {
  line_id: "line-42:A",
  host: "router-01",
  interface_name: "GigabitEthernet1/0/1",
  capacity_mbps: 100,
  description: "Example upstream circuit",
  high_water: 0.90,
  recovery_water: 0.80,
  problem_window: "5m",
  recovery_window: "15m",
  low_traffic: { below_bps: 50, recovery_bps: 1000, window: "5m" },
  status: true,
  speed: true,
  reachability_target: "192.0.2.2",
  severity: 4,
  tags: [{ tag: "service", value: "internet" }],
  comments: "Example circuit; the caller owns its business metadata."
}

plan = zbx.monitoring.plan_line(line)
plan.fetch(:triggers).each do |kind, attributes|
  puts({ kind: kind, expression: attributes[:expression],
         recovery_expression: attributes[:recovery_expression] }.inspect)
end

result = zbx.monitoring.reconcile_line(line)
puts result.slice(:hostid, :line_id, :itemids, :triggerids).inspect
```

`plan_line` performs only reads. It returns `hostid`, `host`, `interface`,
`line_id`, `itemids`, native `triggers`, dependencies expressed as trigger kinds,
and an optional `icmp_item` plan. `reconcile_line` resolves the plan again and
returns confirmed IDs. It does not blindly execute an earlier, possibly stale
preview.

Inbound and outbound items must be unique, numeric, enabled and measured in
`bps`. Recognized raw octet counters need change-per-second and multiplier-8
preprocessing. Full and abbreviated interface names are matched exactly after
normalization; ambiguous or missing items stop that endpoint before writes.

| Check | Enable with | Problem and recovery |
| --- | --- | --- |
| High traffic (`:bandwidth`) | Always enabled | Either direction above capacity × `high_water`; both recover at or below capacity × `recovery_water`. |
| Low traffic (`:low_traffic`) | `low_traffic: { ... }` | Both directions below `below_bps`; either recovers at or above `recovery_bps`. |
| Interface status (`:interface_status`) | `status: true` | Latest unsigned status differs from 1; recovers at 1. |
| ICMP (`:reachability`) | `reachability_target:` | Five-minute maximum is 0; recovers when two-minute minimum is 1. |

Water levels are ratios greater than 0 and at most 1, not percentages; recovery
must be below the high-water ratio. Capacity is the contracted
line capacity in Mbps, not the physical port speed. `speed: true` adds a positive
speed guard to the traffic expressions. It does not change the capacity used in
threshold calculations. A status trigger becomes a dependency of the other
checks so an interface outage suppresses their separate alerts.

Omit `low_traffic`, `status`, `speed` and `reachability_target` for a high-traffic
only definition. `low_traffic: {}` uses 50/1000 bps and a five-minute window.
`status: false` and `speed: false` explicitly disable those options.

## Select custom status and speed items

Pass an item ID when a custom template does not use recognizable names. It must
belong to the discovered host, be enabled and have the required numeric meaning.
The status contract is SNMP ifOperStatus: 1 means up. A speed guard uses a positive
numeric speed value. The same item cannot stand for multiple metrics.

```ruby
plan = zbx.monitoring.plan_line(
  line_id: "line-42:A",
  host: { hostid: 101, host: "router-01" },
  interface_name: "Gi1/0/1",
  capacity_mbps: 100,
  status: { itemid: 203 },
  speed: { itemid: 204 }
)
puts plan.fetch(:itemids).inspect
```

ICMP is collected by the assigned Zabbix server/proxy, not sent by the monitored
router. It cannot prove the forwarding path between the two line endpoints.
The target must be an IPv4 or IPv6 address. An existing compatible, enabled
`icmpping[target]` simple-check item is reused without changing its configuration.
Otherwise the module creates a one-minute simple check. Shared ICMP items are
never deleted or disabled by line retirement. Native `event_name` (Zabbix 5.2+)
and `opdata` (4.4+) can also be supplied; unsupported versions are rejected before
writes. Use macros appropriate to the generated expressions.

## Reconcile both endpoints

Use a stable, distinct `line_id` for each endpoint, even when both are on the same
host. The caller chooses which endpoints should be monitored.

```ruby
endpoints = [
  { line_id: "line-42:A", host: "router-01", interface_name: "Gi1/0/1", capacity_mbps: 100 },
  { line_id: "line-42:Z", host: "router-02", interface_name: "Gi1/0/2", capacity_mbps: 100 }
]

zbx.monitoring.reconcile_lines(endpoints).each do |entry|
  case entry.fetch(:status)
  when :ok
    puts entry.fetch(:result).inspect
  when :unknown
    warn "Inspect the managed trigger state before retrying #{entry[:line].inspect}"
  when :error
    warn entry.fetch(:error).inspect
  end
end
```

The batch validates all local definitions and performs discovery before the
first line write. Duplicate endpoint identities are rejected. Remote failures
remain per-endpoint results unless `fail_fast: true` is selected. If device
templates have just been linked, wait for Zabbix discovery to produce the items;
the module does not poll or create substitute traffic counters.

## Read and retire managed checks

```ruby
zbx.monitoring.line_triggers(hostid: 101, line_id: "line-42:A").each do |trigger|
  puts trigger.slice("triggerid", "description", "status", "value").inspect
end

problems = zbx.monitoring.line_problems(
  hostid: 101, line_id: "line-42:A", time_from: Time.now - 7 * 86_400, limit: 100
)
problems.fetch(:problems).each { |problem| puts problem.inspect }
warn "Problem results were truncated" if problems.fetch(:truncated)
```

Problems are filtered by the managed trigger IDs **before** the API limit is
applied. `problem.get` exposes unresolved and recently resolved problems according
to server retention settings, not a complete historical event archive.

```ruby
disabled_ids = zbx.monitoring.disable_line(hostid: 101, line_id: "line-42:A")
puts disabled_ids.inspect
```

Stable managed tags identify ownership. Same-description manual triggers are
preserved, conflicting ownership is rejected, and repeated reconciliation updates
the same trigger identities. Removing an optional check from a definition
disables its previously managed trigger only after the remaining desired checks
have been confirmed. `disable_line` disables all owned checks for that endpoint.
Neither operation deletes traffic items, ICMP items or unrelated triggers.

Multi-step writes cannot be rolled back as a transaction. A failed later step
leaves earlier confirmed changes in place. Workflows are serialized within one
manager instance; callers must coordinate separate processes that manage the
same endpoint. Use [traffic queries](traffic.md) to read the resulting items.
