# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-11-11

### Added

- Configurable checkout timeout via `checkout(name, timeout: milliseconds | :infinity)`,
  applying to pool calls and `FLUSHDB` while preserving existing defaults when omitted.

### Fixed

- Run checkout's `FLUSHDB` in the calling process so slow flushes no longer block
  other checkouts or connection lookups in the pool.
- Release the reserved database and ownership when a checkout flush fails.

## [0.1.0] - 2026-08-24

### Added

- Process-scoped Redis connections for concurrent ExUnit tests.
- Explicit process allowances for detached workers.
- Private and shared ownership modes.
- Structured errors for checkout, allowance, mode, and connection failures.
