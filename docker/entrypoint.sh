#!/usr/bin/env bash
# Seeds baked VCF CLI state from /opt/vcfctl/skel into $HOME, then execs the
# command. $HOME may be the image's writable layer or a user-mounted volume;
# seeding at start makes both behave identically. Idempotent and fast when
# the volume is already seeded at the current version.
set -euo pipefail

SKEL=/opt/vcfctl/skel
MARKER=.vcfctl-version

seed_home() {
    # Plugin state is vendor binaries + caches: safe to replace wholesale on
    # first run or image upgrade.
    rm -rf "$HOME/.local/share/vcf-cli" "$HOME/.cache/vcf"
    mkdir -p "$HOME/.local/share" "$HOME/.cache" "$HOME/.config"
    cp -a "$SKEL/.local/share/vcf-cli" "$HOME/.local/share/"
    cp -a "$SKEL/.cache/vcf" "$HOME/.cache/"
    # Config holds user contexts and settings: never clobber existing files.
    cp -an "$SKEL/.config/." "$HOME/.config/" || true
    cp "$SKEL/$MARKER" "$HOME/$MARKER"
}

if [ ! -w "$HOME" ]; then
    cat >&2 <<'EOF'
[vcfctl] WARNING: $HOME is not writable; the VCF CLI cannot be initialized.
[vcfctl] Run the image as its built-in user with a writable home, e.g.:
[vcfctl]   docker run -it --rm -v vcfctl-home:/home/vcfctl:z ghcr.io/devalexllc/vcfctl
EOF
elif [ ! -f "$HOME/$MARKER" ] || ! cmp -s "$HOME/$MARKER" "$SKEL/$MARKER"; then
    seed_home
fi

mkdir -p "$HOME/.kube" 2>/dev/null || true

# Show the cheat-sheet only for interactive shells started with the default CMD.
if [ -t 0 ] && [ "${1:-}" = "bash" ]; then
    motd.sh || true
fi

exec "$@"
