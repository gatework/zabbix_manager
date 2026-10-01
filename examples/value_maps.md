# Valuemaps

This example assumes you have already initialized and connected the ZabbixManager.

For more information and available properties please refer to the Zabbix API documentation for Users:
[https://www.zabbix.com/documentation/4.0/manual/api/reference/valuemap](https://www.zabbix.com/documentation/4.0/manual/api/reference/valuemap)

## Create Valuemap
```ruby
zbx.value_maps.create_or_update(
  name: "Test valuemap",
  mappings: [{ newvalue: "newvalue", value: "value" }]
)
```

## Delete Valuemap
```ruby
zbx.value_maps.delete(
  zbx.value_maps.get_id(name: "Test valuemap")
)
```
