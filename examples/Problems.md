# Problems

This example assumes you have already initialized and connected the ZabbixManager.

For more information and available properties please refer to the Zabbix API documentation for MediaTypes:
[https://www.zabbix.com/documentation/5.2/manual/api/reference/problem](https://www.zabbix.com/documentation/5.2/manual/api/reference/problem)

## Get Problems
Problems are identified by `eventid`. Queries may also be filtered by name or
the following API parameters:
- `eventids`: Return only problems with the given IDs.
- `groupids`: Return only problems created by objects that belong to the given
  host groups.
- `hostids`: Return only problems created by objects that belong to the given
  hosts.
- `objectids`: Return only problems created by the given objects.
- `applicationids`: Return only problems created by objects that belong to the
  given applications. Applies only if object is trigger or item.
- `tags`: Return only problems with given tags. Exact match by tag and
  case-insensitive search by value and operator.
- `eventid_from`: Return only problems with IDs greater or equal to the given
  ID.
- `eventid_till`: Return only problems with IDs less or equal to the given ID.
- `time_from`: Return only problems that have been created after or at the given
  time.
- `time_till`: Return only problems that have been created before or at the
  given time.

See Zabbix API documentation for more details.

```ruby
# selecting by name (which is not unique)
zbx.problems.get_full_data(
  name: "Zabbix agent is not available (for 3m)"
)

# selecting by source eventids
zbx.problems.get_full_data(eventids: "86")

# selecting by source objectids
zbx.problems.get_full_data(objectids: "17884")

# selecting by timestamp
zbx.problems.get_full_data(time_from: 1611928989)
zbx.problems.get_full_data(time_till: 1611928989)
```

## Get all Problems
```ruby
zbx.problems.all
```
