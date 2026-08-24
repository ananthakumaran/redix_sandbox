# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-08-24

### Added

- Process-scoped Redis connections for concurrent ExUnit tests.
- Explicit process allowances for detached workers.
- Private and shared ownership modes.
- Structured errors for checkout, allowance, mode, and connection failures.
