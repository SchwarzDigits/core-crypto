#!/usr/bin/env bash
# Fails if a shared library needs a newer glibc than the given version.
#
#   scripts/check-max-glibc.sh <library> <version>
set -euo pipefail

library="$1"
max="$2"
versions="$(objdump -T "$library" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' || true)"
if [ -z "$versions" ]; then
  echo "$library has no GLIBC symbol versions; is it a shared library linked against glibc?" >&2
  exit 1
fi
needed="$(printf '%s\n' "${versions//GLIBC_/}" | sort -uV | tail -n 1)"
if [ "$(printf '%s\n%s\n' "$needed" "$max" | sort -V | tail -n 1)" != "$max" ]; then
  echo "$library needs glibc $needed, more than $max" >&2
  exit 1
fi
echo "$library needs glibc $needed at most"
