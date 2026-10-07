# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`PubsubGrpc.child_spec/1` and `config :pubsub_grpc, :start_pool, false`**: host
  applications can keep `:pubsub_grpc` from starting the connection pool and supervise it
  themselves with `PubsubGrpc` as a child, configured from the same application env.
- **CI: Dialyzer and dependency audit**: blocking `mix dialyzer` (PLTs cached in
  `priv/plts`) and `mix hex.audit` (requires Hex ≥ 2.5.1) jobs; publishing now requires
  both. The accepted advisories are listed under "Known advisories" below.
- **Common options on every operation**: all public operations now take a trailing
  `opts` keyword list with `:timeout` (deadline for the gRPC call; waits for a pool
  connection or an auth token fetch come on top of it) and `:pool` (pool name).
  Before, `create_topic`, `get_topic`, `delete_topic`, `get_subscription`,
  `delete_subscription`, `publish_message` and five `Schema` functions ignored them, and
  no operation honoured `:pool`. New arities: `create_topic/3`, `get_topic/3`,
  `delete_topic/3`, `get_subscription/3`, `delete_subscription/3`, `publish_message/5`
  (`publish_message/4` also accepts options in place of attributes, but only a keyword
  list of `:timeout`/`:pool`; any other list is validated as attributes and rejected),
  `create_schema/5`, `delete_schema/3`, `validate_schema/4`, `validate_message/5`,
  `validate_message_with_schema/6`. Existing arities are unchanged.
- **Request limits checked locally** ([Pub/Sub quotas](https://cloud.google.com/pubsub/quotas#resource_limits)):
  `publish/4` rejects more than 1,000 messages or more than 10 MiB of message data plus
  attribute keys and values; `acknowledge/4`, `modify_ack_deadline/5` and `nack/4` reject
  more than 512 KiB of ack IDs; `pull/4` rejects a `max_messages` above the int32 maximum
  (it used to raise during encoding). Each returns `:validation_error` naming the limit.
- **Connection checkout retry**: when no pooled connection is ready (`:not_connected`),
  `PubsubGrpc.Client.execute/2` and every operation wait up to `min(timeout, 2 s)` for one
  and retry once, instead of failing immediately after startup or during a reconnect.
- **New `:auth_timeout` config** (`config :pubsub_grpc, :auth_timeout, ms`, a positive
  integer, default `10_000`, read at runtime): the maximum time for one auth token fetch
  (Goth or gcloud CLI). An invalid value fails startup with an `ArgumentError`; one set
  at runtime after startup falls back to the default.
- `PubsubGrpc.Auth.request_opts/1` builds request options for a given channel (the token
  only over TLS), and `PubsubGrpc.Auth.invalidate/1` drops a token from the cache only if
  it is still the cached one.

### Changed
- **Dependency refresh**: `grpc`/`grpc_core` 1.0.2 → 1.0.5, `grpc_connection_pool` 0.5.3,
  `cowlib` 2.20.0, `mint` 1.11, `finch` 0.24, `hpax` 1.1. Behaviour notes:
  - `grpc`/`grpc_core` 1.0.5 encode the `grpc-timeout` header exactly. On 1.0.2, timeouts
    of 1 s or more were truncated: `timeout: 90_000` was sent as `1M` (60 s) and `1_500` as
    `1S`. Non-whole-second timeouts and timeouts of 60 s or more (e.g. `pull/4` with a long
    `:timeout`) are now honoured. The 30_000 ms default (`:default_timeout`) is unaffected.
  - `GRPC.Stub.connect/2` now establishes the connection asynchronously with a
    `:connect_timeout` (default 15 s) and keeps fail-fast semantics. No API change here.
  - `cowlib` 2.20.0 adds the HPACK big-integer cap on the gun/gRPC response path.
    Consumers should run `mix deps.update grpc grpc_core grpc_connection_pool cowlib`.
- **The `grpc_connection_pool` requirement is raised to `~> 0.5.3`** (was `~> 0.5.1`). 0.5.3
  has no runtime code change (only its `endpoint_config` typespec now uses
  `%GRPC.Credential{}`), but its release notes cover the grpc 1.0.5 / cowlib 2.20.0 /
  mint 1.11 / finch 0.24 / hpax 1.1 refresh, so consumers resolve a pool release that
  documents those bumps.
- **The `:pubsub_grpc_auth_cache` ETS table is now `:protected`** and written only by the
  internal PubsubGrpc.Auth.Cache process. Other processes can still read it, but writing
  to it directly (previously possible because it was `:public`) now raises `ArgumentError`.
- `PubsubGrpc.TaskSupervisor` (a `Task.Supervisor`) is added to the application
  supervision tree; it runs token fetches.
- **Startup now fails for two configurations that used to fail silently** (both raise
  `ArgumentError` with the fix in the message):
  - `config :pubsub_grpc, GrpcConnectionPool` is present but invalid (e.g. a missing
    `host`, or not a keyword list). Previously this was logged at debug level and the
    application silently fell back to the legacy/production configuration. An invalid
    legacy `:emulator` / `:default_pool_size` config also raises now, instead of falling
    back to production defaults.
  - An endpoint whose type is not `:local` has neither `:ssl` nor `:credentials`.
    Previously it connected over plaintext h2c and sent auth tokens over it.
- **Auth follows the connection, not the configuration**: the bearer token is attached
  per checked-out channel, and only if that channel uses TLS. A plaintext `:local`
  endpoint (the emulator) therefore never gets a token, with or without the legacy
  `:emulator` key. A `type: :local` `GrpcConnectionPool` config no longer also needs the
  `:emulator` key. The `:emulator` key itself no longer switches off authentication: it
  must be a keyword list (any other value, such as `true` or `false`, is ignored with a
  warning). The connection configuration is resolved once at startup.
  `PubsubGrpc.Auth.request_opts/0` still decides from the global configuration; prefer
  `request_opts/1` in custom `execute/2` callbacks.
- **TLS defaults**: `:ssl_opts` are now merged over the verified defaults
  (`GrpcConnectionPool.Config.default_production_ssl/0`: system CAs, `verify_peer`, hostname
  check) instead of replacing them. A user `:cacertfile` replaces the default `:cacerts`.
  A `:production` endpoint without `:ssl`, and any endpoint (including `:local`) with
  `ssl: []`, gets these defaults.
- **CI hardening**: actions pinned to commit SHAs (Dependabot weekly, also for Hex deps),
  checkouts don't persist credentials, `mix deps.get --check-locked` in every job, publish
  gated by the `hex` environment, the CI emulator binds to 127.0.0.1, compile/test matrix
  on Elixir 1.18.4/OTP 27.3 and 1.19.3/OTP 28.1.
- **Emulator**: docker-compose, `mix emulator.start` and the README use
  `google/cloud-sdk:489.0.0-emulators` bound to `127.0.0.1:8085`.
- **Dev deps**: `ex_doc ~> 0.40`; added `dialyxir ~> 1.4`.
- **Requirements documented**: Elixir ≥ 1.18 and Erlang/OTP ≥ 27 (cowlib 2.20 needs OTP 27's
  `maybe`; jose 1.11.12, via optional goth, needs OTP 26+).
- ⚠ **Stricter `project_id` validation**: project IDs must follow the GCP format (6–30
  lowercase letters, digits and hyphens, starting with a letter and not ending with a
  hyphen). Project numbers (`"123456789012"`) and legacy domain-scoped IDs
  (`"example.com:my-project"`) are also accepted. Anything else, which the API would
  reject anyway, now returns `:validation_error` without a network call. Check
  non-standard IDs, such as short IDs or IDs with uppercase letters or underscores, before
  upgrading.
- `validate_message/4,5` validates `schema_name`: it must be a schema ID or
  `projects/<project>/schemas/<schema_id>`.
- Publish message validation is stricter: a message's `:data` must be a binary and its
  `:attributes` a map. Before, `%{data: 123, attributes: %{...}}` or
  `%{data: "x", attributes: [...]}` passed validation and raised during encoding.
- The `PubsubGrpc.Error` docs now state that `details` holds raw upstream terms and must
  not be logged verbatim.
- PubsubGrpc.Telemetry.span/3 and auth_span/2 are now `@doc false`: they are internal
  helpers, not public API. The attachable events are unchanged.
- **Auth telemetry `:result` shape**: `[:pubsub_grpc, :auth, :stop]` metadata `:result` is
  now `:ok | {:error, code}` (was `:ok | :error`). Update handlers that match on `:error`.

### Fixed
- **Emulator image**: CI, docker-compose, `mix emulator.start`, the README and the test
  helper's hint pinned `google/cloud-sdk:489.0.0-stable`, which has no Java and no
  pubsub-emulator component, so `gcloud beta emulators pubsub start` exited at once. They
  now use `google/cloud-sdk:489.0.0-emulators`, still bound to `127.0.0.1:8085`.
- **CI runs the integration tests**: with no emulator, the test helper silently skipped
  them. The CI step now waits until the emulator answers HTTP (failing, with its logs,
  otherwise), the suite runs once (`mix coveralls.html`), and `test/test_helper.exs`
  raises instead of skipping when `CI` is set and the emulator is unreachable.
- **The telemetry docs now match the emitted metadata**: the `PubsubGrpc.Telemetry`
  moduledoc lists the exact keys for each operation. For example, `pull` carries
  `:max_messages`, not `:message_count`, and the docs now also list `:ack_count`,
  `:ack_deadline_seconds`, `:schema_type`, `:schema_name` and `:encoding`.
- **Auth events go through `Telemetry.auth_span/2`**: the `:source` is `:goth`,
  `:gcloud` or `:custom` (the documented `:cache`/`:network` values were never emitted;
  cache hits emit no event). One span is emitted per real fetch, not per waiting caller.
  (The `:result` shape change is listed under Changed.)
- **Typespecs no longer reference GRPC.Channel.t/0 / GRPC.RPCError.t/0**, which grpc
  1.0.3+ removed and which caused Dialyzer `unknown_type` warnings for consumers. Specs now
  use new public struct types: `t:PubsubGrpc.Client.channel/0`,
  `t:PubsubGrpc.Error.grpc_error/0`, `t:PubsubGrpc.topic/0`, `t:PubsubGrpc.subscription/0`,
  `t:PubsubGrpc.Schema.schema/0`, `t:PubsubGrpc.Schema.validate_schema_response/0` and
  `t:PubsubGrpc.Schema.validate_message_response/0`.
- **`PubsubGrpc.execute/2` and `PubsubGrpc.with_connection/2` no longer raise** when the
  callback returns something other than `{:ok, _}` / `{:error, _}` (e.g. `:ok` or a map).
  Such values are now returned as `{:ok, value}`; `{:ok, result}` and `{:error, reason}`
  callback results are normalized as before.
- Doc examples for `PubsubGrpc.execute/2`, `PubsubGrpc.with_connection/2` and
  `PubsubGrpc.Client` now unwrap `{:ok, auth_opts} = PubsubGrpc.Auth.request_opts(channel)`
  instead of passing the `{:ok, opts}` tuple (or no auth) as request options.
- **Token-refresh stampede**: on a cache miss, concurrent callers no longer each fetch a
  token. Exactly one fetch runs at a time and every caller waiting on it gets its
  result. Cache hits are still lock-free ETS reads.
- **Auth token fetches can no longer hang callers**: a fetch exceeding `:auth_timeout`
  is aborted and every waiter gets `{:error, %PubsubGrpc.Error{code: :deadline_exceeded}}`.
  A timed-out `gcloud` OS process is now killed. Previously it kept running, because
  `System.cmd/3` children survive their Erlang process.
- **gcloud CLI output is validated before use**: `gcloud` is resolved with
  `System.find_executable/1` (missing → `:unauthenticated`, "gcloud not found"), and the
  token is the last output line that looks like an access token (base64url characters,
  at least 20 long). Before, merged stderr text (warnings, error messages, "Done.") could
  end up in the `authorization` header.
- **Cached token invalidated on `UNAUTHENTICATED`**: when one of this library's
  operations fails with gRPC status 16, the token that request carried is dropped from the
  cache if it is still the cached one, so the next request fetches a fresh token instead
  of reusing a revoked or rotated one until its TTL ran out. A late rejection of an old
  token never evicts a newer one.
- **The auth token is never sent over a plaintext connection.** Previously the decision
  followed the global configuration, so a per-call `:pool` pointing at a non-TLS
  endpoint, under a production configuration, received the bearer token over h2c.
- **`Auth.clear_cache/0` during an in-flight fetch**: the fetch still answers its waiting
  callers, but its token is no longer cached, so a token fetched with the old credentials
  can't outlive a clear made after rotating them.
- Callers that ask for a token after `Auth.clear_cache/0` start a new fetch instead of
  joining one that began before the clear.
- Only `UNAUTHENTICATED` from the configured pool invalidates the shared token; a custom
  `:pool` endpoint rejecting it no longer forces refetches for every pool.
- **A bad `:auth_timeout` no longer crashes the token cache** (a negative value raised
  inside `Auth.Cache`, `:infinity` raised from every operation); see Added.
- Goth failures keep only a tag (exception module or error atom) in `Error.details`, never
  the raw exception or response.
- Topic, subscription and schema IDs with a trailing newline are rejected by validation
  (the anchors allowed one).
- `PubsubGrpc.Auth.get_token/0` returns `{:error, %PubsubGrpc.Error{}}` instead of exiting
  when the token cache process is unavailable (for example while it restarts).
- **The configured pool name is used everywhere**: `PubsubGrpc.Client` and every API
  function default to the pool named in `config :pubsub_grpc, GrpcConnectionPool`
  (`pool: [name: ...]`). A config without a pool name now starts the pool as
  `PubsubGrpc.ConnectionPool`. Before, it started under the dependency's default name,
  which none of the API functions could reach.
- **update-protos.sh** no longer deletes all of `lib/`; protoc (SHA-256 verified), the
  googleapis commit and protoc-gen-elixir 0.17.0 are pinned.
- README "Viewing Logs" code block; `LICENSE` is included in the generated docs.

### Removed
- PubsubGrpc.Auth.init_cache/0 (undocumented, `@doc false`). The token table is created
  and owned by the internal PubsubGrpc.Auth.Cache process, which the application starts.

### Tests
- Added Schema API integration tests (Avro; the emulator doesn't support
  `protocol_buffer`), auth-failure tests through the public API, and full `Result` clause
  coverage. Also covered: the gcloud CLI's own deadline kill, a fetch task killed
  mid-flight, a raising fetcher, and the Goth success, TTL-skew and error paths (real
  Goth with a stub HTTP client).
- List tests read every page; `modify_ack_deadline` is checked via redelivery; the
  publish-batch test checks each message's data and attributes.
- Polling uses a deadline-bounded `eventually/3` instead of `:timer.sleep`; resource
  names are unique and always cleaned up; connection tests use dedicated pools; most
  integration modules run async.
- Removed tautological and duplicate tests; misnamed test files renamed
  (`client_test.exs`, `api_validation_test.exs`).
- `coveralls.json` excludes generated protos, mix tasks and test support, and sets a 90%
  minimum coverage.

### Known advisories
`mix hex.audit` reports the following; all are accepted and listed in `mix.exs` under
`hex: [ignore_advisories: ...]`:
- **cowlib EEF-CVE-2026-43966 (MEDIUM) / EEF-CVE-2026-43969 (LOW).** They affect every
  cowlib ≥ 2.9.0 and no fix has been released. The vulnerable encoders
  `cow_http_struct_hd:escape_string/2` and `cow_cookie:cookie/1` are not called on the gRPC
  client path.
- **gun GHSA-w4f7-4cxr-rv3c.** The advisory's "patched" version, 2.16.0, is a cowboy version,
  so scanners flag every gun release including 2.6.0. grpc 1.0.5 pins `gun ~> 2.4.0`. There
  is no `override: true`: it would not reach consumers, would not clear the scanner, and
  would run gun outside grpc's tested range.

## [0.5.0] - 2026-07-26

### Changed
- **License changed from MIT to Apache-2.0.** The `LICENSE` file is now the full
  Apache License 2.0 text and `mix.exs` declares `Apache-2.0`, matching the license of
  the `grpc_connection_pool` and `grpc` dependencies. Releases up to and including 0.4.2
  remain MIT-licensed; only 0.5.0 onward is Apache-2.0. Apache-2.0 is still permissive,
  but it adds an explicit patent grant and requires that recipients be given a copy of
  the license and notice of any modified files.
- **Updated `grpc_connection_pool` from 0.3.0 to 0.5.1**, which moves the underlying
  `grpc` dependency to 1.0 (was 0.11.5). `protobuf` moves 0.16 → 0.17 and `gun` to 2.4.1.
  The `GrpcConnectionPool` API used by this library (`GrpcConnectionPool.get_channel/1`,
  `GrpcConnectionPool.status/1`, `GrpcConnectionPool.stop/1`, and the `Config` builders
  `new/1`, `from_env/1`, `local/1`, `production/1`) is unchanged.
- The dependency requirement is now `~> 0.5.1` rather than an exact pin, so patch updates
  no longer require a release here.

### Fixed
- **Removed `{GRPC.Client.Supervisor, []}` from the application supervision tree.**
  grpc 1.0 deleted that module — the name is now just the registered name of a
  `DynamicSupervisor` that grpc starts itself in GRPC.Client.Application. Keeping the
  child spec crashes at boot with *"The module GRPC.Client.Supervisor was given as a child
  to a supervisor but it does not exist"*. Nothing replaces it; no manual start is needed.

### Upgrade notes
- No changes are required in application code. If you added `{GRPC.Client.Supervisor, []}`
  to your **own** supervision tree (pre-1.0 grpc's README recommended it), remove it — it
  will crash at boot under grpc 1.0.
- If you attached telemetry handlers to `[:grpc_connection_pool, :channel, :gun_down]` or
  `[:grpc_connection_pool, :channel, :gun_error]`, switch to the adapter-agnostic
  `[:grpc_connection_pool, :channel, :connection_down]` (metadata: `pool_name`, `reason`).
  Those two events were removed upstream in `grpc_connection_pool` 0.5.0. This library's
  own `[:pubsub_grpc, ...]` events are unaffected.

## [0.4.2] - 2026-05-14

### Changed
- Version bump only (package metadata).

## [0.4.1] - 2026-05-14

### Added
- Telemetry events for publish/pull/ack operations.

### Fixed
- Goth token expiry handling when `expires` is returned as an integer.
- Credential-safety and silent-failure hardening across auth and client paths.

## [0.4.0] - 2026-03-24

### Breaking Changes
- All error returns now use `%PubsubGrpc.Error{}` struct instead of raw `%GRPC.RPCError{}`
  - Pattern match on `error.code` atoms: `:not_found`, `:already_exists`, `:unauthenticated`, etc.
  - Original gRPC error preserved in `error.details` for migration
- `PubsubGrpc.Auth.request_opts/0` now returns `{:ok, opts}` | `{:error, %Error{}}` instead of bare list
- Removed deprecated 2-arity `Client.execute/2` (use 1-arity operation functions)
- Schema type/view enum helpers now return errors for invalid values instead of silently defaulting
- Input validation added to all public functions — invalid inputs return `{:error, %Error{code: :validation_error}}`

### Added
- **`PubsubGrpc.Error`** — structured error type with code, message, details, and gRPC status
- **PubsubGrpc.Validation** — input validation for all parameters (project IDs, topic IDs, messages, ack IDs, deadlines, etc.)
- **New API functions:**
  - `get_topic/2` — get topic details
  - `get_subscription/2` — get subscription details
  - `list_subscriptions/2` — list subscriptions in a project
  - `modify_ack_deadline/4` — modify ack deadline for messages
  - `nack/3` — negatively acknowledge messages (immediate redelivery)
  - `validate_message/4` — validate message against existing schema
  - `validate_message_with_schema/5` — validate message against inline schema definition
- **Auth token caching** — ETS-based cache with TTL, avoids re-fetching on every request
- **Per-request timeouts** — configurable via `:default_timeout` app env (default: 30s)
- **Logging** — Logger warnings/errors for auth failures, config fallbacks
- Typespecs on all public functions
- Unit tests for Error, Validation, and Auth modules
- Validation integration tests (no emulator needed)
- Integration tests for all new API functions

### Fixed
- Silent authentication failures now log warnings and return proper error tuples
- Empty message list no longer silently sent to server (validated)
- Empty ack_ids list no longer silently sent to server (validated)
- Application config fallback now logs warning instead of failing silently
- Dead code removed from Client module (2-arity execute with unused pool logic)

### Migration Guide
```elixir
# Before (v0.3.x)
case PubsubGrpc.create_topic("proj", "topic") do
  {:ok, topic} -> topic
  {:error, %GRPC.RPCError{status: 6}} -> "exists"
end

# After (v0.4.0)
case PubsubGrpc.create_topic("proj", "topic") do
  {:ok, topic} -> topic
  {:error, %PubsubGrpc.Error{code: :already_exists}} -> "exists"
  {:error, %PubsubGrpc.Error{code: :validation_error} = err} -> "invalid: #{err}"
end

# Auth.request_opts/0 now returns {:ok, opts}
{:ok, opts} = PubsubGrpc.Auth.request_opts()
# or in emulator mode: {:ok, []}
```

## [0.3.1] - 2025-11-21

### Fixed
- **Critical fix**: Resolved `FunctionClauseError` during GRPC connection termination in `grpc_connection_pool` worker
  - Modified worker cleanup logic to handle Gun-based connections safely
  - Bypasses problematic pattern matching in GRPC v0.11.5's disconnect handling
  - Prevents GenServer crashes with error: `no function clause matching in anonymous fn/1 in GRPC.Client.Connection.handle_call/3`
- Improved connection pool stability during shutdown and restart cycles

### Added
- Comprehensive tests for disconnect behavior and connection pool lifecycle
- Integration tests verifying graceful pool shutdown without errors

## [0.3.0] - 2025-01-21

### Changed
- **BREAKING**: Updated `grpc_connection_pool` dependency from 0.1.3 to 0.1.5
  - New architecture uses DynamicSupervisor with Registry-based health tracking
  - Round-robin channel distribution without checkout/checkin overhead
  - Improved connection reliability with exponential backoff and jitter
- Upgraded `grpc` library from 0.10.2 to 0.11.5
- Added `GRPC.Client.Supervisor` to application supervision tree (required by grpc 0.11.5)

### Internal
- Updated `PubsubGrpc.Client.execute/2` to use new `GrpcConnectionPool.get_channel/1` API
- Improved test initialization sequence to ensure emulator is ready before pool connections
- Updated tests to work with new pool architecture

### Migration Notes
- **No changes required to public API** - all existing code continues to work
- Pool process name changed from `PubsubGrpc.ConnectionPool` to `PubsubGrpc.ConnectionPool.Supervisor`
- Connection establishment is now asynchronous with automatic retry on failure

## [0.2.5] - 2025-01-XX

Previous release with grpc_connection_pool 0.1.3
