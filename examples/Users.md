# Users

These examples target Zabbix 5.4 and later. Earlier servers use `alias` instead
of `username`; user group and role requirements also depend on the server version.

```ruby
userid = zbx.users.create(
  username: "operator",
  name: "Operations",
  surname: "Team",
  passwd: generated_password,
  roleid: roleid,
  usrgrps: [{ usrgrpid: user_group_id }]
)
```

Here `generated_password`, `roleid`, and `user_group_id` come from the calling
application. Querying the resource's identity field handles version differences.

```ruby
userid = zbx.users.get_id(zbx.users.identify.to_sym => "operator")
zbx.users.update(userid: userid, name: "Network operations")
```
