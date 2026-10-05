#!/usr/bin/env bash
#/ DESCRIPTION:
#/   Compiles the interface files the proxy's UIKit tests load:
#/   Tests/TarjimTests/Fixtures/proxy-ui/Base.lproj/Main.storyboard -> Main.storyboardc and Card.xib -> Card.nib,
#/   beside their sources. They are compiled from Base.lproj on purpose: only then does ibtool mark each
#/   label's text as localizable (key `<objectID>.text`, table = the file's name); compiled anywhere else,
#/   UIKit applies no strings table at all.
#/
#/ USAGE:
#/   compile-proxy-ui-fixtures.sh [--help]
#/
#/ SYNOPSIS:
#/   --help: Prints this message

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

need xcrun

base="$(cd "$(dirname "$0")/.." && pwd)/Tests/TarjimTests/Fixtures/proxy-ui/Base.lproj"

compile() {
  local source="$1"
  local output="$2"
  rm -rf "${base:?}/$output"
  xcrun ibtool --compile "$base/$output" "$base/$source" \
    --target-device iphone --minimum-deployment-target 15.0 --errors --warnings --output-format human-readable-text
}

compile Main.storyboard Main.storyboardc
compile Card.xib Card.nib
