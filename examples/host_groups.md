# Hostgroups

This example assumes you have already initialized and connected the ZabbixManager.

For more information and available properties please refer to the Zabbix API documentation for Hostgroups:
[https://www.zabbix.com/documentation/4.0/manual/api/reference/hostgroup](https://www.zabbix.com/documentation/4.0/manual/api/reference/hostgroup)

## Create Hostgroup
```ruby
zbx.host_groups.create(name: "hostgroup")
```
