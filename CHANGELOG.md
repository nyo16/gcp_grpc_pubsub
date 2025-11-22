# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
