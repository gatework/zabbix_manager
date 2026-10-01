# User groups

These methods replace the complete membership or host-group permission list. An explicit empty array clears that list; `nil` is invalid.

```ruby
group_id = zbx.user_groups.get_or_create(name: "Network operators")

zbx.user_groups.replace_users(
  user_group_ids: [group_id],
  user_ids: [12, 15]
)

zbx.user_groups.replace_host_group_permissions(
  user_group_id: group_id,
  host_group_ids: [4, 5],
  permission: 3 # 0: deny, 2: read, 3: read-write
)
```

The helpers select `userids` before Zabbix 6.0 and `users` from 6.0 onward. Host-group permissions use `rights` before 6.2 and `hostgroup_rights` from 6.2 onward; the latter leaves template-group rights unchanged. Other operations accept the server's official schema through the resource methods or `query`.

Official references: [Zabbix 5.0 usergroup.update](https://www.zabbix.com/documentation/5.0/en/manual/api/reference/usergroup/update), [Zabbix 6.0 API changes](https://www.zabbix.com/documentation/6.0/en/manual/api/changes_5.4_-_6.0), [Zabbix 6.2 API changes](https://www.zabbix.com/documentation/6.2/en/manual/api/changes_6.0_-_6.2), [Zabbix 7.0 usergroup.update](https://www.zabbix.com/documentation/7.0/en/manual/api/reference/usergroup/update).
