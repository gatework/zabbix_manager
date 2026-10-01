# Configuration import and export

These examples use an initialized manager named `zbx`. Import data must match a
format supported by the target Zabbix server.

```ruby
exported = zbx.configurations.export(
  format: "xml",
  options: { templates: [zbx.templates.get_id(host: "Router template")] }
)
```

Import a reviewed export file; enabled rules may create or update server objects.

```ruby
zbx.configurations.import(
  format: "xml",
  rules: {
    templates: { createMissing: true, updateExisting: true },
    items: { createMissing: true, updateExisting: true }
  },
  source: File.read("reviewed-template.xml")
)
```
