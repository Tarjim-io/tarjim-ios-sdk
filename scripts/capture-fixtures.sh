#!/usr/bin/env bash
#/ DESCRIPTION:
#/   Records a project's current release from the delivery routes into the layout the fixture
#/   tests read (see Tests/TarjimTests/Fixtures/README.md): meta.<mode>.json, manifest.json, every
#/   object, and the answer to a request made with an invalid key. Every hash is verified against
#/   the manifest, and the manifest against meta, before anything is written.
#/   The API key is read from the environment variable TARJIM_APIKEY only; it is never printed,
#/   written to disk or passed on a command line.
#/
#/ USAGE:
#/   TARJIM_APIKEY=... capture-fixtures.sh --host <url> --project <id> --out <dir> [--api-version <v>] [--app-version <v>] [--help]
#/
#/ SYNOPSIS:
#/   --host: API base URL: https://<host>[:port][/path], or http://localhost|127.0.0.1[:port][/path]
#/   --project: numeric project id
#/   --out: recording directory to create; must not exist
#/   --api-version: value for X-Tarjim-Api-Version (default: 2026-07-29)
#/   --app-version: value for X-Tarjim-App-Version on meta requests, MAJOR.MINOR.PATCH (default: 0.0.0)
#/   --help: Prints this message
#/
#/ Afterwards move the directory to Tests/TarjimTests/Fixtures/recorded/<name>/ and run
#/ `swift test --parallel`: its leak scan must pass before the recording is committed, and a
#/ recording it flags is captured again from another project, never edited.

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
app_version="0.0.0"

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
    --app-version)
      app_version="${2:?--app-version requires a value}"
      shift 2
      ;;
    --app-version=*)
      app_version="${1#*=}"
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
# No userinfo, query or fragment: the key must go to the host the operator typed.
host_re='^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*$'
local_re='^http://(localhost|127\.0\.0\.1)(:[0-9]+)?(/[A-Za-z0-9._~-]+)*$'
if [[ ! "$host" =~ $host_re && ! "$host" =~ $local_re ]]; then
  fail "--host must be https://<host>[:port][/path] (http only for localhost and 127.0.0.1)"
fi

if [[ ! "$project" =~ ^[0-9]+$ ]]; then
  fail "--project must be a number"
fi

if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "--app-version must be MAJOR.MINOR.PATCH"
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

# curl reads headers and URLs from files (-H @file, -K file) so neither the key nor a signed query
# appears in argv, where `ps` shows it.
umask 077
key_headers="$work/key.hdr"
meta_headers="$work/meta-req.hdr"
bad_key_headers="$work/badkey.hdr"
bad_key_meta_headers="$work/badkey-meta.hdr"
printf 'X-Tarjim-Apikey: %s\nX-Tarjim-Api-Version: %s\n' "$TARJIM_APIKEY" "$api_version" >"$key_headers"
printf 'X-Tarjim-Apikey: tarjim-0-0-0-invalid\nX-Tarjim-Api-Version: %s\n' "$api_version" >"$bad_key_headers"
# The server rejects a meta request without it; the SDK sends it on meta only, so the other requests don't.
app_header="$(printf 'X-Tarjim-App-Version: %s' "$app_version")"
{ cat "$key_headers"; echo "$app_header"; } >"$meta_headers"
{ cat "$bad_key_headers"; echo "$app_header"; } >"$bad_key_meta_headers"
umask 022

stage="$work/stage"
mkdir -p "$stage/objects" "$stage/errors"
recorded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

url_re='^[A-Za-z0-9._~:/?&=%+,-]+$'

# fetch <url> <body-file> <headers-dump-file> [header-file]  -> prints the HTTP status
fetch() {
  local url="$1" body="$2" dump="$3" hdr="${4:-}"
  [[ "$url" =~ $url_re ]] || fail "refusing a URL with unexpected characters"
  local cfg
  cfg="$(mktemp "$work/curl.XXXXXX")"
  printf 'url = "%s"\n' "$url" >"$cfg"
  # -q first: a ~/.curlrc must not add options. No redirects are followed, so the key stays on one host.
  local args=(-q -sS --compressed --max-time 60 -D "$dump" -o "$body" -w '%{http_code}' -K "$cfg")
  if [[ -n "$hdr" ]]; then
    args+=(-H "@$hdr")
  fi
  curl "${args[@]}"
}

# Content-Encoding is not kept: bodies are stored decoded.
keep_headers='["Content-Type","Cache-Control","ETag","Retry-After","X-Tarjim-Api-Version"]'

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

status="$(fetch "$meta_url" "$work/meta.body" "$work/meta.hdr" "$meta_headers")"
if [[ "$status" != "200" ]]; then
  fail "meta answered $status, expected 200"
fi

# A failing jq aborts the run: command substitution in an assignment propagates its status.
checksum="$(jq -er '.checksum | strings' <"$work/meta.body")"
authenticated="$(jq -er '.authenticated | booleans | tostring' <"$work/meta.body")"
manifest_ref="$(jq -er '.manifestUrl | strings' <"$work/meta.body")"
slices_ref="$(jq -er '.slicesBaseUrl | strings' <"$work/meta.body")"

if [[ "$authenticated" == "true" ]]; then
  mode="origin"
  asset_headers="$key_headers"
  # Origin URLs are path-relative; anything else could send the key to another host.
  for ref in "$manifest_ref" "$slices_ref"; do
    if [[ "$ref" == *://* || "$ref" == /* || "$ref" == *..* ]]; then
      fail "origin-mode meta carries a URL that is not path-relative"
    fi
  done
  manifest_url="${meta_url%/*}/$manifest_ref"
  slices_url="${meta_url%/*}/$slices_ref"
  signed_query=""
else
  mode="cdn"
  asset_headers=""
  for ref in "$manifest_ref" "$slices_ref"; do
    if [[ "$ref" != https://* ]]; then
      fail "CDN-mode meta carries a URL that is not https"
    fi
  done
  signed_query="$(jq -er '.signedQuery | strings' <"$work/meta.body")"
  manifest_url="$manifest_ref?$signed_query"
  slices_url="$slices_ref"
fi

status="$(fetch "$manifest_url" "$stage/manifest.json" "$work/manifest.hdr" "$asset_headers")"
if [[ "$status" != "200" ]]; then
  fail "manifest answered $status, expected 200"
fi
if [[ "$(sha256 "$stage/manifest.json")" != "$checksum" ]]; then
  fail "manifest sha256 does not match meta.checksum"
fi

objects="$(jq -er '[.slices[] | .[] | to_entries[] | "\(.value.hash) \(.key)"] | unique | .[]' <"$stage/manifest.json")" || fail "the manifest is not valid or lists no objects"

object_count=0
while read -r hash file_type; do
  if [[ ! "$hash" =~ ^[0-9a-f]{64}$ || ! "$file_type" =~ ^[a-z]+$ ]]; then
    fail "the manifest lists a malformed object: $hash $file_type"
  fi
  object="$hash.$file_type"
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
done <<<"$objects"

# meta: drop the real host and the live signature before it is written.
jq -ec '
  def redact_host: if test("^[A-Za-z][A-Za-z0-9+.-]*://") then sub("^(?<s>[A-Za-z][A-Za-z0-9+.-]*://)[^/]+"; "\(.s)cdn.example.invalid") else . end;
  .manifestUrl |= redact_host
  | .slicesBaseUrl |= redact_host
  | if has("signedQuery") then .signedQuery = "Policy=REDACTED&Signature=REDACTED&Key-Pair-Id=REDACTED" else . end
' <"$work/meta.body" | tr -d '\n' >"$work/meta.redacted"
write_envelope 200 "$work/meta.hdr" "$work/meta.redacted" "$stage/meta.$mode.json"

status="$(fetch "$meta_url" "$work/e401.body" "$work/e401.hdr" "$bad_key_meta_headers")"
if [[ "$status" != "401" ]]; then
  fail "meta with an invalid key answered $status, expected 401"
fi
write_envelope 401 "$work/e401.hdr" "$work/e401.body" "$stage/errors/meta-401-unauthorized.json"

mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
chmod 755 "$out"

echo "Recorded $mode-mode release for project $project into $out:"
echo "  meta.$mode.json, manifest.json, $object_count objects, errors/meta-401-unauthorized.json"
echo "Move it to Tests/TarjimTests/Fixtures/recorded/<name>/ and run 'swift test --parallel' (the leak scan) before committing. Nothing was staged in git."
