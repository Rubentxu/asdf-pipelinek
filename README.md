# asdf-pipelinek

[asdf](https://asdf-vm.com) plugin for [PipelineK](https://github.com/Rubentxu/pipeline-kotlin).

Installs the **official release ZIP** from
[github.com/Rubentxu/pipeline-kotlin/releases](https://github.com/Rubentxu/pipeline-kotlin/releases),
verifies its SHA-256 against the published `SHA256SUMS`, and fails closed on any
mismatch. The plugin **never compiles PipelineK** and **never installs Java**.

## Install

```bash
asdf plugin add pipelinek https://github.com/Rubentxu/asdf-pipelinek.git
asdf install pipelinek 0.39.1-rc1      # or the latest stable, e.g. 0.39.0
asdf set --home pipelinek 0.39.0       # or per-project with asdf local
```

## Requirements

- **JDK 21+** must be available (system JDK, SDKMAN, or `asdf` java plugin).
  The plugin does not install Java. If `pipelinek version` fails with a Java
  error, see the hint printed by `bin/install`.
- `curl`, `unzip`, `sha256sum` (coreutils).

## Version policy

- `asdf install pipelinek <version>` accepts any published release tag,
  including prereleases like `0.39.1-rc1` (always pinned explicitly).
- `asdf latest pipelinek` returns **stable releases only**; prereleases
  (`-rc*`, etc.) are never the default.

## Security

Every download is verified against the `SHA256SUMS` asset published with the
release. A digest mismatch aborts the install before any file is placed.
Releases also ship CycloneDX SBOMs (`bom.json`/`bom.xml`) — see the release page.

## License

MIT
