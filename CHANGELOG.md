# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-07-26

### Changed
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
- **`PubsubGrpc.Validation`** — input validation for all parameters (project IDs, topic IDs, messages, ack IDs, deadlines, etc.)
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
