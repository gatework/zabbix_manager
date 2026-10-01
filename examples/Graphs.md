# Graphs

These examples use an initialized manager named `zbx`.

Graph ownership is determined by its items. For `create_or_update`, `hostid`
identifies the owning host or template during lookup and is omitted from the
write request. The API's `templateid` is the inherited source graph ID.

```ruby
hostid = zbx.hosts.get_id(host: "router-01")
item = zbx.items.find_by_key(hostid: hostid, key: "system.uptime")

graphid = zbx.graphs.create_or_update(
  name: "System uptime",
  hostid: hostid,
  width: 900,
  height: 200,
  gitems: [{ itemid: item.fetch("itemid"), color: "00AA00" }]
)
```

```ruby
zbx.graphs.get_ids_by_host(host: "router-01", filter: "uptime")
zbx.graphs.get_items(graphid)
zbx.graphs.update(graphid: graphid, ymax_type: 1)
zbx.graphs.delete(graphid)
```
