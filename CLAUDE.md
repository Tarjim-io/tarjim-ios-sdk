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
- `Tests/TarjimTests`: tests; `Tests/TarjimTests/Fixtures` holds hand-built server answers and, under
  `recorded/<name>/`, recordings (see the README there).
- `scripts`: capture and test-report tooling.

Planned components:

- `DeliveryClient`: requests, both delivery modes.
- `Verifier`: sha256 checks.
- `Store`: the only code that writes files; immutable install directories.
- `Scheduler`: when to check for updates; foreground only.
- `LocaleSelector`: picks the locale to serve.
- `Resolver`: lookup chain over an immutable snapshot.
- `Reporter`: local reports only; no network.

## Rules

- This repository is public. Never commit an API key, a signature, a real hostname (use `*.invalid`,
  `example.com` and its subdomains), a staging or production URL, an internal ticket id, or a reference
  to private planning documents. Describe what the code does, not how it was decided.
- Tests first. A test must be seen failing for the right reason before the code that satisfies it.
- Fixtures are recorded or hand-built and never edited after recording; editing breaks the hashes. If the
  leak scan flags a recording, re-capture it from another project.
- Commit messages are one line, at most 50 characters, `type(scope): description`, with no trailers.
- Never set `Accept-Encoding`; let the URL loading system negotiate and decode.
- The API key only travels in the `X-Tarjim-Apikey` header and never reaches a log line or a report.
- All logging goes through one call site, at `debug` level.
