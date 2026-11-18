#!/usr/bin/env bash
# CI check for lib/secret-gen.sh under the same shell options as production-secrets.sh (#781 review B1).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/secret-gen.sh
. "$here/lib/secret-gen.sh"

for n in 40 64; do
  for _ in 1 2 3 4 5; do
    v=$(alnum "$n")
    [ "${#v}" -eq "$n" ] || { echo "alnum $n gave ${#v} characters" >&2; exit 1; }
    case "$v" in *[!A-Za-z0-9]*) echo "alnum $n gave a non-alphanumeric character" >&2; exit 1 ;; esac
  done
done
[ "$(alnum 64)" != "$(alnum 64)" ] || { echo "alnum repeated a value" >&2; exit 1; }

k=$(key32)
[ "$(printf '%s' "$k" | base64 -d | wc -c)" -eq 32 ] || { echo "key32 is not 32 bytes" >&2; exit 1; }

t=$(mktemp); printf 'x' >"$t"
[ "$(fingerprint "$t")" = "2d711642b726" ] || { echo "fingerprint wrong" >&2; exit 1; }
rm -f "$t"
echo "secret generators: ok"
