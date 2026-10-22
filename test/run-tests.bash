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
# Honours the real flags the plugin uses: -fsSL, --retry N, -o FILE, -H header,
# and -w FORMAT. -w matters: bin/download reads the HTTP status to tell a missing
# version (404) apart from a refused request (403), so a stub that ignored -w
# would feed the plugin a status string real curl never sends.
out=""
url=""
prev=""
wfmt=""
for a in "\$@"; do
  case "\$prev" in
    -o) out="\$a"; prev=""; continue ;;
    -w) wfmt="\$a"; prev=""; continue ;;
  esac
  case "\$a" in
    -o) prev="-o"; continue ;;
    -w) prev="-w"; continue ;;
    http*) url="\$a" ;;
  esac
  prev="\$a"
done

# Emit the -w format the way real curl does: %-expansions become the status,
# anything else passes through.
emit_status() {
  [ -z "\$wfmt" ] && return 0
  case "\$wfmt" in
    *'%{http_code}'*) printf '%s' "\${wfmt//'%{http_code}'/\$1}" ;;
    *) printf '%s' "\$wfmt" ;;
  esac
}

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
      emit_status 200
      exit 0
    fi
  done
done

echo "curl(stub): no fixture for \$url" >&2
emit_status "\${STUB_STATUS:-404}"
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
section "the archive name is READ from the manifest, not derived from the tag"

# The real v0.43.0 release publishes an asset named exactly "SHA256SUMS".
assert_eq "digest manifest asset name" "SHA256SUMS" "$(pk_sums_asset)"
assert_eq "release URL shape" \
  "https://github.com/Rubentxu/pipeline-kotlin/releases/download/v0.43.0/SHA256SUMS" \
  "$(pk_release_url 0.43.0 SHA256SUMS)"

# A manifest writer, so each test states its fixture as data and not as shell.
write_manifest() { cat > "$1"; }

M="${WORK}/m1"

# THE regression. v0.47.0-rc2 publishes its archive as "pipelinek-0.47.0.zip"
# under the tag "v0.47.0-rc2", alongside an sbom and two json manifests. A plugin
# that built the name from the tag asked for "pipelinek-0.47.0-rc2.zip", which
# no release has ever published, so no release candidate of this project could
# be installed. Reading the name out of the manifest resolves it.
write_manifest "$M" <<'SUMS'
02b1632edcd351bce3ee49ab735b72df21941595036ef5edcb7dbb3d4e9dd635  pipelinek-0.47.0.zip
f6d158afb015e8016bd21b2534a8526ac38181e8512a75f19e5038302787b2dc  pipelinek-0.47.0.sbom.json
e491f02e99a495bba412173c3c1c717e099d44160b4e7957c6192654f8113579  distribution-manifest.json
e6583293b43f1c30de98789e6f7d4e539cc9970b2e4ea35fbb77cfd6982ba7a4  candidate-handoff.json
SUMS
assert_eq "resolves the rc2 archive, whose name differs from its tag" \
  "pipelinek-0.47.0.zip" "$(pk_distribution_zip "$M")"
assert_eq "digest comes from the same manifest" \
  "02b1632edcd351bce3ee49ab735b72df21941595036ef5edcb7dbb3d4e9dd635" \
  "$(pk_manifest_digest "$M" pipelinek-0.47.0.zip)"
# The sbom shares the version prefix, so classification cannot be a bare
# "starts with pipelinek-" test.
assert_not_contains "the sbom is not mistaken for the archive" \
  "sbom" "$(pk_distribution_zip "$M")"

# A release with both runtime and SDK ZIPs must select only the runtime ZIP.
write_manifest "$M" <<'SUMS'
02b1632edcd351bce3ee49ab735b72df21941595036ef5edcb7dbb3d4e9dd635  pipelinek-0.47.0.zip
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  pipelinek-0.47.0.sdk.zip
SUMS
assert_eq "runtime archive wins when release also has an SDK ZIP" \
  "pipelinek-0.47.0.zip" "$(pk_distribution_zip "$M")"
assert_eq "only the runtime ZIP is returned as a candidate" \
  "$(printf '02b1632edcd351bce3ee49ab735b72df21941595036ef5edcb7dbb3d4e9dd635\tpipelinek-0.47.0.zip')" \
  "$(pk_manifest_dist_rows "$M")"

# v0.47.0-rc1 did carry a tag-shaped name, and must still resolve.
write_manifest "$M" <<'SUMS'
3bbe586b1fa2e6574fd11c1dd79292d51c330e92e7da87bf4f4c47071bbc0d7c  pipelinek-0.47.0-rc1.zip
85020ea692fe92161b803acd4f840184fc19a11ffdf74326ad89b0f4d446b146  pipelinek-0.47.0-rc1.sbom.json
SUMS
assert_eq "resolves an rc1 archive named after its tag" \
  "pipelinek-0.47.0-rc1.zip" "$(pk_distribution_zip "$M")"

# A promoted GA carries the candidate's asset name verbatim under the GA tag, so
# the GA-shaped manifest has to resolve to the same bytes the candidate shipped.
write_manifest "$M" <<'SUMS'
02b1632edcd351bce3ee49ab735b72df21941595036ef5edcb7dbb3d4e9dd635  pipelinek-0.47.0.zip
02b1632edcd351bce3ee49ab735b72df21941595036ef5edcb7dbb3d4e9dd635  pipelinek-0.47.0.sbom.json
SUMS
assert_eq "resolves the GA archive" "pipelinek-0.47.0.zip" "$(pk_distribution_zip "$M")"

# The older plain shape, unchanged.
write_manifest "$M" <<'SUMS'
59478baf669407aa905239e3754aff48d77d20f8fad4de8e48464583fb929397  pipelinek-0.46.0.zip
5591480be83676a1172a3b714f52926b92a54ef133998a7652f9ce1f1e66ddd2  pipelinek-0.46.0.sbom.json
SUMS
assert_eq "resolves a plain GA archive" "pipelinek-0.46.0.zip" "$(pk_distribution_zip "$M")"

# Unresolvable manifests must fail closed rather than fall back to a guess.
write_manifest "$M" <<'SUMS'
deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  manifest.json
SUMS
out="$(pk_distribution_zip "$M" 2>&1)"
assert_status "a manifest with no archive fails closed" "1" "$?"
assert_contains "and says so" "no distribution archive" "$out"

write_manifest "$M" <<'SUMS'
aaaa  pipelinek-0.47.0.zip
bbbb  pipelinek-0.47.0-hotfix.zip
SUMS
out="$(pk_distribution_zip "$M" 2>&1)"
assert_status "two candidate archives fail closed" "1" "$?"
assert_contains "ambiguity is named as such" "ambiguous" "$out"

# One name with two digests is a self-contradicting manifest. Accepting either
# digest would reduce the SHA-256 check to proving the file matches one of two
# conflicting claims.
write_manifest "$M" <<'SUMS'
aaaa  pipelinek-0.47.0.zip
bbbb  pipelinek-0.47.0.zip
SUMS
out="$(pk_manifest_digest "$M" pipelinek-0.47.0.zip 2>&1)"
assert_status "conflicting digests fail closed" "1" "$?"
assert_contains "and report the contradiction" "different digests" "$out"

# The same name repeated with the same digest is benign.
write_manifest "$M" <<'SUMS'
aaaa  pipelinek-0.47.0.zip
aaaa  pipelinek-0.47.0.zip
SUMS
assert_eq "a repeated identical entry still resolves" "aaaa" \
  "$(pk_manifest_digest "$M" pipelinek-0.47.0.zip 2>/dev/null)"

out="$(pk_manifest_digest "$M" pipelinek-9.9.9.zip 2>&1)"
assert_status "an unknown asset has no digest" "1" "$?"

# Manifest shapes seen in the wild: CRLF line endings, the binary-mode '*'
# marker, single-tab separation, and leading indentation.
write_manifest "$M" <<'SUMS'
  cccc	pipelinek-0.47.0.zip
SUMS
assert_eq "leading blanks and tab separation parse" "pipelinek-0.47.0.zip" \
  "$(pk_distribution_zip "$M")"

printf 'dddd *pipelinek-0.47.0.zip\r\n' > "$M"
assert_eq "binary-mode marker and CRLF parse" "dddd" \
  "$(pk_manifest_digest "$M" pipelinek-0.47.0.zip 2>/dev/null)"

########################################################################
section "bin/download resolves the archive from the release (P0-1 regression)"

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

# A manifest that lists no distribution archive at all must also fail closed.
printf 'deadbeef  some-other-file.zip\n' > "${SUMS}/SHA256SUMS"
out="$(PATH="${STUB_BIN}:$PATH" ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL_BAD" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "download fails closed when the manifest lists no archive" "1" "$?"
assert_contains "download explains the unresolvable manifest" \
  "does not identify a distribution archive" "$out"

# A manifest naming the artifact with a binary-mode '*' marker must still verify.
printf '%s *pipelinek-0.43.0.zip\n' "$real_digest" > "${SUMS}/SHA256SUMS"
out="$(PATH="${STUB_BIN}:$PATH" ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL_BAD" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "sha256sum binary-mode manifest is tolerated" "0" "$?"

# THE regression, end to end. Version 0.47.0-rc2 whose archive is published as
# "pipelinek-0.47.0.zip". Before this change the plugin requested
# "pipelinek-0.47.0-rc2.zip", which 404s, and no release candidate of this
# project could be installed by asdf or mise.
RC_DL="${WORK}/dlrc"
RC_SUMS="${WORK}/sumsrc"
mkdir -p "$RC_DL" "$RC_SUMS"
make_release_zip "${RC_SUMS}/pipelinek-0.47.0.zip" "pipelinek-0.47.0"
rc_digest="$(sha256sum "${RC_SUMS}/pipelinek-0.47.0.zip" | awk '{print $1}')"
cat > "${RC_SUMS}/SHA256SUMS" <<SUMSRC
${rc_digest}  pipelinek-0.47.0.zip
${rc_digest}  pipelinek-0.47.0.sbom.json
SUMSRC

out="$(PATH="${STUB_BIN}:$PATH" STUB_FIXTURES="$RC_SUMS" ASDF_INSTALL_TYPE=version \
  ASDF_INSTALL_VERSION=0.47.0-rc2 ASDF_DOWNLOAD_PATH="$RC_DL" \
  "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "an rc whose archive is named after the GA installs" "0" "$?"
assert_contains "it asks for the name the release published" \
  "download/v0.47.0-rc2/pipelinek-0.47.0.zip" "$out"
assert_contains "and verifies it" "SHA-256 verified" "$out"
if [ -f "${RC_DL}/pipelinek-0.47.0.zip" ]; then
  ok "the archive lands under its published name"
else
  fail "the archive lands under its published name" \
    "download dir: $(find "$RC_DL" -mindepth 1 | tr '\n' ' ')"
fi

RC_INSTALL="${WORK}/installrc"
out="$(ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.47.0-rc2 \
  ASDF_DOWNLOAD_PATH="$RC_DL" ASDF_INSTALL_PATH="$RC_INSTALL" \
  "${REPO_ROOT}/bin/install" 2>&1)"
assert_status "and installs from it" "0" "$?"
if [ -x "${RC_INSTALL}/bin/pipelinek" ]; then
  ok "an rc installs a working launcher"
else
  fail "an rc installs a working launcher" \
    "tree: $(find "$RC_INSTALL" -maxdepth 2 | tr '\n' ' ')"
fi

# Restore the fixture the remaining sections rely on.
printf '%s  pipelinek-0.43.0.zip\n' "$real_digest" > "${SUMS}/SHA256SUMS"

########################################################################
section "download distinguishes WHY a fetch failed"

# The point of capturing the HTTP status: a 404 (no such version) and a 403
# (rate limit / refused) used to produce the identical opaque message, so a user
# could not tell a typo from a throttled request. These force each status
# through the stub and assert the two messages genuinely differ.

DL_404="${WORK}/dl404"
mkdir -p "$DL_404"
out_404="$(PATH="${STUB_BIN}:$PATH" STUB_FIXTURES="${WORK}/empty" STUB_STATUS=404 \
  ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=9.99.99 \
  ASDF_DOWNLOAD_PATH="$DL_404" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "404 fails closed" "1" "$?"
assert_contains "404 says the version does not exist" "does not exist" "$out_404"
assert_contains "404 points at list all" "list all" "$out_404"

DL_403="${WORK}/dl403"
mkdir -p "$DL_403"
out_403="$(PATH="${STUB_BIN}:$PATH" STUB_FIXTURES="${WORK}/empty" STUB_STATUS=403 \
  ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL_403" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "403 fails closed" "1" "$?"
assert_contains "403 names the HTTP status" "403" "$out_403"
assert_contains "403 suggests authenticating" "GITHUB_TOKEN" "$out_403"
# The decisive assertion: a 404 must NOT read like a 403 and vice versa.
assert_not_contains "403 does not claim the version is missing" \
  "does not exist" "$out_403"
assert_not_contains "404 does not blame the rate limit" \
  "rate limit" "$out_404"

# A request that never reached the server (DNS/proxy/TLS) reports 000, which is
# a network problem, not a missing version.
DL_000="${WORK}/dl000"
mkdir -p "$DL_000"
out_000="$(PATH="${STUB_BIN}:$PATH" STUB_FIXTURES="${WORK}/empty" STUB_STATUS=000 \
  ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$DL_000" "${REPO_ROOT}/bin/download" 2>&1)"
assert_status "network failure fails closed" "1" "$?"
assert_contains "000 says GitHub was unreachable" "could not reach" "$out_000"
assert_not_contains "000 does not claim the version is missing" \
  "does not exist" "$out_000"

# Fail-closed must be total: no partial artifact may survive a failed fetch.
assert_eq "404 leaves no partial download behind" "0" \
  "$(find "$DL_404" -mindepth 1 | grep -c . || true)"

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
assert_contains "install says what it looked for" "no pipelinek-*.zip" "$out"

# Two archives in the download directory means resolution cannot be trusted, and
# installing either would be a coin flip on which release this is.
AMB="${WORK}/dlamb"
mkdir -p "$AMB"
cp "${DL}/pipelinek-0.43.0.zip" "${AMB}/"
cp "${DL}/pipelinek-0.43.0.zip" "${AMB}/pipelinek-0.43.0-other.zip"
out="$(ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=0.43.0 \
  ASDF_DOWNLOAD_PATH="$AMB" ASDF_INSTALL_PATH="${WORK}/install-amb" \
  "${REPO_ROOT}/bin/install" 2>&1)"
assert_status "install fails closed on two archives" "1" "$?"
assert_contains "and refuses to guess" "Refusing to guess" "$out"
assert_eq "nothing was installed" "0" \
  "$(find "${WORK}/install-amb" -mindepth 1 2>/dev/null | grep -c . || true)"

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
#
# PATH must carry the stub here. Without it this callback reached the real
# GitHub API and returned whichever release is newest today, so the assertion
# silently tested production instead of the fixture, and only failed because
# upstream had moved on since the fixture was recorded. Every run that did NOT
# fail was a run that proved nothing about the contract.
export STUB_FIXTURES="$WORK/no-overrides"
mkdir -p "$STUB_FIXTURES"
assert_eq "latest-stable callback returns the newest stable" \
  "0.43.0" "$(PATH="${STUB_BIN}:$PATH" "${REPO_ROOT}/bin/latest-stable" 2>/dev/null)"
assert_eq "latest-stable honours a prefix query" \
  "0.40.0" "$(PATH="${STUB_BIN}:$PATH" "${REPO_ROOT}/bin/latest-stable" 0.40 2>/dev/null)"
assert_eq "latest-stable fails closed for an unknown query" "1" \
  "$(PATH="${STUB_BIN}:$PATH" "${REPO_ROOT}/bin/latest-stable" 9.99 >/dev/null 2>&1; echo $?)"

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

FALLBACK_FIXTURES="${WORK}/empty-release-list"
mkdir -p "$FALLBACK_FIXTURES"
printf '[]\n' > "${FALLBACK_FIXTURES}/releases.json"
cat > "${FALLBACK_FIXTURES}/tags.json" <<'TAGS'
[
  {"ref": "refs/tags/v0.74.0-rc1"},
  {"ref": "refs/tags/v0.75.0"},
  {"ref": "refs/tags/wu-lpr-090"},
  {"ref": "refs/tags/checkpoint-2026-10-22"}
]
TAGS
fallback_versions="$(PATH="${STUB_BIN}:$PATH" STUB_FIXTURES="$FALLBACK_FIXTURES" \
  "${REPO_ROOT}/bin/list-all" 2>/dev/null)"
assert_status "empty release list falls back to Git tag refs" "0" "$?"
assert_eq "fallback returns only SemVer tags" "0.74.0-rc1 0.75.0" \
  "$(printf '%s' "$fallback_versions" | tr ' ' '\n' | pk_sort_versions | tr '\n' ' ' | sed 's/ $//')"
latest_fallback="$(PATH="${STUB_BIN}:$PATH" STUB_FIXTURES="$FALLBACK_FIXTURES" \
  "${REPO_ROOT}/bin/latest-stable" 2>/dev/null)"
assert_eq "latest-stable resolves the stable version from tag refs" "0.75.0" "$latest_fallback"

########################################################################
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  green "all ${PASS} assertions passed"
  exit 0
fi
red "${FAIL} of $((PASS + FAIL)) assertions failed:"
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
