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
pk_zip_asset() { printf 'pipelinek-%s.zip\n' "$1"; }
pk_release_url() { printf '%s/v%s/%s\n' "$PK_RELEASE_BASE" "$1" "$2"; }

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
pk_fetch() {
  local auth=()
  local token
  if token="$(pk_github_token)"; then
    auth=(-H "Authorization: token ${token}")
  fi
  curl -fsSL --retry 3 "${auth[@]}" -o "$2" "$1"
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
