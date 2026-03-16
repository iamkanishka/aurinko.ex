# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2024-06-01

### Added

- Initial release
- `Aurinko.Auth` — OAuth authorization URL builder, code exchange, and token refresh
- `Aurinko.API.Email` — List, get, send, draft, update messages; delta sync; attachments; email tracking
- `Aurinko.API.Calendar` — List/get calendars and events; create/update/delete events; delta sync; free/busy
- `Aurinko.API.Contacts` — CRUD contacts; delta sync
- `Aurinko.API.Tasks` — Task list and task management (list, create, update, delete)
- `Aurinko.API.Webhooks` — Subscription management (list, create, delete)
- `Aurinko.API.Booking` — Booking profile listing and availability
- `Aurinko.Types` — Typed structs for Email, CalendarEvent, Calendar, Contact, Task, Pagination, SyncResult
- `Aurinko.Error` — Structured, tagged error type with HTTP status mapping
- `Aurinko.HTTP.Client` — Req-based HTTP client with retry, backoff, and connection pooling
- `Aurinko.Telemetry` — `:telemetry` events for all HTTP requests
- `Aurinko.Config` — NimbleOptions-validated configuration
- Full typespecs and `@moduledoc`/`@doc` coverage
- GitHub Actions CI with matrix testing (Elixir 1.16/1.17, OTP 26/27)
- Credo strict linting and Dialyzer integration
