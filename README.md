# vcfctl

[![build](https://github.com/devalexllc/vcfctl/actions/workflows/build.yml/badge.svg)](https://github.com/devalexllc/vcfctl/actions/workflows/build.yml)

**One `docker pull` to a working VCF 9 VKS login toolbox — built for air-gapped environments.**

VCF 9 replaced `kubectl vsphere` with the `vcf` CLI, which normally installs its plugins from
Broadcom's online plugin repository — a problem in disconnected environments. This image ships
the **VCF 9 CLI with every plugin preinstalled**, plus `kubectl` and login helper scripts, all
preconfigured to work fully offline. Pull the image, run it, log in to your
vSphere Kubernetes Service (VKS) environment.

```bash
docker pull ghcr.io/devalexllc/vcfctl:9.0.2
```

## Quickstart

```bash
docker volume create vcfctl-home
alias vcfctl='docker run -it --rm -v vcfctl-home:/home/vcfctl ghcr.io/devalexllc/vcfctl:9.0.2'

vcfctl                        # interactive shell with vcf, kubectl, and helpers
vcfctl vcf context list       # or run any command one-shot
vcfctl kubectl get pods       # contexts/kubeconfigs persist in the volume
```

Nothing is installed on the host — every command in this README (`vcf`, `kubectl`,
`supervisor-login`, `vcfa-login`, `fetch-ca`) runs **inside the container**: either type it in
the interactive shell (`vcfctl`), or run it one-shot by prefixing the alias
(`vcfctl supervisor-login ...`). To pass credentials via environment variables in one-shot
mode, forward them through Docker (an `-e VAR` with no value forwards it only when set):

```bash
alias vcfctl='docker run -it --rm -v vcfctl-home:/home/vcfctl \
    -e VCF_CLI_VSPHERE_PASSWORD -e VCF_CLI_VCFA_API_TOKEN \
    ghcr.io/devalexllc/vcfctl:9.0.2'
```

Pick the image tag matching your VCF environment version. `latest` tracks the newest VCF CLI.

## What's inside

| Component | Version | Notes |
|---|---|---|
| `vcf` CLI | 9.0.2 | linux binary from packages.broadcom.com, checksum-verified |
| VCF CLI plugins | bundle 9.0.0 | **all** plugins: cluster, kubernetes-release, namespaces, package, pais, registry-secret, secret, telemetry, vm, imgpkg |
| `kubectl` | 1.33.x | compatible with K8s 1.32–1.34 API servers (skew policy) |
| helpers | — | `supervisor-login`, `vcfa-login`, `fetch-ca`, `vcfctl-help` |
| tools | — | openssl, ssh client, curl, jq, bash completion |

Offline hardening baked in: plugin auto-install at login is disabled
(`VCF_CLI_SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION=true`), the plugin database cache
never expires, and CEIP telemetry is opted out. Plugins are installed at build time from
Broadcom's checksummed offline bundle with networking disabled, so every binary in the image
is pinned and verifiable. The online plugin discovery source is removed from the image so no
command ever attempts to reach Broadcom's registry (on air-gap firewalls that silently drop
traffic, such attempts would stall). Everything operational (contexts, clusters, kubectl)
works fully offline; to browse or install additional plugins from a connected network, restore
the source with `vcf plugin source init`.
The image runs as a non-root user (uid 1000). Multi-arch: `linux/amd64` and `linux/arm64`.

## Log in: direct Supervisor (no VCF Automation)

For environments where you connect straight to the Supervisor as a vCenter SSO user, from the
container shell (or one-shot: `vcfctl supervisor-login ...`):

```bash
supervisor-login -e supervisor.example.com -u admin@vsphere.local --fetch-ca

# ... or drop straight into a VKS workload cluster:
supervisor-login -e supervisor.example.com -u dev@corp.example \
    -c my-cluster -s my-namespace --insecure
```

Password comes from `VCF_CLI_VSPHERE_PASSWORD` or an interactive prompt.
Equivalent raw commands:

```bash
vcf context create mysup --endpoint https://supervisor.example.com --type k8s \
    --auth-type basic --username admin@vsphere.local --ca-certificate ./ca.crt
vcf context use mysup
```

## Log in: VCF Automation (VCFA / CCI)

For environments fronted by VCF Automation, authentication uses an API token scoped to a
tenant/org (generate one in VCFA: username menu → User Settings → My Account → API Tokens).
From the container shell (or one-shot: `vcfctl vcfa-login ...` — export the token on the host
and use the credential-forwarding alias from the Quickstart):

```bash
export VCF_CLI_VCFA_API_TOKEN=...   # or let the script prompt

# Create the cci context (CA cert is fetched from the endpoint automatically):
vcfa-login -e vcfa.example.com -o acme

# Full flow: context + project/namespace + cluster kubeconfig in one command:
vcfa-login -e vcfa.example.com -o acme \
    -s acme-ns1-rmxbk -p default-project -c dev-cluster
kubectl config use-context <context printed by the script>
kubectl get nodes
```

The underlying chain, if you prefer to run it yourself:

```bash
fetch-ca vcfa.example.com > vcfa.crt
vcf context create vcfa-acme --endpoint https://vcfa.example.com --type cci \
    --auth-type basic --tenant-name acme --ca-certificate ./vcfa.crt
vcf context use vcfa-acme:acme-ns1-rmxbk:default-project
vcf cluster register-vcfa-jwt-authenticator dev-cluster
vcf cluster kubeconfig get dev-cluster
```

Namespaces created after login not showing up? Run `vcfa-login ... --refresh`, or:

```bash
vcf config set env.VCF_CLI_CONTEXT_REFRESH_EXPIRY_CHECK_SKIP true
vcf context refresh
```

## Persistence & upgrades

Mount a volume (or host directory owned by uid 1000) at `/home/vcfctl` to keep VCF contexts,
kubeconfigs, and fetched CA certs across runs. On start, the entrypoint seeds the baked CLI
and plugin state into the home if missing or if the image version changed — your contexts and
config are never overwritten, while plugin binaries update automatically when you pull a newer
tag.

Limitation: the plugin catalog records absolute paths under `/home/vcfctl`, so running with
`--user` / a custom `$HOME` is not supported.

## Air-gapped transfer

On a connected machine:

```bash
docker pull --platform linux/amd64 ghcr.io/devalexllc/vcfctl:9.0.2   # pick your target arch
docker save ghcr.io/devalexllc/vcfctl:9.0.2 | gzip > vcfctl-9.0.2.tar.gz
```

Transfer the file across the air gap, then:

```bash
docker load < vcfctl-9.0.2.tar.gz
```

No further network access is needed — plugins, inventory cache, and configuration are baked in.

## Building from source

```bash
make build        # local-arch image (vcfctl:dev), downloads from packages.broadcom.com
make test         # smoke test suite (offline behavior verified via --network=none)
make run          # interactive shell with persistent volume
```

Pinned versions live in [`versions.env`](versions.env) — the single source of truth used by the
Makefile and CI. A weekly workflow probes Broadcom's package server and opens a PR when new
versions appear.

## Disclaimer

This is a community project, not affiliated with or endorsed by Broadcom. The image
redistributes unmodified Broadcom binaries (VCF CLI and plugins) solely to facilitate their use
with Broadcom products by licensed customers; your use of them is governed by your agreement
with Broadcom. See [NOTICE](NOTICE) for details.

## License

Project code is licensed under [Apache-2.0](LICENSE). Bundled third-party binaries are covered
by their own licenses — see [NOTICE](NOTICE).
