# Traffic queries

Use the shared `zbx` connection from [Connect](README.md#connect). Replace the
example host and item IDs with visible Zabbix resources. These examples only read
the native `item.get`, `history.get`, `trend.get` and host discovery APIs. They do
not access a database or modify monitoring configuration.

## Query explicit items

`time_from` and `time_till` accept `Time` or nonnegative Unix seconds. Both bounds
are inclusive; fractional `Time` values are rounded down to seconds. Numeric
history types are discovered separately for each requested item.

```ruby
end_time = Time.utc(2026, 9, 30, 12)
snapshot = zbx.traffic.series(
  hostid: 101,
  itemids: [201, 202],
  time_from: end_time - 3600,
  time_till: end_time,
  source: :history,
  limit: 12_000,
  max_points: 720
)

snapshot.fetch(:series).each do |series|
  puts({ itemid: series[:itemid], status: series[:status], units: series[:units],
         current_value: series[:current_value], peak_value: series[:peak_value],
         truncated: series[:truncated] }.inspect)
end
```

The result includes `hostid`, the normalized second timestamps, `source`, and a
`series` array in requested item order. Duplicate requested IDs are collapsed.
The host filter and returned ownership must agree. Direct item queries preserve
the item's declared units; they do not convert bytes, counters or percentages to
bits per second.

Each series keeps its identity and one of these statuses:

| Status | Meaning |
| --- | --- |
| `:ok` | At least one valid record was returned. Check `truncated` separately. |
| `:empty` | The visible numeric item has no returned records in this range. |
| `:unavailable` | The item is absent from the monitored items visible on this host. |
| `:unsupported` | The item is visible, but its value type is not numeric float or unsigned integer. |

Empty and unavailable results have no invented zero value. There is no fallback
to an item's `lastvalue`, another history type, or trends. API/transport failures
raise their original errors; malformed or out-of-scope responses raise
`ZabbixManager::ProtocolError`.

## Discover an interface's directions

An explicit host reference checks both its ID and technical name. A string or
array of candidate names/IP addresses is also accepted. Interface discovery
requires unique inbound and outbound items, `bps` units, and verified rate
preprocessing for recognized raw octet counters. Ambiguous or incompatible items
raise an error.

```ruby
end_time = Time.utc(2026, 9, 30, 12)
snapshot = zbx.traffic.for_interface(
  host: { hostid: 101, host: "router-01" },
  interface_name: "GigabitEthernet1/0/1",
  time_from: end_time - 3600,
  time_till: end_time
)

by_direction = snapshot.fetch(:series).to_h { |series| [series.fetch(:direction), series] }
puts by_direction.fetch(:inbound).slice(:itemid, :status, :current_value).inspect
puts by_direction.fetch(:outbound).slice(:itemid, :status, :current_value).inspect
```

This convenience query adds `host`, `interface_name`, and each series' `direction`
(`:inbound` or `:outbound`). An item disappearing after discovery remains present
as `:unavailable`; units changing away from `bps` raise a conflict.

## Read hourly trends explicitly

Trends are hourly statistics, not raw samples. `trend.get` has no sorting
parameters; the library sorts the returned records locally. A truncated trend
result cannot establish that it contains the latest hour or covers the whole
requested interval.

```ruby
end_time = Time.utc(2026, 9, 30, 12)
snapshot = zbx.traffic.series(
  hostid: 101,
  itemids: [201, 202],
  time_from: end_time - 7 * 86_400,
  time_till: end_time,
  source: :trends,
  limit: 1000,
  max_points: 168
)

snapshot.fetch(:series).each do |series|
  puts({ itemid: series[:itemid], records: series[:record_count],
         samples: series[:sample_count], truncated: series[:truncated] }.inspect)
end
```

Each point contains `clock`, `ns`, `count`, `value`, `min`, and `max`. For history,
an unreduced point has `count: 1` and equal value/min/max. For trends, these fields
preserve the hour's sample count, average, minimum and maximum; `ns` is zero.
Trend times remain hour-start timestamps; boundary hours are not prorated.

`limit` bounds the records retained **per item**. The API request asks for one
extra record to detect truncation. History requests the latest records first;
the result presents retained points in ascending time order. `record_count` counts
retained API records; `sample_count` sums their measurement counts. A result with
`truncated: false` can still have gaps or missing records due to retention.

`max_points` bounds presentation density. Adjacent records are combined using
sample-count weighted averages; minima, maxima and counts are preserved. The
combined point's `clock`/`ns` identify its final record. Compression does not fill
gaps, interpolate missing observations or create fixed-duration buckets.

`current_value` means the latest **returned in-range record**, or that record's
hourly average for trends. It is not a live reading. `peak_value` is the maximum
observed value (trend maximum) among retained records. Both are computed before
point reduction; neither establishes an interval-wide peak when truncated.

## Calculate utilization from caller-owned capacity

The caller supplies capacity and interprets the result. No weekday, business-hour
or capacity upgrade policy is embedded in the library. This example calculates
observed peak percentages separately for each direction; it never adds the two
directions of a full-duplex link.

```ruby
require "bigdecimal"

capacity_mbps = BigDecimal("100")
raise ArgumentError, "capacity must be positive" unless capacity_mbps.positive?

end_time = Time.utc(2026, 9, 30, 12)
snapshot = zbx.traffic.for_interface(
  host: { hostid: 101, host: "router-01" },
  interface_name: "GigabitEthernet1/0/1",
  time_from: end_time - 3600,
  time_till: end_time
)

snapshot.fetch(:series).each do |series|
  observed_peak = series[:peak_value]
  percent = observed_peak && BigDecimal(observed_peak.to_s) / (capacity_mbps * 1_000_000) * 100
  puts({ direction: series[:direction], status: series[:status],
         observed_peak_percent: percent&.round(2)&.to_s("F"), truncated: series[:truncated] }.inspect)
end
```

Unsigned history values remain Ruby integers. Decimal values and weighted
averages use `BigDecimal`; the library does not silently reduce them to `Float`.
Convert to floating-point only at a presentation boundary where that precision
loss is acceptable. To export JSON without losing decimal precision, encode
decimals explicitly as strings:

```ruby
require "json"

snapshot = zbx.traffic.series(
  hostid: 101, itemids: [201, 202],
  time_from: Time.utc(2026, 9, 30, 11), time_till: Time.utc(2026, 9, 30, 12)
)
payload = snapshot.deep_transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value }
puts JSON.generate(payload)
```

For an offline example check, supply a `zbx` fixture with the same public facade
and evaluate each Ruby fence independently in a binding containing that fixture.
The fixture needs host `101` / `router-01`, interface `GigabitEthernet1/0/1`, and
numeric inbound/outbound items `201` / `202`; return samples inside each requested
time range. These read-only examples do not depend on another fence's variables.
