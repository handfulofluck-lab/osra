# Secret generators for production-secrets.sh, kept apart so CI can run them (tests/secret-gen.sh) without
# touching AWS. Each reads a FIXED number of random bytes, so no pipe is cut short: `tr </dev/urandom | head`
# dies of SIGPIPE, and under `set -o pipefail` that ends the calling script (#781 review B1).

# alnum <n>: n characters from [A-Za-z0-9].
alnum() {
  local want=$1 out=""
  while [ "${#out}" -lt "$want" ]; do
    out+=$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${out:0:$want}"
}

# key32: base64 of 32 random bytes (packages/crypto generateFamilyKey's format).
key32() {
  head -c 32 /dev/urandom | base64 | tr -d '\n'
}

# fingerprint <file>: first 12 hex characters of SHA-256, for evidence that two values differ without
# revealing either.
fingerprint() {
  sha256sum "$1" | cut -c1-12
}
