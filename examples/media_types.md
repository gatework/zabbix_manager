# Media types

These examples use an initialized manager named `zbx`. Required delivery fields
vary by media type and server version; see the matching Zabbix API reference.

```ruby
mediatypeid = zbx.media_types.create_or_update(
  name: "Operations email",
  type: 0,
  smtp_server: "smtp.example.test",
  smtp_helo: "zabbix.example.test",
  smtp_email: "zabbix@example.test"
)
```

Replace a user's complete media collection; omitted media are removed. The
wrapper chooses `medias` or `user_medias` for the connected server version.

```ruby
userid = zbx.users.get_id(zbx.users.identify.to_sym => "operator")
zbx.users.update_medias(
  userids: [userid],
  media: [{ mediatypeid: mediatypeid, sendto: "ops@example.test", active: 0, period: "1-7,00:00-24:00", severity: 63 }]
)
```
