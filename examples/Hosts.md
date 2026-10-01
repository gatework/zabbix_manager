# Hosts

These examples use an initialized manager named `zbx`. SNMP interface `details`
are supported by Zabbix 5.0 and later; consult the matching server API reference
for older interface schemas.

## Create or update a host

Supply groups and interfaces for a new host. Existing hosts may receive partial
metadata updates. Fields omitted from `reconcile` remain unchanged.

```ruby
zbx.hosts.reconcile(
  host: "router-01",
  name: "Core router",
  groups: [{ groupid: zbx.host_groups.get_or_create(name: "Routers") }],
  interfaces: [{
    type: 2, main: 1, useip: 1, ip: "192.0.2.10", dns: "", port: "161",
    details: { version: 2, community: "{$SNMP_COMMUNITY}" }
  }],
  macros: [{ macro: "{$SNMP_COMMUNITY}", value: snmp_community }]
)
```

Here `snmp_community` comes from the application's secret configuration.

## Update and query

```ruby
hostid = zbx.hosts.get_id(host: "router-01")
zbx.hosts.update(hostid: hostid, status: 0)
zbx.hosts.dump_by_id(hostid: hostid)
zbx.hosts.get_full_data(host: "router-01")
```

Use `reconcile` for interface changes, or `update_raw` when intentionally sending
an unconditional API update. Every interface ID must belong to the selected host.

```ruby
zbx.hosts.reconcile(host: "router-01", interfaces: [{ interfaceid: 12, main: 1 }])
zbx.hosts.update_raw(hostid: hostid, description: "Managed by operations")
```

## Delete

```ruby
zbx.hosts.delete(hostid)
```
