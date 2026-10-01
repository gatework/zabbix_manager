# Httptests

This example assumes you have already initialized and connected the ZabbixManager.

For more information and available properties please refer to the Zabbix API documentation for Httptests:
[https://www.zabbix.com/documentation/4.0/manual/api/reference/httptest](https://www.zabbix.com/documentation/4.0/manual/api/reference/httptest)

## Create Web Scenario (httptest)
```ruby
zbx.http_tests.create(
  name: "web scenario",
  hostid: zbx.templates.get_id(host: "template"),
  applicationid: zbx.applications.get_id(name: "application"),
  steps: [
    {
      name: "step",
      url: "http://localhost/zabbix/",
      status_codes: 200,
      no: 1
    }
  ]
)

# or use (lib merge json):
zbx.http_tests.create_or_update(
  name: "web scenario",
  hostid: zbx.templates.get_id(host: "template"),
  applicationid: zbx.applications.get_id(name: "application"),
  steps: [
    {
      name: "step",
      url: "http://localhost/zabbix/",
      status_codes: 200,
      no: 1
    },
    {
      name: "step 2",
      url: "http://localhost/zabbix/index.php",
      status_codes: 200,
      no: 2
    }
  ]
)
```

## Update Web Scenario (httptest)
```ruby
zbx.http_tests.update(
  httptestid: zbx.http_tests.get_id(name: "web scenario"),
  status: 0
)

#You can check web scenario:
puts zbx.http_tests.get_full_data(name: "web scenario", hostid: zbx.templates.get_id(host: "template"))

```
