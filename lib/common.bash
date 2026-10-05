#!/usr/bin/env bash
# Shared helpers for asdf-pipelinek callbacks.
# Sourced, never executed. No side effects beyond defining functions.

# Upstream release repository and the canonical asset naming it actually uses.
# Verified against https://api.github.com/repos/Rubentxu/pipeline-kotlin/releases/tags/v0.43.0
PK_GH_REPO="${PK_GH_REPO:-Rubentxu/pipeline-kotlin}"
PK_RELEASE_BASE="https://github.com/${PK_GH_REPO}/releases/download"

# Upstream ships a single, version-independent digest manifest per release named
# exactly "SHA256SUMS" (NOT "pipelinek-<version>.SHA256SUMS"). Keep this in one
# place so a future upstream rename is a one-line change.
pk_sums_asset() { printf '%s\n' "SHA256SUMS"; }
pk_release_url() { printf '%s/v%s/%s\n' "$PK_RELEASE_BASE" "$1" "$2"; }

# Which manifest entry is the distribution archive.
#
# The published manifest is "<sha256>  <name>", two spaces, no '*' marker, but
# tolerate the binary-mode '*' prefix some checksum tools emit. The name is the
# last whitespace-delimited field; everything before it is the digest.
PK_DIST_ZIP_RE='^pipelinek-[^/]+\.zip$'

# Print "<sha256><TAB><name>" for every distribution-archive entry in a manifest.
# One awk owns the parsing so the consumers below cannot drift apart on what a
# manifest line means.
# $1 path to a SHA256SUMS file.
pk_manifest_dist_rows() {
  awk -v re="$PK_DIST_ZIP_RE" '
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[ \t]+/, "", line)
      # strip an optional binary-mode marker
      sub(/^[*]/, "", line)
      n = split(line, f, /[ \t]+/)
      if (n < 2) next
      name = f[n]
      sub(/^\*/, "", name)
      if (name !~ re) next
      print f[1] "\t" name
    }
  ' "$1"
}

# Print the name of the distribution archive in a manifest.
# $1 path to a SHA256SUMS file.
#
# The name is READ from what the release published, never derived from the
# version. Deriving it ("pipelinek-<version>.zip") is what made this plugin
# unable to install any real release candidate: the v0.47.0 line ships rc2's
# artifact as "pipelinek-0.47.0.zip" under the tag "v0.47.0-rc2", so the derived
# name never existed and rc2 was uninstallable by every approved channel. A
# promoted GA keeps the candidate's bytes, and under the v2 release model also
# its asset name, so a name derived from the GA tag is a name nobody published.
# Both directions were unwinnable: the correct name installs a URL that 404s,
# and the only name that "worked" was the accident of a candidate published
# under its GA name.
#
# SHA256SUMS is the release's own index of its contents, so the single entry
# shaped like a distribution archive is the answer. The pattern only classifies
# an entry by role (distribution vs sbom vs json); it does not rebuild a name.
#
# Fails closed (non-zero, diagnostic on stderr) when the manifest lists no such
# entry or more than one. Choosing between candidates is the very guess this
# replaces, and an unresolvable release must install nothing at all.
pk_distribution_zip() {
  local rows names count
  rows="$(pk_manifest_dist_rows "$1")"
  names="$(printf '%s' "$rows" | awk -F'\t' '!seen[$2]++ { print $2 }')"
  count="$(printf '%s\n' "$names" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "no distribution archive (an entry named pipelinek-<something>.zip) is listed in the manifest" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "ambiguous distribution archive: the manifest lists ${count} of them" >&2
    # shellcheck disable=SC2086  # deliberate: one name per line, unquoted so each becomes an argument
    printf '  %s\n' $names >&2
    return 1
  fi
  printf '%s\n' "$names"
}

# Print the SHA-256 the manifest publishes for a named entry.
# $1 manifest path, $2 asset name.
#
# Fails closed when the asset has no entry, and also when the manifest gives
# the same name two different digests: picking either would make the
# verification below meaningless, since it would only prove the file matches
# one of two contradictory claims.
pk_manifest_digest() {
  local digests count
  digests="$(pk_manifest_dist_rows "$1" | awk -F'\t' -v want="$2" '$2 == want { print $1 }')"
  count="$(printf '%s\n' "$digests" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "the manifest has no entry for ${2}" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    local unique
    unique="$(printf '%s\n' "$digests" | awk '!seen[$0]++' | grep -c . || true)"
    if [ "$unique" -gt 1 ]; then
      echo "the manifest gives ${2} ${unique} different digests" >&2
      return 1
    fi
  fi
  printf '%s\n' "$digests" | head -1
}

# GitHub token resolution, shared by every callback that talks to GitHub.
# Precedence: GITHUB_TOKEN, GITHUB_API_TOKEN, gh CLI, gh config file.
# Prints the token on stdout and returns 0; returns 1 with no output when no
# source yields one, so callers can fall back to anonymous access.
pk_github_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s\n' "$GITHUB_TOKEN"
    return 0
  fi
  if [ -n "${GITHUB_API_TOKEN:-}" ]; then
    printf '%s\n' "$GITHUB_API_TOKEN"
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    local t
    if t="$(gh auth token 2>/dev/null)" && [ -n "$t" ]; then
      printf '%s\n' "$t"
      return 0
    fi
  fi
  local cfg="${HOME:-}/.config/gh/hosts.yml"
  if [ -f "$cfg" ]; then
    local t
    t="$(grep 'oauth_token:' "$cfg" 2>/dev/null | head -1 | awk '{print $2}')"
    if [ -n "$t" ]; then
      printf '%s\n' "$t"
      return 0
    fi
  fi
  return 1
}

# Fetch a URL, authenticating when a token is available. GitHub allows only 60
# anonymous requests per hour, which a CI matrix exhausts quickly.
# $1 url, $2 destination.
#
# curl -f makes a non-2xx response fail WITHOUT preserving the status code, so
# before this helper recorded it a 404 (no such version) and a 403 (rate limit or
# bad token) were indistinguishable to callers: both surfaced as a bare
# "could not download". PK_LAST_STATUS now carries the status so callers can say
# which one actually happened. curl -f still governs success, so a non-2xx
# response is never written to the destination and always returns non-zero; only
# the diagnosis improves, never the fail-closed behaviour.
#
# Must be called in the current shell, not a command substitution, for the
# caller to read PK_LAST_STATUS back.
pk_fetch() {
  local auth=()
  local token
  if token="$(pk_github_token)"; then
    auth=(-H "Authorization: token ${token}")
  fi
  # -w writes to stdout; -o sends the body to the file, so stdout carries only
  # the status line. http_code is 000 when the request never reached the server
  # (DNS, proxy, TLS, timeout), which is the network-failure case itself.
  local status
  status="$(curl -fsSL --retry 3 -w '%{http_code}' "${auth[@]}" -o "$2" "$1" 2>/dev/null)" || true
  PK_LAST_STATUS="$status"
  [ -n "$PK_LAST_STATUS" ] || return 1
  case "$PK_LAST_STATUS" in
    2*) return 0 ;;
    # curl -f already refused to write the body on a non-2xx response.
    *) return 1 ;;
  esac
}

# Turn a failed pk_fetch into a message a user can act on.
# $1 what failed (e.g. "pipelinek-0.43.0.zip"), $2 version.
pk_explain_fetch_failure() {
  local what="$1" version="$2" status="${PK_LAST_STATUS:-000}"
  case "$status" in
    404)
      echo "ERROR: ${what} does not exist: version ${version} was not found in the" >&2
      echo "${PK_GH_REPO} releases." >&2
      echo "Run 'asdf list all pipelinek' to see the available versions." >&2
      ;;
    403)
      echo "ERROR: GitHub refused the request for ${what} (HTTP 403)." >&2
      echo "This is usually the anonymous rate limit (60 requests/hour), not a" >&2
      echo "missing version. Authenticate to raise it:" >&2
      echo "  gh auth login" >&2
      echo "  # or: export GITHUB_TOKEN=..." >&2
      ;;
    429)
      echo "ERROR: GitHub rate limit exceeded for ${what} (HTTP 429)." >&2
      echo "Wait for the limit to reset, or authenticate with GITHUB_TOKEN." >&2
      ;;
    000)
      echo "ERROR: could not reach GitHub to download ${what}." >&2
      echo "Check your connection and proxy settings (HTTPS_PROXY), then retry." >&2
      ;;
    *)
      echo "ERROR: could not download ${what} (HTTP ${status})." >&2
      ;;
  esac
}

# Fetch a URL to stdout, authenticating when possible. $1 url.
pk_fetch_stdout() {
  local auth=()
  local token
  if token="$(pk_github_token)"; then
    auth=(-H "Authorization: token ${token}")
  fi
  curl -fsSL --retry 3 "${auth[@]}" "$1"
}

# Prerelease detection, single source of truth. Upstream uses -rcN today; other
# SemVer prerelease shapes (-alpha, -beta, -M1) and '+' build metadata are also
# treated as unstable so the stable filter never silently leaks one.
# In POSIX ERE, unanchored '-' before a non-digit is not reliable, so the pattern
# is explicit: a '-' or '+' that is not the leading character.
PK_PRERELEASE_RE='^[0-9][0-9A-Za-z.]*[-+]'

pk_is_prerelease() {
  printf '%s' "$1" | grep -Eq "$PK_PRERELEASE_RE"
}

# Emit only stable versions, one per line. Accepts space- or newline-separated.
pk_filter_stable() {
  tr ' ' '\n' | grep -v '^[[:space:]]*$' | grep -Ev "$PK_PRERELEASE_RE" || true
}

# Portable version sort (GNU sort -V is explicitly non-portable per the asdf
# plugin authoring rules, and 'sort' is on asdf's banned-commands list).
# Emits the input lines in ascending SemVer precedence order, so the newest
# version is last. Within one release a prerelease sorts before the stable
# version, which keeps the last token a stable release.
pk_sort_versions() {
  awk '
    # Compare two version fragments, returning -1/0/1.
    # Every iteration consumes at least one character from BOTH strings, which
    # guarantees termination (an earlier revision compared equal fragments by
    # reassigning them unchanged and looped forever).
    function cmpnum(a, b,   x, y) {
      while (1) {
        if (a == "" && b == "") return 0
        ad = (a ~ /^[0-9]/)
        bd = (b ~ /^[0-9]/)
        if (ad && bd) {
          # compare the leading run of digits numerically
          x = a; sub(/^[^0-9]*/, "", x); sub(/[^0-9].*$/, "", x)
          y = b; sub(/^[^0-9]*/, "", y); sub(/[^0-9].*$/, "", y)
          if ((x + 0) != (y + 0)) return ((x + 0) < (y + 0)) ? -1 : 1
          sub(/^[0-9]+/, "", a); sub(/^[0-9]+/, "", b)
        } else if (ad) {
          return 1    # a still has a numeric run, b is at a separator
        } else if (bd) {
          return -1
        } else {
          # compare the leading run of non-digits
          x = a; sub(/^[^0-9]*/, "", x); sub(/[0-9].*$/, "", x)
          y = b; sub(/^[^0-9]*/, "", y); sub(/[0-9].*$/, "", y)
          if (x != y) return (x < y) ? -1 : 1
          sub(/^[^0-9]+/, "", a); sub(/^[^0-9]+/, "", b)
        }
      }
    }
    # Split "1.2.3-rc1" into release "1.2.3" and prerelease "rc1" in SPLIT_BASE/SPLIT_PRE.
    function vsplit(v) {
      pre = ""
      if (index(v, "+") > 0) { pre = substr(v, index(v, "+")); v = substr(v, 1, index(v, "+") - 1) }
      if (index(v, "-") > 0) { base = substr(v, 1, index(v, "-") - 1); pre = substr(v, index(v, "-")) pre }
      else base = v
      SPLIT_BASE = base; SPLIT_PRE = pre
    }
    { lines[NR] = $0 }
    END {
      n = NR
      for (i = 1; i <= n; i++) {
        vsplit(lines[i]); ib[i] = SPLIT_BASE; ip[i] = SPLIT_PRE
      }
      # insertion sort: release part ascending, prerelease last within a release
      for (i = 2; i <= n; i++) {
        key = lines[i]; kb = ib[i]; kp = ip[i]
        j = i - 1
        while (j >= 1) {
          c = cmpnum(ib[j], kb)
          if (c == 0) {
            # SemVer: a prerelease has LOWER precedence than the stable
            # release of the same number, so in ascending order the
            # prerelease comes first and the stable version lands last.
            # That also makes the asdf tail-based fallback resolve to a
            # stable version.
            if (ip[j] == "" && kp != "") c = 1
            else if (ip[j] != "" && kp == "") c = -1
            else if (ip[j] == "" && kp == "") c = 0
            else c = cmpnum(ip[j], kp)
          }
          if (c <= 0) break
          lines[j + 1] = lines[j]; ib[j + 1] = ib[j]; ip[j + 1] = ip[j]
          j--
        }
        lines[j + 1] = key; ib[j + 1] = kb; ip[j + 1] = kp
      }
      for (i = 1; i <= n; i++) print lines[i]
    }
  '
}

# Latest stable version from a whitespace-separated version list on stdin.
# Prints nothing and returns 1 when no stable version exists, so callers can
# fail closed instead of handing asdf an empty version.
pk_latest_stable() {
  pk_filter_stable | pk_sort_versions | tail -1 | grep -v '^$'
}

# Filter a version list by a prefix query (asdf passes $1 to latest-stable).
# Accepts space- or newline-separated input. An empty query matches everything.
# The query is a plain prefix, mirroring asdf itself ("list all nodejs 18"
# selects every 18.x), so 0.4 matches 0.4.0, 0.43.0 and 0.432.0 alike. Dots are
# escaped so a query can never be read as a regex wildcard.
pk_filter_prefix() {
  local query="$1"
  # Normalise to one version per line so the line-oriented grep below is valid.
  local lines
  lines="$(tr ' ' '\n' | grep -v '^[[:space:]]*$' || true)"
  if [ -z "$query" ]; then
    printf '%s\n' "$lines"
    return 0
  fi
  local esc="${query//./\\.}"
  printf '%s\n' "$lines" | grep -E "^${esc}" || true
}
