# Tarjim iOS SDK

The runtime half of the Tarjim iOS SDK. It downloads a project's released translation files, verifies
them, installs them atomically and answers string lookups. Swift Package, source only, iOS 15+,
a Swift 6.0+ toolchain (Xcode 16+) and Swift 6 language mode. MIT licensed. Versions stay `0.x` until the first public release.

## Commands

- Build: `swift build`
- Test: `swift test --parallel`
- Warnings as errors, as CI runs it: `swift build --build-tests -Xswiftc -warnings-as-errors`
- Simulator: `xcodebuild test -scheme Tarjim -destination "id=<simulator udid>"`
- Test-report gate: `swift test --parallel --xunit-output <file>.xml`, then
  `scripts/verify-test-report.py --report <file>.xml ...` (see its docstring). `--parallel` is required,
  otherwise XCTest writes no report.
- Record fixtures from a live server: `scripts/capture-fixtures.sh --help`.

## Layout

- `Sources/Tarjim`: the SDK.
  - `Delivery/` is the network layer: `DeliveryClient` (meta, manifest and object requests, both delivery modes,
    every answer a typed outcome), `Verifier` (SHA-256), `URLSessionTransport` (one ephemeral session, no cache, no
    cookies, redirects refused).
  - `Store/` is the only code that writes files: one store per (host, project, key) under Application Support,
    verified objects staged by hash, immutable install directories, `state.json` replaced atomically, cleanup of
    whatever nothing names. The SDK keeps exactly one `Store` per root.
  - `Lookup/` picks the locales to serve (Apple's matcher plus a same-language, same-script check) and answers
    lookups from one immutable snapshot: downloaded text, then the app's own text, then the key. Nothing in a lookup
    touches the file system; each string is formatted with the locale it was found in.
- `Tests/TarjimTests`: tests; `Tests/TarjimTests/Fixtures` holds hand-built server answers and, under
  `recorded/<name>/`, recordings (see the README there).
- `scripts`: capture and test-report tooling.

Planned components (not built yet):

- `Scheduler`: when to check for updates; foreground only.
- `Reporter`: local reports only; no network.

## Rules

- This repository is public. Never commit an API key, a signature, a real hostname (use `*.invalid`,
  `example.com` and its subdomains), a staging or production URL, an internal ticket id, or a reference
  to private planning documents. Describe what the code does, not how it was decided.
- Tests first. A test must be seen failing for the right reason before the code that satisfies it.
- Fixtures are recorded or hand-built and never edited after recording; editing breaks the hashes. If the
  leak scan flags a recording, re-capture it from another project.
- A commit message is a single line — no body, no trailers such as `Co-Authored-By` — at most
  50 characters, `type(scope): description`.
- Pull requests follow `.claude/skills/pr/SKILL.md`; `.github/PULL_REQUEST_TEMPLATE.md` mirrors it.
- Never set `Accept-Encoding`; let the URL loading system negotiate and decode.
- The API key only travels in the `X-Tarjim-Apikey` header and never reaches a log line or a report.
- All logging goes through one call site, at `debug` level.
