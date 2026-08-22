# CHANGELOG

## Unreleased

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
