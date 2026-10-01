# Device monitoring

Use the shared `zbx` connection from [Connect](README.md#connect). These methods
create or update Zabbix configuration through its native APIs. They do not use
SQL, Rails models, jobs or a local database.

## Create or update an SNMP device

The technical `host` name is the stable identity. Groups and templates accept
names or native ID references; template names are technical names. Referenced
groups, templates and proxies must already exist and be visible to the API user.
The `proxy_group` option requires Zabbix 7.0 or newer; a new host with no routing
option uses the server. Omitted routing leaves an existing host's assignment
unchanged. Supply `proxy: "Proxy name"` for an individual proxy.

```ruby
definition = {
  host: "router-01",
  name: "Example edge router",
  groups: ["Network devices"],
  templates: ["Generic SNMP"],
  proxy_group: "Branch proxies",
  snmp: { ip: "192.0.2.10", community: ENV.fetch("SNMP_COMMUNITY") },
  inventory_mode: 0,
  inventory: { vendor: "Example vendor", model: "Example router", serialno_a: "EXAMPLE-001" },
  tags: [{ tag: "service", value: "edge" }]
}

receipt = zbx.monitoring.reconcile_device(definition)
puts receipt.fetch(:hostid)
puts receipt.fetch(:managed).inspect
```

The result is `{hostid:, enabled:, managed: {group_ids:, template_ids:,
tag_names:}}`. The SNMP convenience option creates a main SNMP v2c interface
referencing `{$SNMP_COMMUNITY}` and a secret host macro. It never supplies a
default community. `ENV.fetch` above is an explicit application read, not an
additional environment variable imported by the library. Use `version: 1` for
SNMP v1, `dns:` instead of `ip:` for a DNS endpoint, or `interfaceid:` to select
an existing interface. Existing secret macros are updated individually; unrelated
macros are preserved.

## Preserve unmanaged configuration

Pass the previous `managed` receipt back for the **same technical host** when
replacing the collections this caller manages. Other groups, templates and tag
names are retained. An omitted collection is left unchanged; an explicit empty
collection removes its previously managed members. A host must retain at least
one group. No receipt is stored by the module.

```ruby
definition = {
  host: "router-01",
  groups: ["Network devices"],
  tags: [{ tag: "service", value: "edge" }]
}

first = zbx.monitoring.reconcile_device(definition)
second = zbx.monitoring.reconcile_device(
  definition.merge(tags: [{ tag: "service", value: "core" }], managed: first.fetch(:managed))
)
puts second.fetch(:managed).inspect
```

Without a previous receipt, requested groups and templates are added to existing
memberships. A conflicting value under an unowned tag name raises `Conflict`
before writes. An identical existing tag or requested membership can be adopted
into the returned receipt. Coordinate ownership when several applications manage
the same host.

## Use native interface definitions

For other interface protocols, pass native `interfaces` instead of `snmp`.
Groups and templates can also use explicit IDs. This example creates or updates
an agent-monitored device:

```ruby
receipt = zbx.monitoring.reconcile_device(
  host: "agent-01",
  groups: [{ groupid: 20 }],
  templates: [{ templateid: 10001 }],
  interfaces: [{ type: 1, main: 1, useip: 1, ip: "192.0.2.20", dns: "", port: "10050" }]
)
puts receipt.inspect
```

Native `macros`, `inventory`, `tags` and host attributes remain available. Use
the matching Zabbix version's API fields; `snmp` and `interfaces` are mutually
exclusive. Server capability checks reject proxy groups or secret macro types
on versions that do not support them.

## Disable or reconcile a batch

Disabling never creates a missing host. It returns `enabled: false` and a nil
`hostid` when there is no visible matching host.

```ruby
receipt = zbx.monitoring.reconcile_device(host: "retired-router", enabled: false)
puts receipt.inspect
```

```ruby
results = zbx.monitoring.reconcile_devices([
  { host: "router-01", name: "Updated display name" },
  { host: "retired-router", enabled: false }
])

results.each do |entry|
  case entry.fetch(:status)
  when :ok
    puts({ device: entry[:device], receipt: entry[:result] }.inspect)
  when :unknown
    warn "Inspect the remote state before retrying #{entry[:device].inspect}"
  when :error
    warn entry.fetch(:error).inspect
  end
end
```

All local definitions are validated before the batch writes. Names and remote
interface ownership are resolved before each device's writes. `fail_fast: true`
raises the first remote error. Multi-step API calls are not a transaction:
earlier confirmed steps remain if a later operation fails. A transport failure
can leave the result unknown; the library does not automatically replay writes.
