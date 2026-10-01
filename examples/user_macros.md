# UserMacros

This example assumes you have already initialized and connected the ZabbixManager.

For more information and available properties please refer to the Zabbix API documentation for UserMacros:
[https://www.zabbix.com/documentation/4.0/manual/api/reference/usermacro](https://www.zabbix.com/documentation/4.0/manual/api/reference/usermacro)

### User and global macros
```ruby
zbx.user_macros.create(
    hostid: zbx.hosts.get_id( host: "Zabbix server" ),
    macro: "{$ZZZZ}",
    value: "192.0.2.1"
)
```
