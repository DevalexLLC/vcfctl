# vcfctl — repo conventions

Public container image (ghcr.io/devalexllc/vcfctl) bundling the Broadcom VCF 9 CLI + all
plugins + kubectl + login helpers for air-gapped VKS access, plus runtime-installed vSphere 8
(TKGS) support via `tkgs-login`. See README.md for user docs.

## Rules

- `versions.env` is the single source of truth for pinned versions. The Makefile and both
  workflows read it; never hardcode versions elsewhere.
- Deliberate exception to pinning: the vSphere 8 CLI tools (`kubectl-vsphere` + matched
  kubectl) have NO public/versioned/checksummed download — each Supervisor serves its own
  copy at `/wcp/plugin/linux-amd64/vsphere-plugin.zip`. Never attempt to bake or pin them;
  `bin/tkgs-login` installs them at runtime into the home volume.
- Never modify Broadcom binaries; they are downloaded checksum-verified at build time and
  shipped unmodified (see NOTICE).
- Only the per-OS/arch plugin bundle (`vcf-cli-plugins/vX/linux/<arch>/plugins.tar.gz`) may be
  used as plugin source. `vcf plugin download-bundle` is banned — it mirrors every OS/arch.
- All shell scripts must be shellcheck-clean (`make lint`), `set -euo pipefail`, with `--help`.
- Image tags track the bundled VCF CLI version (`9.0.2`, `latest`, `-N` revision suffix for
  image-side rebuilds, git tags like `v9.0.2-1`).

## Build & test

```bash
make build   # local image vcfctl:dev
make test    # smoke suite; offline behavior proven with --network=none
make lint    # shellcheck
```

## Verified facts (checked against the real v9.0.2 binary — do not re-derive)

- Env var prefix is `VCF_CLI_` (NOT `TANZU_CLI_`; verified via `strings` on the binary).
- `VCF_CLI_PLUGIN_DB_CACHE_TTL_SECONDS=0` means "immediately stale, refresh from network
  every time" — the image sets a 10-year TTL instead. `VCF_CLI_USE_DB_CACHE_ONLY` is
  IGNORED by v9.0.2 (tested offline).
- The plugin-install layer runs with `--network=none`: with network, first-run init
  downloads the latest unpinned essentials plugin group BEFORE honoring `--local-source`
  (non-reproducible builds). Offline install from the bundle is verified working; the CEIP
  opt-out also works offline.
- The default plugin discovery source is DELETED at build (`vcf plugin source delete
  default`): while any source exists but no inventory cache does (network-none build bakes
  none), every command attempts online init — on drop-traffic firewalls that stalls for TCP
  timeouts. With no source, `vcf plugin list` runs clean and `vcf plugin search` fails
  instantly with "run 'vcf plugin source init'" (verified). Users restore online plugin
  management with `vcf plugin source init`.
- v9.0.2 has NO interactive EULA prompt; first run auto-initializes and auto-installs the
  essentials plugin group when online. CEIP opt-out: `vcf telemetry cli-usage-analytics
  update --opt-out` (done at build).
- `vcf config eula accept` does NOT exist in v9.0.2.
- CLI state paths: config `~/.config/vcf/` (+ `~/.config/vcf-cli-telemetry/`), plugin
  binaries `~/.local/share/vcf-cli/`, inventory/catalog cache `~/.cache/vcf/`.
- The plugin catalog and config store ABSOLUTE paths — plugin state must be created under
  `/home/vcfctl` at build; custom `--user`/`$HOME` at runtime is unsupported.
- Mounted-volume support: build installs plugins into the real home, then `mv`s state to
  `/opt/vcfctl/skel` in the SAME Dockerfile layer (avoids doubling image size);
  `entrypoint.sh` seeds `$HOME` on start (plugin state replaced on version change, user
  config never clobbered — `cp -an`).
- Upstream URLs: CLI `vcf-distro/vcf-cli/linux/<arch>/v<ver>/vcf-cli.tar.gz`; plugins
  `vcf-distro/vcf-cli-plugins/v<ver>/linux/<arch>/plugins.tar.gz`; both with `sha256sum.txt`
  (`<hash> *<file>` format). Plugin bundle versions are independent of CLI versions (as of
  2026-07 only v9.0.0 exists).

## vSphere 8 (TKGS) runtime tools — facts and contracts

- Distribution (per Broadcom techdocs): `https://<supervisor>/wcp/plugin/linux-amd64/
  vsphere-plugin.zip`, self-signed cert by default, x86_64 only, no checksums, contains
  `bin/kubectl` + `bin/kubectl-vsphere` version-matched to that Supervisor. Also
  darwin-amd64/windows-amd64 variants (unused here).
- Install dirs (in the home volume, so they persist): `~/.local/bin/kubectl-vsphere`;
  opt-in Supervisor-matched kubectl in `~/.local/tkgs/bin/kubectl` (`--with-kubectl`).
  INVARIANT: `~/.local/bin` must never contain a `kubectl` — the skel `~/.profile`
  re-prepends it ahead of `~/.local/tkgs/bin` in login shells, which would silently
  shadow without opt-in.
- PATH contract: `~/.local/tkgs/bin:~/.local/bin:` + Debian default, set in TWO places
  that must stay in sync — Dockerfile ENV (one-shot `docker run`, `docker exec`) and
  profile-vcfctl.sh (login shells: Debian's `/etc/profile` unconditionally RESETS PATH,
  discarding the ENV entries, so the profile snippet re-prepends them). Both dirs absent
  until tkgs-login creates them → image kubectl resolves by default. Smoke test [9]
  enforces the contract in both shell types.
- `entrypoint.sh` seeding removes only `.local/share/vcf-cli` and `.cache/vcf` — the
  runtime-installed tools survive re-seeding and image upgrades (verified).
- Password env var for `kubectl vsphere login` is `KUBECTL_VSPHERE_PASSWORD` (the
  plugin's own; sessions last ~10 h, not configurable).
- CA trust without root (uid 1000 cannot run update-ca-certificates): tkgs-login builds
  `~/.config/vcfctl/tkgs-ca-bundle.crt` = system roots + `~/.config/vcfctl/certs/*.crt`
  (always a superset of system trust; stored outside certs/ so it never self-includes)
  and passes it via `SSL_CERT_FILE`; profile-vcfctl.sh exports it in login shells only
  when the file exists (Go degrades root loading if SSL_CERT_FILE points at a missing
  file). UNVERIFIED against a real Supervisor: whether kubectl-vsphere honors
  SSL_CERT_FILE (standard Go root loading suggests yes) and whether its written
  kubeconfig embeds CA data — `--insecure` → `--insecure-skip-tls-verify` is the
  guaranteed fallback either way.
