#!/usr/bin/env bash
# Smoke test suite for the vcfctl image. Needs no VCF infrastructure; offline
# behavior is proven with --network=none.
#
# Usage: IMAGE=vcfctl:dev ./test/smoke.sh
set -uo pipefail

IMAGE=${IMAGE:?set IMAGE to the image tag to test}

# Expected versions from versions.env (repo root or parent of this script)
VERSIONS_FILE="$(cd "$(dirname "$0")/.." && pwd)/versions.env"
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

EXPECTED_PLUGINS=(cluster imgpkg kubernetes-release namespaces package pais registry-secret secret telemetry vm)

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

offline() { docker run --rm --network=none "$IMAGE" "$@"; }

echo "[1] vcf version (offline)"
if out=$(offline vcf version 2>&1) && grep -q "v${VCF_CLI_VERSION}" <<<"$out"; then
    pass "vcf version reports v${VCF_CLI_VERSION}"
else
    fail "vcf version: $out"
fi

echo "[2] vcf plugin list (offline) contains all expected plugins"
out=$(offline vcf plugin list 2>&1)
for p in "${EXPECTED_PLUGINS[@]}"; do
    if grep -qE "^ *${p} " <<<"$out"; then
        pass "plugin present: $p"
    else
        fail "plugin missing: $p"
    fi
done

echo "[3] no windows/darwin artifacts in image"
out=$(offline sh -c 'find /usr /opt /home -name "*windows*" -o -name "*darwin*" 2>/dev/null')
if [ -z "$out" ]; then
    pass "no foreign-OS files"
else
    fail "foreign-OS files found: $out"
fi

echo "[4] kubectl client version"
out=$(offline kubectl version --client 2>&1)
if grep -q "v${KUBECTL_VERSION}" <<<"$out"; then
    pass "kubectl v${KUBECTL_VERSION}"
else
    fail "kubectl version: $out"
fi

echo "[5] volume-shadow seeding (fresh volume over \$HOME, offline)"
vol="vcfctl-smoke-$$"
docker volume create "$vol" >/dev/null
count=$(docker run --rm --network=none -v "$vol:/home/vcfctl" "$IMAGE" vcf plugin list 2>/dev/null | grep -c installed)
if [ "$count" -eq "${#EXPECTED_PLUGINS[@]}" ]; then
    pass "fresh volume seeded ($count plugins)"
else
    fail "fresh volume: expected ${#EXPECTED_PLUGINS[@]} plugins, got $count"
fi
count=$(docker run --rm --network=none -v "$vol:/home/vcfctl" "$IMAGE" vcf plugin list 2>/dev/null | grep -c installed)
if [ "$count" -eq "${#EXPECTED_PLUGINS[@]}" ]; then
    pass "second run idempotent"
else
    fail "second run: expected ${#EXPECTED_PLUGINS[@]} plugins, got $count"
fi
docker volume rm "$vol" >/dev/null

echo "[6] offline context create fails fast (no plugin-fetch hang)"
if timeout 60 docker run --rm --network=none -e VCF_CLI_VSPHERE_PASSWORD=x "$IMAGE" \
    vcf context create smoke --endpoint https://203.0.113.1 --type k8s \
    --auth-type basic --username smoke@test --insecure-skip-tls-verify >/dev/null 2>&1; then
    fail "context create unexpectedly succeeded"
else
    rc=$?
    if [ "$rc" -eq 124 ]; then
        fail "context create hung (timeout)"
    else
        pass "failed fast with rc=$rc"
    fi
fi

echo "[7] helper scripts respond offline"
for cmd in "supervisor-login --help" "vcfa-login --help" "fetch-ca --help" "vcfctl-help"; do
    # shellcheck disable=SC2086
    if offline $cmd >/dev/null 2>&1; then
        pass "$cmd"
    else
        fail "$cmd"
    fi
done

echo "[8] runs as non-root uid 1000"
uid=$(docker run --rm "$IMAGE" id -u)
if [ "$uid" = "1000" ]; then
    pass "uid=1000"
else
    fail "uid=$uid"
fi

echo
echo "Image size: $(docker images "$IMAGE" --format '{{.Size}}')"
if [ "$fails" -gt 0 ]; then
    echo "SMOKE FAILED: $fails failure(s)" >&2
    exit 1
fi
echo "SMOKE PASSED"
