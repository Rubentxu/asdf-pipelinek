#!/usr/bin/env bash
# Offline contract tests for the asdf-pipelinek plugin.
#
# No network: upstream responses are served from recorded fixtures through a
# curl stub on PATH. Every test asserts a behaviour that previously failed in
# production, so a regression here is a regression for users.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Exported: the curl stub is a separate process and reads these from the env.
export FIXTURES="${REPO_ROOT}/test/fixtures"
PASS=0
FAIL=0
FAILED_NAMES=()

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  red "  FAIL $1"
  shift
  [ "$#" -gt 0 ] && printf '       %s\n' "$@"
  return 0
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$name"
  else
    fail "$name" "expected: [$expected]" "actual:   [$actual]"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail "$name" "expected to contain: [$needle]" "actual: [$haystack]" ;;
  esac
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) fail "$name" "expected NOT to contain: [$needle]" "actual: [$haystack]" ;;
    *) ok "$name" ;;
  esac
}

assert_status() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$name"
  else
    fail "$name" "expected exit: $expected" "actual exit:   $actual"
  fi
}

section() { printf '\n%s\n' "$1"; }

# Build a sandbox that mirrors a release ZIP: one top-level dir holding bin/ and
# lib/. The dir name deliberately does NOT match the version, mirroring the real
# v0.43.0 artifact whose top dir is "pipelinek-0.43.0-rc1".
make_release_zip() {
  local out="$1" topdir="$2"
  local work
  work="$(mktemp -d)"
  mkdir -p "${work}/${topdir}/bin" "${work}/${topdir}/lib"
  cat > "${work}/${topdir}/bin/pipelinek" <<'LAUNCHER'
#!/bin/sh
# stand-in for the Gradle launcher: resolves APP_HOME as the parent of bin/
APP_HOME=$( cd -P "$(dirname "$0")/.." > /dev/null && printf '%s\n' "$PWD" )
if [ -d "$APP_HOME/lib" ]; then
  echo "pipelinek-ok lib=$(ls "$APP_HOME/lib" | tr '\n' ',')"
else
  echo "pipelinek-broken: no lib at $APP_HOME/lib" >&2
  exit 1
fi
LAUNCHER
  chmod +x "${work}/${topdir}/bin/pipelinek"
  echo "dummy-jar" > "${work}/${topdir}/lib/pipeline-application.jar"
  ( cd "$work" && zip -qr "$out" "$topdir" )
  rm -rf "$work"
}

# A curl stub that serves recorded fixtures, so tests never touch the network.
# Lookup order: $STUB_FIXTURES (per-test overrides) then $FIXTURES (committed).
make_curl_stub() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "${dir}/curl" <<STUB
#!/usr/bin/env bash
# Test double for curl. Serves recorded fixtures by URL basename; no network.
# Honours the real flags the plugin uses: -fsSL, --retry N, -o FILE, -H header.
out=""
url=""
prev=""
for a in "\$@"; do
  case "\$prev" in
    -o) out="\$a"; prev=""; continue ;;
  esac
  case "\$a" in
    -o) prev="-o"; continue ;;
    http*) url="\$a" ;;
  esac
  prev="\$a"
done

# Drop the query string, then map a bare path to its recorded file.
path="\${url%%\?*}"
name="\$(basename "\$path")"
[ -z "\$name" ] && name=releases

for base in "\${STUB_FIXTURES:-}" "\$FIXTURES"; do
  [ -z "\$base" ] && continue
  [ -d "\$base" ] || continue
  for cand in "\$name" "\$name.json" "\$name.txt"; do
    if [ -f "\$base/\$cand" ]; then
      if [ -n "\$out" ]; then cat "\$base/\$cand" > "\$out"; else cat "\$base/\$cand"; fi
      exit 0
    fi
  done
done

echo "curl(stub): no fixture for \$url" >&2
exit 22
STUB
  chmod +x "${dir}/curl"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../lib/common.bash
source "${REPO_ROOT}/lib/common.bash"

########################################################################
section "version helpers (lib/common.bash)"

assert_eq "latest stable ignores prereleases" \
  "0.43.0" \
  "$(printf '%s\n' '0.43.0-rc1 0.43.0 0.42.0-rc1 0.40.0 0.39.0 0.1.0' | pk_latest_stable)"

assert_eq "latest stable, newline separated" \
  "0.43.0" \
  "$(printf '%s\n' 0.43.0-rc1 0.43.0 0.40.0 | pk_latest_stable)"

assert_eq "no stable version yields empty output" \
  "" \
  "$(printf '%s\n' 0.43.0-rc1 0.42.0-rc2 | pk_latest_stable)"

assert_eq "sorts numerically, not lexically" \
  "0.1.0 0.2.0 0.10.0 0.39.0" \
  "$(printf '%s\n' 0.39.0 0.10.0 0.2.0 0.1.0 | pk_sort_versions | tr '\n' ' ' | sed 's/ $//')"

assert_eq "orders rc numerically (rc1<rc2<rc10)" \
  "0.40.0-rc1 0.40.0-rc2 0.40.0-rc10" \
  "$(printf '%s\n' 0.40.0-rc10 0.40.0-rc2 0.40.0-rc1 | pk_sort_versions | tr '\n' ' ' | sed 's/ $//')"

assert_eq "orders multi-digit patch numerically" \
  "0.43.9 0.43.10" \
  "$(printf '%s\n' 0.43.10 0.43.9 | pk_sort_versions | tr '\n' ' ' | sed 's/ $//')"

assert_eq "stable follows its own prereleases (SemVer precedence)" \
  "0.40.0-rc1 0.40.0" \
  "$(printf '%s\n' 0.40.0 0.40.0-rc1 | pk_sort_versions | tr '\n' ' ' | sed 's/ $//')"

assert_eq "alpha/beta are prereleases" "yes" \
  "$(pk_is_prerelease 1.0.0-beta1 && echo yes || echo no)"
assert_eq "plain version is not a prerelease" "yes" \
  "$(pk_is_prerelease 0.43.0 && echo no || echo yes)"
assert_eq "build metadata counts as unstable" "yes" \
  "$(pk_is_prerelease '0.43.0+build5' && echo yes || echo no)"

assert_eq "prefix filter keeps only matching lines" \
  "0.43.0 0.43.0-rc1" \
  "$(printf '%s' '0.43.0 0.43.0-rc1 0.42.0' | pk_filter_prefix 0.43 | tr '\n' ' ' | sed 's/ $//')"
# asdf matches a version query as a plain prefix ("list all nodejs 18" selects
# every 18.x), so 0.4 legitimately matches 0.432.0. The filter must not
# over-match on a NON-prefix version, which is what 9.9 checks.
assert_eq "prefix filter matches 0.4x family" \
  "0.4.0 0.432.0 0.43.0" \
  "$(printf '%s' '0.4.0 0.432.0 0.43.0' | pk_filter_prefix 0.4 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "prefix filter rejects a non-matching major" \
  "" \
  "$(printf '%s' '0.4.0 0.43.0' | pk_filter_prefix 9.9 | tr '\n' ' ' | sed 's/ *$//')"

# Sorting must terminate on any input, including equal fragments.
assert_eq "sorting equal versions terminates" \
  "0.43.0 0.43.0" \
  "$(printf '%s\n' 0.43.0 0.43.0 | pk_sort_versions | tr '\n' ' ' | sed 's/ $//')"

########################################################################
section "asset naming matches upstream reality"

# The real v0.43.0 release publishes an asset named exactly "SHA256SUMS".
assert_eq "digest manifest asset name" "SHA256SUMS" "$(pk_sums_asset)"
assert_eq "zip asset name" "pipelinek-0.43.0.zip" "$(pk_zip_asset 0.43.0)"
assert_eq "release URL shape" \
  "https://github.com/Rubentxu/pipeline-kotlin/releases/download/v0.43.0/SHA256SUMS" \
  "$(pk_release_url 0.43.0 SHA256SUMS)"

########################################################################
section "bin/download uses the real asset names (P0-1 regression)"

STUB_BIN="${WORK}/stubbin"
make_curl_stub "$STUB_BIN"

DL="${WORK}/dl"
mkdir -p "$DL"
make_release_zip "${DL}/pipelinek-0.43.0.zip" "pipelinek-0.43.0-rc1"
real_digest="$(sha256sum "${DL}/pipelinek-0.43.0.zip" | awk '{print $1}')"

# Per-test manifest overrides live in the sandbox, never in the repo.
SUMS="${WORK}/sums"
mkdir -p "$SUMS"
export STUB_FIXTURES="$SUMS"

# The ZIP is a real local artifact; copy it where the stub can serve it by name.
cp "${DL}/pipelinek-0.43.0.zip" "${SUMS}/"

printf '%s  pipelinek-0.43.0.zip\n' "$real_digest" > "${SUMS}/SHA256SUMS"
out="$(PATH="${STUB_BIN}:$PATH" ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "download succeeds with correct asset names" "0" "$?"
assert_contains "download reports verification" "SHA-256 verified" "$out"

# A digest that does not match must abort and leave nothing usable behind.
DL_BAD="${WORK}/dlbad"
mkdir -p "$DL_BAD"
cp "${DL}/pipelinek-0.43.0.zip" "${DL_BAD}/"
printf '%s  pipelinek-0.43.0.zip\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  > "${SUMS}/SHA256SUMS"

out="$(PATH="${STUB_BIN}:$PATH" ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL_BAD" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "download fails closed on digest mismatch" "1" "$?"
assert_contains "download explains the mismatch" "verification FAILED" "$out"

# A manifest with no entry for our artifact must also fail closed.
printf 'deadbeef  some-other-file.zip\n' > "${SUMS}/SHA256SUMS"
out="$(PATH="${STUB_BIN}:$PATH" ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL_BAD" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "download fails closed when manifest lacks the entry" "1" "$?"
assert_contains "download explains the missing entry" "does not contain an entry" "$out"

# A manifest naming the artifact with a binary-mode '*' marker must still verify.
printf '%s *pipelinek-0.43.0.zip\n' "$real_digest" > "${SUMS}/SHA256SUMS"
printf '%s  pipelinek-0.43.0.zip\n' "$real_digest" > "${SUMS}/SHA256SUMS.good"
out="$(PATH="${STUB_BIN}:$PATH" ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL_BAD" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "sha256sum binary-mode manifest is tolerated" "0" "$?"

########################################################################
section "bin/install handles a mismatched top-level dir (P0-2 regression)"

INSTALL="${WORK}/install"
mkdir -p "$INSTALL"
out="$(ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL" ASDF_INSTALL_PATH="$INSTALL" \
  "${REPO_ROOT}/bin/install" 2>&1)"
assert_status "install succeeds despite mismatched dir name" "0" "$?"

if [ -x "${INSTALL}/bin/pipelinek" ]; then
  ok "launcher is at \$ASDF_INSTALL_PATH/bin/pipelinek"
else
  fail "launcher is at \$ASDF_INSTALL_PATH/bin/pipelinek" \
    "tree: $(find "$INSTALL" -maxdepth 2 | tr '\n' ' ')"
fi

if [ -d "${INSTALL}/lib" ]; then
  ok "lib/ is hoisted next to bin/"
else
  fail "lib/ is hoisted next to bin/" "tree: $(find "$INSTALL" -maxdepth 2 | tr '\n' ' ')"
fi

leftover="$(find "$INSTALL" -mindepth 1 -maxdepth 1 -type d -name 'pipelinek-*' | wc -l)"
assert_eq "no nested leftover version dir" "0" "$leftover"

# The launcher resolves lib/ relative to its own parent, so the flattened tree
# must actually run.
out="$("${INSTALL}/bin/pipelinek" 2>&1)"
assert_status "installed launcher executes" "0" "$?"
assert_contains "installed launcher finds lib/" "pipelinek-ok" "$out"

# list-bin-paths must now succeed and expose the right path.
out="$(ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_INSTALL_PATH="$INSTALL" "${REPO_ROOT}/bin/list-bin-paths" 2>&1)"
assert_status "list-bin-paths succeeds after install" "0" "$?"
assert_eq "list-bin-paths reports bin" "bin" "$(printf '%s' "$out" | tr -d '[:space:]')"

# Fail closed when the download step produced nothing.
out="$(ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="${WORK}/empty" ASDF_INSTALL_PATH="${WORK}/install-empty" \
  "${REPO_ROOT}/bin/install" 2>&1)"
assert_status "install fails closed without a verified download" "1" "$?"

########################################################################
section "latest-stable callback honours the asdf contract (P0-3 regression)"

if [ -x "${REPO_ROOT}/bin/latest-stable" ]; then
  ok "bin/latest-stable exists (the name asdf 0.19 invokes)"
else
  fail "bin/latest-stable exists (the name asdf 0.19 invokes)" \
    "asdf calls bin/latest-stable; bin/latest is never invoked"
fi

if [ -e "${REPO_ROOT}/bin/latest" ]; then
  fail "bin/latest is gone (it was dead code)" "remove the never-invoked callback"
else
  ok "bin/latest is gone (it was dead code)"
fi

VERSIONS="0.1.0 0.2.0 0.39.0 0.39.1-rc4 0.40.0 0.40.0-rc8 0.43.0 0.43.0-rc1"
assert_eq "latest stable from a mixed list" \
  "0.43.0" "$(printf '%s' "$VERSIONS" | pk_latest_stable)"
assert_eq "prefix query 0.40 returns latest stable 0.40.x" \
  "0.40.0" "$(printf '%s' "$VERSIONS" | pk_filter_prefix 0.40 | pk_latest_stable)"
assert_eq "prefix query 0.39 returns latest stable 0.39.x" \
  "0.39.0" "$(printf '%s' "$VERSIONS" | pk_filter_prefix 0.39 | pk_latest_stable)"

# The callback must work end to end against the recorded release fixture.
# An empty override dir means "no per-test overrides", so the committed
# releases.json fixture is still used.
export STUB_FIXTURES="$WORK/no-overrides"
mkdir -p "$STUB_FIXTURES"
assert_eq "latest-stable callback returns the newest stable" \
  "0.43.0" "$("${REPO_ROOT}/bin/latest-stable" 2>/dev/null)"
assert_eq "latest-stable honours a prefix query" \
  "0.40.0" "$("${REPO_ROOT}/bin/latest-stable" 0.40 2>/dev/null)"
assert_eq "latest-stable fails closed for an unknown query" "1" \
  "$("${REPO_ROOT}/bin/latest-stable" 9.99 >/dev/null 2>&1; echo $?)"

########################################################################
section "bin/list-all output contract"

out="$(PATH="${STUB_BIN}:$PATH" "${REPO_ROOT}/bin/list-all" 2>&1)"
status=$?
assert_status "list-all succeeds against fixture" "0" "$status"

# asdf requires ONE line, space separated, newest last.
lines="$(printf '%s' "$out" | grep -c '')"
assert_eq "list-all emits a single line" "1" "$lines"
assert_eq "list-all lists every recorded release" "22" \
  "$(printf '%s' "$out" | tr ' ' '\n' | grep -c .)"
newest="$(printf '%s' "$out" | tr ' ' '\n' | pk_latest_stable)"
assert_eq "newest stable is last after sorting" "0.43.0" "$newest"
assert_not_contains "no prerelease leaks as newest" "-rc" "$newest"
# The stable release must be the final token, so asdf's tail fallback is safe.
assert_eq "last token is the newest stable release" "0.43.0" \
  "$(printf '%s' "$out" | tr ' ' '\n' | grep -v '^$' | tail -1)"

########################################################################
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  green "all ${PASS} assertions passed"
  exit 0
fi
red "${FAIL} of $((PASS + FAIL)) assertions failed:"
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
