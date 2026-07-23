# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: fetch — download and checksum-verify all upstream artifacts
# ---------------------------------------------------------------------------
FROM debian:stable-slim AS fetch

ARG TARGETARCH
ARG VCF_CLI_VERSION
ARG VCF_PLUGIN_BUNDLE_VERSION
ARG KUBECTL_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /fetch

# VCF CLI binary (sha256sum.txt line format: "<hash> *vcf-cli.tar.gz")
RUN curl -fsSLO "https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/${TARGETARCH}/v${VCF_CLI_VERSION}/vcf-cli.tar.gz" \
    && curl -fsSLO "https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/${TARGETARCH}/v${VCF_CLI_VERSION}/sha256sum.txt" \
    && sha256sum -c sha256sum.txt \
    && tar -xzf vcf-cli.tar.gz \
    && mv "vcf-cli-linux_${TARGETARCH}" vcf \
    && chmod 0755 vcf \
    && rm vcf-cli.tar.gz sha256sum.txt

# VCF CLI plugin bundle. The per-OS/arch bundle contains ONLY linux binaries for
# this arch — do not replace this with `vcf plugin download-bundle`, which mirrors
# every OS/arch combination.
RUN mkdir plugins && cd plugins \
    && curl -fsSLO "https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/v${VCF_PLUGIN_BUNDLE_VERSION}/linux/${TARGETARCH}/plugins.tar.gz" \
    && curl -fsSLO "https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli-plugins/v${VCF_PLUGIN_BUNDLE_VERSION}/linux/${TARGETARCH}/sha256sum.txt" \
    && sha256sum -c sha256sum.txt \
    && tar -xzf plugins.tar.gz \
    && rm plugins.tar.gz sha256sum.txt

# kubectl
RUN curl -fsSLo kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && curl -fsSLo kubectl.sha256 "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
    && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c \
    && chmod 0755 kubectl

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM debian:stable-slim

ARG VCF_CLI_VERSION
ARG VCF_PLUGIN_BUNDLE_VERSION
ARG KUBECTL_VERSION

LABEL org.opencontainers.image.title="vcfctl" \
      org.opencontainers.image.description="Broadcom VCF 9 CLI with all plugins, kubectl, and login helpers for VCF 9 VKS and vSphere 8 TKGS environments — built for disconnected/air-gapped use" \
      org.opencontainers.image.source="https://github.com/devalexllc/vcfctl" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${VCF_CLI_VERSION}" \
      us.devalex.vcfctl.vcf-cli-version="${VCF_CLI_VERSION}" \
      us.devalex.vcfctl.plugin-bundle-version="${VCF_PLUGIN_BUNDLE_VERSION}" \
      us.devalex.vcfctl.kubectl-version="${KUBECTL_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl openssl openssh-client jq less bash-completion unzip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /fetch/vcf /fetch/kubectl /usr/local/bin/

RUN groupadd -g 1000 vcfctl \
    && useradd -m -u 1000 -g 1000 -s /bin/bash vcfctl \
    && mkdir -p /opt/vcfctl/skel \
    && chown -R vcfctl:vcfctl /opt/vcfctl

# Offline hardening (behavior verified against the v9.0.2 binary):
# - SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION stops login-time plugin fetches
# - PLUGIN_DB_CACHE_TTL_SECONDS=10y keeps the baked inventory cache valid forever.
#   Do NOT set it to 0 — that means "immediately stale, refresh every time".
#   (VCF_CLI_USE_DB_CACHE_ONLY is ignored by v9.0.2 — tested, do not rely on it.)
ENV VCF_CLI_SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION=true \
    VCF_CLI_PLUGIN_DB_CACHE_TTL_SECONDS=315360000 \
    HOME=/home/vcfctl \
    KUBECONFIG=/home/vcfctl/.kube/config \
    PATH=/home/vcfctl/.local/tkgs/bin:/home/vcfctl/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# PATH contract for runtime-installed vSphere 8 tools (tkgs-login): both home
# dirs are absent until tkgs-login creates them, so by default the image
# kubectl resolves everywhere. ~/.local/bin holds kubectl-vsphere and must
# never contain a kubectl; ~/.local/tkgs/bin holds the opt-in
# Supervisor-matched kubectl, which shadows the image one exactly when the
# user asked for it. ENV (not skel .profile) so one-shot `docker run` and
# `docker exec` resolve them too.

USER vcfctl
WORKDIR /home/vcfctl

# Install every plugin from the offline bundle, opt out of CEIP telemetry, then
# move all CLI state to /opt/vcfctl/skel in the SAME layer (mv, not cp — avoids
# shipping the ~250 MB plugin state twice). The entrypoint seeds it back into
# $HOME on start, which makes user-mounted volumes over /home/vcfctl work.
# NOTES:
# - state must be created under /home/vcfctl — the plugin catalog records
#   absolute installation paths.
# - --network=none: with network, the CLI's first-run init would download the
#   latest (unpinned, un-checksummed) essentials plugin group before honoring
#   --local-source, making builds non-reproducible. Offline, only the pinned
#   bundle is installed. Verified working fully offline on v9.0.2.
# - the default discovery source is DELETED: without it, no command ever
#   attempts to reach the plugin registry (on firewalls that silently drop
#   traffic, init attempts would stall for TCP timeouts on every invocation).
#   `vcf plugin source init` restores it for connected plugin management.
RUN --mount=type=bind,from=fetch,source=/fetch/plugins,target=/tmp/vcf-plugins \
    --network=none \
    vcf plugin install all --local-source /tmp/vcf-plugins \
    && vcf telemetry cli-usage-analytics update --opt-out \
    && vcf plugin source delete default \
    && vcf plugin list \
    && mv /home/vcfctl/.config /home/vcfctl/.local /home/vcfctl/.cache /opt/vcfctl/skel/ \
    # Marker = versions + digest of the seeded plugin state (file contents PLUS
    # names/modes/types/symlink targets), so an image-side rebuild that corrects
    # .local/.cache at the SAME versions — even a permissions- or symlink-only
    # fix — still re-seeds existing home volumes. (.config is excluded: it is
    # never clobbered on seed, and it contains a per-build random cliId.)
    && skel_digest=$(cd /opt/vcfctl/skel && { \
         find .local .cache -type f -print0 | sort -z | xargs -0 sha256sum; \
         find .local .cache -print0 | sort -z | xargs -0 stat -c '%n %a %F %N'; \
       } | sha256sum | awk '{print substr($1,1,16)}') \
    && echo "${VCF_CLI_VERSION}+plugins${VCF_PLUGIN_BUNDLE_VERSION}+${skel_digest}" > /opt/vcfctl/skel/.vcfctl-version

USER root
COPY docker/entrypoint.sh docker/motd.sh bin/supervisor-login bin/vcfa-login bin/tkgs-login bin/fetch-ca bin/vcfctl-help /usr/local/bin/
COPY docker/profile-vcfctl.sh /etc/profile.d/vcfctl.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/motd.sh \
        /usr/local/bin/supervisor-login /usr/local/bin/vcfa-login \
        /usr/local/bin/tkgs-login /usr/local/bin/fetch-ca /usr/local/bin/vcfctl-help

USER vcfctl

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash", "-l"]
