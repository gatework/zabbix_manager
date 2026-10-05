# CHANGELOG

## 6.0.2 (2026-10-05)

* Use the repository account name for Gem author metadata.

## 6.0.1 (2026-10-05)

* Discover batch item keys once per host and validate returned ownership, identities and duplicate targets before writes.
* Snapshot item, interface and trigger definitions; reject non-scalar or non-positive IDs in single-host operations.
* Report malformed high-level resource query responses as ProtocolError so batch reconciliation can isolate discovery failures.
* Correlate request logs by request_id, suppress rejected method text, and avoid tag/serialization overhead for disabled severities.
* Validate method encodings, Bearer-compatible tokens and logger severity setters before use while retaining Unicode password authentication.

* Filter native SNMPv3 authentication/privacy passphrases and complete escaped quoted credentials in diagnostic logs.
* Snapshot line definitions before discovery so caller mutations cannot change validated interfaces, identities or trigger attributes.
* Use an ID index for traffic metadata ownership checks, avoiding quadratic lookups while preserving query order and missing-item states.
* Correct Ruby layout violations to restore the existing RuboCop gate.

## 6.0.0 (2026-10-01)

* Fix role ID queries and host-scoped value map identities, keeping immutable host fields out of updates.
* Reject incomplete interface creation and duplicate resolved interface targets before remote writes.
* Preserve distinct interface names, validate standard 32-bit octet conversion, and check effective numeric item configuration before writing monitoring updates.
* Bound network request duration and decompressed response size, close failed connections, and never replay uncertain mutations.
* Complete Chinese module comments and correct public return-type documentation.

* Extract reusable Motor monitoring scenarios through native Zabbix APIs only, without SQL or application persistence.
* Add `traffic.series` and `traffic.for_interface` for precise history/trend reads with missing-data and truncation states.
* Add device name resolution, proxy groups, SNMP secret macros and caller-owned membership receipts; preserve unrelated configuration.
* Add line previews, low-traffic/status/ICMP checks, dependencies, scoped problem reads and managed trigger retirement.
* Return device receipts and per-kind line `triggerids`; expand public method contracts and executable workflow examples.

* Validate mutation receipts against requested IDs; empty, malformed or mismatched receipts remain unconfirmed outcomes.
* Require desired trigger state during lost-response recovery and serialize dependency replacement with appends.
* Replace obsolete template-side host-link helpers with `hosts.link_templates`, `replace_templates`, and `unlink_templates` using current host APIs.
* Use explicit `user_groups.replace_users` and `replace_host_group_permissions` operations with version-correct server fields.
* Verify packaged source inventory and isolated authenticated requests, then publish the exact verified artifact; declare IRB for Ruby 4 development consoles.

* Normalize multiword resource classes, files and accessors to Ruby CamelCase/snake_case without compatibility aliases.

* Require Ruby 3.4 or newer; refresh the dependency lockfile and remove development-tool version pins and duplicate declarations.
* Replace the split `Basic` hierarchy with `Resource`, remove compatibility aliases and parameter logging, and use keyword connection/request options.
* Use ActiveSupport logger/tagging/parameter filtering; make logging failure independent of API results.
* Add explicit `from_env` loading for `ZABBIX_URL`, `ZABBIX_API_TOKEN`, `ZABBIX_USERNAME`, and `ZABBIX_PASSWORD` only.
* Remove `current`, `user`, `debug`, `manager_request`, low-level client request helpers and legacy inventory field aliases; use explicit managers, `username`, `logger`/`log_level` and canonical monitoring fields.
* Validate JSON-RPC response shapes and IDs, report unconfirmed responses as `ProtocolError`, and prevent server text or exception causes from leaking secrets.
* Delegate proxy discovery and exclusions to Ruby, validate finite timeouts, and avoid closing an inherited parent TLS session after fork.
* Validate complete interface/item batches before writes, refuse ambiguous macro ownership, and distinguish missing values from empty strings during updates.
* Separate monitoring input, threshold and traffic-item rules, reject invalid units/expressions, and retain unknown write outcomes in batch results.

* Add Zabbix 7.x API-token authentication through the Bearer header while retaining the legacy 4.x-6.x authentication body.
* Reuse a thread-safe persistent `Net::HTTP` session and add explicit `close` lifecycle handling.
* Add injectable, credential-filtered request logging and stable JSON-RPC error handling.
* Add idempotent device/interface monitoring workflows with bandwidth, error, and packet-loss hysteresis triggers.
* Remove experimental `mojo_*` host/trigger methods and unsafe hard-coded SNMP defaults.
* Remove environment-specific item lookup helpers with hard-coded host data; use `monitoring.reconcile_line` instead.
* Remove copied Role user-group methods and the hard-coded historical problem-closing workflow.
* Remove dormant live-Zabbix scripts that were not part of the RSpec test pattern and mutated remote systems by default.
* Use ActiveSupport for deep key normalization and blank-value semantics.
* Batch line reconciliation to reuse host/item discovery and reject ambiguous or dimensionally invalid traffic items.
* Simplify template reference lookup and fix partial final-row sizing in screen creation.
* Replace the inherited Rails RuboCop profile with project-scoped lint, security, performance, packaging, layout, and safe style gates.
* Keep HTTPS verification disabled by default for compatibility, with an opt-in `verify_ssl: true` mode.
* Remove the unused `http` runtime dependency and support the `logger` default gem on modern Ruby.
* Add two-phase batch reconciliation for devices and lines with full preflight validation, sanitized per-entry errors, and summaries.
* Add focused host-interface CRUD, item batch/status/delete, trigger status/delete, and current trigger dependency append/replace APIs.
* Replace legacy exception names with `Invalid`, `Conflict`, `ApiError`, and `TransportError`.
* Add CI jobs for tests, formatting, Gem packaging, and trusted tag-based RubyGems publishing.
* Move project metadata to `https://github.com/gatework/zabbix_manager/tree/master`.
* Scope destructive and dependency operations by host, serialize host/interface reconciliation, and expose uncertain writes as `ResultUnknown`.
* Validate current Zabbix item/interface create contracts before writes and publish the exact smoke-tested Gem artifact.

### 5.0.7
