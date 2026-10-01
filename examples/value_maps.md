# Valuemaps

This example targets Zabbix 5.4 or newer and assumes an authenticated manager and an existing host with ID 101.
Earlier versions use globally named value maps and omit `hostid`.

For more information and available properties please refer to the Zabbix API documentation for value maps:
[https://www.zabbix.com/documentation/7.0/en/manual/api/reference/valuemap](https://www.zabbix.com/documentation/7.0/en/manual/api/reference/valuemap)

## Create Valuemap
```ruby
zbx.value_maps.create_or_update(
  hostid: 101,
  name: "Test valuemap",
  mappings: [{ newvalue: "newvalue", value: "value" }]
)
```

## Delete Valuemap
```ruby
zbx.value_maps.delete(
  zbx.value_maps.get_id(hostid: 101, name: "Test valuemap")
)
```
