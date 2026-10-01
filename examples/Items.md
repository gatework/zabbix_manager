# Items

Use a host and stable item key for idempotent updates. These examples assume an
initialized manager named `zbx` and an existing host interface.

```ruby
hostid = zbx.hosts.get_id(host: "router-01")
itemid = zbx.items.upsert_by_key(
  hostid: hostid,
  interfaceid: 12,
  name: "System uptime",
  key_: "system.uptime",
  type: 0,
  value_type: 3
)
```

Batch methods verify the IDs belong to the selected host before changing them.

```ruby
zbx.items.set_status(hostid: hostid, itemids: [itemid], enabled: true)
zbx.items.find_by_key(hostid: hostid, key: "system.uptime")
zbx.items.delete_many(hostid: hostid, itemids: [itemid])
```
