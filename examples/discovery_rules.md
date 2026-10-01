# Discovery Rule

This example assumes you have already initialized and connected the ZabbixManager.

For more information and available properties please refer to the Zabbix API documentation for Actions:
[https://www.zabbix.com/documentation/3.2/manual/api/reference/drule](https://www.zabbix.com/documentation/3.2/manual/api/reference/drule)

## Create Discovery Rule
```ruby
zbx.discovery_rules.create(
  name: 'zabbix agent discovery',
  delay: '1800', # discover new machines every 30min
  status: '0', # action is enabled
  iprange: '192.0.2.0/24', # RFC 5737 documentation range
  dchecks: [{
    type: '9', # zabbix agent
    uniq: '0', # (default) do not use this check as a uniqueness criteria
    key_: 'system.hostname',
    ports: '10050',
  }],
)
```
