# vcfctl

[![build](https://github.com/devalexllc/vcfctl/actions/workflows/build.yml/badge.svg)](https://github.com/devalexllc/vcfctl/actions/workflows/build.yml)

**One `docker pull` to a working VKS login toolbox for VCF 9 *and* vSphere 8 — built for
air-gapped environments.**

VCF 9 replaced `kubectl vsphere` with the `vcf` CLI, which normally installs its plugins from
Broadcom's online plugin repository — a problem in disconnected environments. This image ships
the **VCF 9 CLI with every plugin preinstalled**, plus `kubectl` and login helper scripts, all
preconfigured to work fully offline. Pull the image, run it, log in to your
vSphere Kubernetes Service (VKS) environment. For **vSphere 8** Supervisors (TKG Service),
the `tkgs-login` helper installs the classic `kubectl-vsphere` plugin directly from *your*
Supervisor on first use — the only place it is distributed — and logs you in.

```bash
docker pull ghcr.io/devalexllc/vcfctl:9.0.2
```

## Quickstart

```bash
docker volume create vcfctl-home
alias vcfctl='docker run -it --rm -v vcfctl-home:/home/vcfctl:z ghcr.io/devalexllc/vcfctl:9.0.2'

vcfctl                        # interactive shell with vcf, kubectl, and helpers
vcfctl vcf context list       # or run any command one-shot
vcfctl kubectl get pods       # contexts/kubeconfigs persist in the volume
```

Nothing is installed on the host — every command in this README (`vcf`, `kubectl`,
`supervisor-login`, `vcfa-login`, `tkgs-login`, `fetch-ca`) runs **inside the container**:
either type it in the interactive shell (`vcfctl`), or run it one-shot by prefixing the alias
(`vcfctl supervisor-login ...`). To pass credentials via environment variables in one-shot
mode, forward them through Docker (an `-e VAR` with no value forwards it only when set):

```bash
alias vcfctl='docker run -it --rm -v vcfctl-home:/home/vcfctl:z \
    -e VCF_CLI_VSPHERE_PASSWORD -e VCF_CLI_VCFA_API_TOKEN -e KUBECTL_VSPHERE_PASSWORD \
    ghcr.io/devalexllc/vcfctl:9.0.2'
```

Pick the image tag matching your VCF environment version. `latest` tracks the newest VCF CLI.

Podman works identically — substitute `podman` for `docker` throughout. The `:z` volume
suffix matters on SELinux-enforcing hosts (RHEL/Fedora): each podman container runs with a
private SELinux label, and without `:z` the volume content gets labeled for the first
container only — later runs are denied access and the CLI panics with
`cannot acquire lock for vcf config file, reason: permission denied`. `:z` keeps the volume
shared-labeled (and repairs a volume already in that state); Docker on non-SELinux hosts
ignores it.

## What's inside

| Component | Version | Notes |
|---|---|---|
| `vcf` CLI | 9.0.2 | linux binary from packages.broadcom.com, checksum-verified |
| VCF CLI plugins | bundle 9.0.0 | **all** plugins: cluster, kubernetes-release, namespaces, package, pais, registry-secret, secret, telemetry, vm, imgpkg |
| `kubectl` | 1.33.x | compatible with K8s 1.32–1.34 API servers (skew policy) |
| `kubectl-vsphere` | matches your Supervisor | **not baked in** — no public download exists; `tkgs-login` installs it from your vSphere 8 Supervisor on first use (x86_64 only) |
| helpers | — | `supervisor-login`, `vcfa-login`, `tkgs-login`, `fetch-ca`, `vcfctl-help` |
| tools | — | openssl, ssh client, curl, jq, unzip, bash completion |

Offline hardening baked in: plugin auto-install at login is disabled
(`VCF_CLI_SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION=true`), the plugin database cache
never expires, and CEIP telemetry is opted out. Plugins are installed at build time from
Broadcom's checksummed offline bundle with networking disabled, so every binary in the image
is pinned and verifiable. The online plugin discovery source is removed from the image so no
command ever attempts to reach Broadcom's registry (on air-gap firewalls that silently drop
traffic, such attempts would stall). Everything operational (contexts, clusters, kubectl)
works fully offline; to browse or install additional plugins from a connected network, restore
the source with `vcf plugin source init`.
The image runs as a non-root user (uid 1000). Multi-arch: `linux/amd64` and `linux/arm64`
(the vSphere 8 CLI tools are published x86_64-only — on arm64 hosts use
`docker run --platform linux/amd64` for TKGS work).

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

## Log in: vSphere 8 Supervisor (TKG Service / TKGS)

vSphere 8 Supervisors use the classic `kubectl vsphere login` flow instead of the `vcf` CLI.
Broadcom does not publish the Kubernetes CLI Tools for vSphere anywhere public — each
Supervisor serves its own version-matched copy at
`https://<supervisor>/wcp/plugin/linux-amd64/vsphere-plugin.zip` (x86_64 only, no
checksums), so they cannot be pinned and baked into this image like everything else.
Instead, `tkgs-login` downloads them from *your* Supervisor on first use, installs them
into the home volume (where they persist across runs and image upgrades), and logs you in:

```bash
# First run downloads + installs kubectl-vsphere from the Supervisor, then logs in.
# Supervisors present a self-signed cert by default; --fetch-ca trusts it explicitly.
tkgs-login -e 10.0.0.10 -u administrator@vsphere.local --fetch-ca

# Log straight into a workload (TKG) cluster:
tkgs-login -e 10.0.0.10 -u dev@corp.example --fetch-ca -c my-cluster -s my-namespace

# After a Supervisor upgrade, refresh the tools:
tkgs-login -e 10.0.0.10 -u admin@vsphere.local --fetch-ca --force
```

Password comes from `KUBECTL_VSPHERE_PASSWORD` or an interactive prompt. Sessions last
~10 hours; re-run `tkgs-login` to renew. If CA trust gives you trouble, `--insecure` skips
TLS verification for both the download and the login.

The image's `kubectl` (1.33) targets VCF 9 clusters and is outside the supported version
skew for the older Kubernetes releases vSphere 8 runs. `--with-kubectl` additionally
installs the Supervisor-matched `kubectl` from the same zip into `~/.local/tkgs/bin`,
which is first on `PATH` — it shadows the image's kubectl until you remove it:

```bash
tkgs-login -e 10.0.0.10 -u admin@vsphere.local --fetch-ca --with-kubectl
kubectl version --client            # now reports the Supervisor's kubectl version
rm ~/.local/tkgs/bin/kubectl        # undo: back to the image's kubectl 1.33
```

CA trust works without root: fetched CAs are collected into
`~/.config/vcfctl/tkgs-ca-bundle.crt` (system roots + your Supervisor CAs), which login
shells export as `SSL_CERT_FILE` so `kubectl` and `kubectl-vsphere` trust your Supervisor
in later sessions too. Equivalent raw commands, if you prefer to run them yourself:

```bash
curl -k "https://10.0.0.10/wcp/plugin/linux-amd64/vsphere-plugin.zip" -o vsphere-plugin.zip
unzip vsphere-plugin.zip && install -m 0755 bin/kubectl-vsphere ~/.local/bin/
kubectl vsphere login --server=10.0.0.10 --vsphere-username administrator@vsphere.local \
    --insecure-skip-tls-verify
```

## Persistence & upgrades

Mount a volume (or host directory owned by uid 1000) at `/home/vcfctl` to keep VCF contexts,
kubeconfigs, fetched CA certs, and the runtime-installed vSphere 8 tools across runs. On start, the entrypoint seeds the baked CLI
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
