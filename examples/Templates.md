# Templates

These examples use an initialized manager named `zbx`. Supply an existing template
group ID appropriate to the server version; Zabbix 6.2 and later distinguish
host groups from template groups. See the [template API](https://www.zabbix.com/documentation/7.0/en/manual/api/reference/template).

## Create a template

```ruby
zbx.templates.create(host: "Router template", groups: [{ groupid: 20 }])
```

## Manage host template links

Host-side operations preserve a clear boundary: link adds, unlink removes the
listed links, and replace sets the complete list. An empty replacement explicitly
clears all links. They return the confirmed host IDs.

```ruby
host_ids = [zbx.hosts.get_id(host: "router-01")]
zbx.hosts.link_templates(host_ids: host_ids, template_ids: [111, 214])
zbx.hosts.unlink_templates(host_ids: host_ids, template_ids: [214])
zbx.hosts.replace_templates(host_ids: host_ids, template_ids: [111])
```

## Find linked templates

```ruby
zbx.templates.get_ids_by_host(hostids: [zbx.hosts.get_id(host: "router-01")])
```
