# asdf-pipelinek

[asdf](https://asdf-vm.com) plugin for [PipelineK](https://github.com/Rubentxu/pipeline-kotlin).

Installs the **official release ZIP** from
[github.com/Rubentxu/pipeline-kotlin/releases](https://github.com/Rubentxu/pipeline-kotlin/releases),
verifies its SHA-256 against the published `SHA256SUMS`, and fails closed on any
mismatch. The plugin **never compiles PipelineK** and **never installs Java**.

## Install

```bash
asdf plugin add pipelinek https://github.com/Rubentxu/asdf-pipelinek.git
asdf install pipelinek 0.40.0        # or the latest stable
asdf set --home pipelinek 0.40.0     # or per-project with asdf local
```

## Requirements

- **JDK 21+** must be available (system JDK, SDKMAN, or `asdf` java plugin).
  The plugin does not install Java. If `pipelinek version` fails with a Java
  error, see the hint printed by `bin/install`.
- `curl`, `unzip`, `sha256sum` (coreutils), `awk`, `find`, `zip` (tests only).

## GitHub Authentication (Optional)

The plugin uses the GitHub API to list available versions. To avoid rate limits:

1. **Using gh CLI** (recommended):
   ```bash
   gh auth login
   ```

2. **Using environment variable**:
   ```bash
   export GITHUB_TOKEN="your_token_here"
   ```

3. **Without authentication**: Works but has a rate limit of 60 requests/hour.

The plugin resolves a token from `GITHUB_TOKEN`, `GITHUB_API_TOKEN`, the `gh`
CLI, or `~/.config/gh/hosts.yml`, in that order. A failed authenticated request
is retried anonymously, so a stale token cannot make the plugin unusable.


## Version policy

- `asdf install pipelinek <version>` accepts any published release tag,
  including prereleases like `0.40.0-rc1` (always pinned explicitly).
- `asdf latest pipelinek` returns **stable releases only**; prereleases
  (`-rc*`, etc.) are never the default.
- `asdf latest pipelinek <prefix>` narrows to that prefix, e.g.
  `asdf latest pipelinek 0.40` → `0.40.0`.

## Requirements

- **JDK 21+** must be available (system JDK, SDKMAN, or `asdf` java plugin).
  The plugin does not install Java. If `pipelinek version` fails with a Java
  error, see the hint printed by `bin/install`.
- `curl`, `unzip`, `sha256sum` (coreutils), `awk`, `find`, `zip` (tests only).

## Security

Every download is verified against the `SHA256SUMS` asset published with the
release. A digest mismatch aborts the install before any file is placed.
Releases also ship CycloneDX SBOMs (`bom.json`/`bom.xml`) — see the release page.

## Development

```bash
./test/run-tests.bash    # offline contract tests, no network required
shellcheck bin/* lib/*.bash test/*.bash
```

The tests replay a recorded copy of the upstream release API
(`test/fixtures/releases.json`) through a `curl` stub, and cover the three
defects that previously made every install fail: wrong digest-manifest asset
name, a hardcoded assumption about the ZIP's top-level directory name, and a
`bin/latest` callback that asdf never invokes.

## License

MIT
