# Fixtures

Server answers the tests replay. Nothing here is fetched at test time.

- `release-1/` holds one complete release: `meta.cdn.json` and `meta.origin.json` (the two delivery
  modes), `manifest.json` (the raw manifest bytes) and `objects/<sha256>.<fileType>` (every object the
  manifest lists, as decoded bytes).
- `errors/` holds the answers the SDK has to handle, one envelope per file.
- `recorded/<name>/` holds a recording made by `scripts/capture-fixtures.sh`: the layout of `release-1/`
  for one delivery mode, plus its own `errors/`.
- `golden/` holds the server writer's own corpus files for `.strings` and `.stringsdict`, verbatim.
- `proxy-ui/` holds a storyboard and a xib with their compiled forms, for the main-bundle proxy's UIKit tests;
  `scripts/compile-proxy-ui-fixtures.sh` regenerates the compiled files from the sources beside them.

An envelope is `{provenance, status, headers, body}`; `body` is the response body as a string, or null.

## Provenance

`release-1` and `errors` are HAND-BUILT from the server's renderer output and documented response
shapes. The `.strings` and `.stringsdict` objects are renderer output; the `json` objects are
hand-built (the SDK never fetches them). `release-1/` and `errors/` stay as the
hand-built contract shape; recordings are added beside them under `recorded/`, made with
`scripts/capture-fixtures.sh`.

Bodies are stored decoded, so object hashes are those of the decoded bytes and no `Content-Encoding`
header is kept.

## Before committing a recording

Run `testNoFixtureCarriesAKeyASignatureOrARealHost`. If it flags a recording, capture again from another
project; never edit the recording, because any edit breaks the hashes.
