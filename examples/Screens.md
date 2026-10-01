# Screens

Screens are a legacy Zabbix resource. These examples target servers that still
provide the [screen API](https://www.zabbix.com/documentation/4.0/manual/api/reference/screen).

```ruby
screenid = zbx.screens.get_or_create_for_host(
  screen_name: "Router traffic",
  graphids: zbx.graphs.get_ids_by_host(host: "router-01")
)

zbx.screens.delete(screenid)
```
