#!/usr/bin/env bash
#/ DESCRIPTION:
#/   Records a project's current release from the delivery routes into the fixture layout the tests
#/   read (Tests/TarjimTests/Fixtures/release-1): meta, manifest, every object, and two error
#/   answers (a request without the version header, and one with an invalid key). Every hash is
#/   verified against the manifest and the manifest against meta before anything is written.
#/   The API key is read from the environment variable TARJIM_APIKEY only; it is never printed,
#/   written to disk or passed on a command line.
#/
#/ USAGE:
#/   TARJIM_APIKEY=... capture-fixtures.sh --host <url> --project <id> --out <dir> [--api-version <v>] [--help]
#/
#/ SYNOPSIS:
#/   --host: API base URL; https only, except http for localhost and 127.0.0.1
#/   --project: numeric project id
#/   --out: directory to create; must not exist
#/   --api-version: value for X-Tarjim-Api-Version (default: 2026-07-29)
#/   --help: Prints this message
#/
#/ Run the test suite before committing the result: its leak scan must pass, and a recording it
#/ flags is captured again from another project, never edited.

set -euo pipefail
# shellcheck disable=SC2154 # ec is assigned inside the trap string
trap 'ec=$?; echo "[ERROR] $BASH_SOURCE:$LINENO: \"$BASH_COMMAND\" exited with $ec" >&2' ERR

usage() {
  grep '^#/' <"$0" | cut -c 4-
  exit 2
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] missing: $1" >&2
    exit 127
  fi
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

need curl
need jq

host=""
project=""
out=""
api_version="2026-07-29"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      host="${2:?--host requires a value}"
      shift 2
      ;;
    --host=*)
      host="${1#*=}"
      shift
      ;;
    --project)
      project="${2:?--project requires a value}"
      shift 2
      ;;
    --project=*)
      project="${1#*=}"
      shift
      ;;
    --out)
      out="${2:?--out requires a value}"
      shift 2
      ;;
    --out=*)
      out="${1#*=}"
      shift
      ;;
    --api-version)
      api_version="${2:?--api-version requires a value}"
      shift 2
      ;;
    --api-version=*)
      api_version="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$host" || -z "$project" || -z "$out" ]]; then
  echo "[ERROR] --host, --project and --out are required" >&2
  usage
fi

if [[ -z "${TARJIM_APIKEY:-}" ]]; then
  fail "TARJIM_APIKEY is not set"
fi

host="${host%/}"
case "$host" in
  https://*)
    ;;
  http://localhost|http://localhost:*|http://localhost/*|http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*)
    ;;
  *)
    fail "--host must be https (http is allowed only for localhost and 127.0.0.1)"
    ;;
esac

if [[ ! "$project" =~ ^[0-9]+$ ]]; then
  fail "--project must be a number"
fi

if [[ -e "$out" ]]; then
  fail "$out already exists; recordings are never overwritten"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
else
  need shasum
  sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
fi

# Everything is staged here and moved to --out only after every check has passed.
work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

# curl reads headers from a file (-H @file) so the key never appears in argv, where `ps` shows it.
umask 077
key_headers="$work/key.hdr"
bad_key_headers="$work/badkey.hdr"
printf 'X-Tarjim-Apikey: %s\nX-Tarjim-Api-Version: %s\n' "$TARJIM_APIKEY" "$api_version" >"$key_headers"
printf 'X-Tarjim-Apikey: tarjim-0-0-0-invalid\nX-Tarjim-Api-Version: %s\n' "$api_version" >"$bad_key_headers"
printf 'X-Tarjim-Apikey: %s\n' "$TARJIM_APIKEY" >"$work/key-only.hdr"
umask 022

stage="$work/stage"
mkdir -p "$stage/objects" "$stage/errors"
recorded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# fetch <url> <body-file> <headers-dump-file> [header-file]  -> prints the HTTP status
fetch() {
  local url="$1" body="$2" dump="$3" hdr="${4:-}"
  local args=(-sS --compressed --max-time 60 -D "$dump" -o "$body" -w '%{http_code}')
  if [[ -n "$hdr" ]]; then
    args+=(-H "@$hdr")
  fi
  curl "${args[@]}" "$url"
}

resolve() {
  local base="$1" ref="$2"
  case "$ref" in
    *://*)
      echo "$ref"
      ;;
    *)
      echo "${base%/*}/$ref"
      ;;
  esac
}

keep_headers='["Content-Type","Content-Encoding","Cache-Control","ETag","Retry-After","X-Tarjim-Api-Version"]'

# write_envelope <status> <headers-dump> <body-file> <dest>
write_envelope() {
  local status="$1" dump="$2" body="$3" dest="$4"
  local headers
  headers="$(jq -Rs --argjson keep "$keep_headers" '
    split("\n")
    | map(rtrimstr("\r") | select(test("^[A-Za-z0-9-]+:")))
    | map(capture("^(?<k>[^:]+):[ \t]*(?<v>.*)$"))
    | map(. as $h | ($keep[] | select(ascii_downcase == ($h.k | ascii_downcase))) as $name | {key: $name, value: $h.v})
    | from_entries' <"$dump")"
  jq -n --arg at "$recorded_at" --argjson status "$status" --argjson headers "$headers" --rawfile body "$body" \
    '{provenance: "recorded", recordedAt: $at, status: $status, headers: $headers, body: $body}' >"$dest"
}

meta_url="$host/projects/$project/delivery/meta"

status="$(fetch "$meta_url" "$work/meta.body" "$work/meta.hdr" "$key_headers")"
if [[ "$status" != "200" ]]; then
  fail "meta answered $status, expected 200"
fi

checksum="$(jq -r '.checksum' <"$work/meta.body")"
authenticated="$(jq -r '.authenticated' <"$work/meta.body")"
manifest_ref="$(jq -r '.manifestUrl' <"$work/meta.body")"
slices_ref="$(jq -r '.slicesBaseUrl' <"$work/meta.body")"

manifest_url="$(resolve "$meta_url" "$manifest_ref")"
slices_url="$(resolve "$meta_url" "$slices_ref")"

if [[ "$authenticated" == "true" ]]; then
  mode="origin"
  asset_headers="$key_headers"
else
  mode="cdn"
  asset_headers=""
  signed_query="$(jq -r '.signedQuery' <"$work/meta.body")"
  manifest_url="$manifest_url?$signed_query"
fi

status="$(fetch "$manifest_url" "$stage/manifest.json" "$work/manifest.hdr" "$asset_headers")"
if [[ "$status" != "200" ]]; then
  fail "manifest answered $status, expected 200"
fi
if [[ "$(sha256 "$stage/manifest.json")" != "$checksum" ]]; then
  fail "manifest sha256 does not match meta.checksum"
fi

object_count=0
while read -r hash file_type; do
  object="$hash.$file_type"
  if [[ -e "$stage/objects/$object" ]]; then
    continue
  fi
  url="$slices_url$object"
  if [[ "$mode" == "cdn" ]]; then
    url="$url?$signed_query"
  fi
  status="$(fetch "$url" "$stage/objects/$object" "$work/object.hdr" "$asset_headers")"
  if [[ "$status" != "200" ]]; then
    fail "object $object answered $status, expected 200"
  fi
  if [[ "$(sha256 "$stage/objects/$object")" != "$hash" ]]; then
    fail "object $object does not match its manifest hash"
  fi
  object_count=$((object_count + 1))
done < <(jq -r '[.slices[][] | to_entries[] | "\(.value.hash) \(.key)"] | unique | .[]' <"$stage/manifest.json")

# meta: drop the real host and the live signature before it is written.
jq -c '
  def redact_host: if test("^[A-Za-z][A-Za-z0-9+.-]*://") then sub("^(?<s>[A-Za-z][A-Za-z0-9+.-]*://)[^/]+"; "\(.s)cdn.example.invalid") else . end;
  .manifestUrl |= redact_host
  | .slicesBaseUrl |= redact_host
  | if has("signedQuery") then .signedQuery = "Policy=REDACTED&Signature=REDACTED&Key-Pair-Id=REDACTED" else . end
' <"$work/meta.body" | tr -d '\n' >"$work/meta.redacted"
write_envelope 200 "$work/meta.hdr" "$work/meta.redacted" "$stage/meta.$mode.json"

# Error answers: the same route without the version header, and with a key that cannot exist.
status="$(fetch "$meta_url" "$work/e400.body" "$work/e400.hdr" "$work/key-only.hdr")"
if [[ "$status" != "400" ]]; then
  fail "meta without the version header answered $status, expected 400"
fi
write_envelope 400 "$work/e400.hdr" "$work/e400.body" "$stage/errors/meta-400-validation.json"

status="$(fetch "$meta_url" "$work/e401.body" "$work/e401.hdr" "$bad_key_headers")"
if [[ "$status" != "401" ]]; then
  fail "meta with an invalid key answered $status, expected 401"
fi
write_envelope 401 "$work/e401.hdr" "$work/e401.body" "$stage/errors/meta-401-unauthorized.json"

mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
chmod 755 "$out"

echo "Recorded $mode-mode release for project $project into $out:"
echo "  meta.$mode.json, manifest.json, $object_count objects, errors/meta-400-validation.json, errors/meta-401-unauthorized.json"
echo "Run 'swift test --parallel' (the leak scan) before committing. Nothing was staged in git."
