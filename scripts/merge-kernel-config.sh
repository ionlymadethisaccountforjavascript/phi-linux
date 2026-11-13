#!/usr/bin/env bash
# Merge Phi's kernel config fragments onto a base config.
#
# Debian's kernel config is a fine VM baseline and a poor phone baseline: no
# EAS, no typec altmode, no binderfs, no ramoops. The fragments in config/kernel
# add what convergence and battery work need.
set -euo pipefail

SRC="${KERNEL_SRC:-}"
OUT="build/kernel/.config"
BASE=""
FRAGMENTS=()
DRYRUN=0

usage() {
    cat <<'EOF'
usage: merge-kernel-config.sh --src <kernel tree> [options]

  --src <dir>        clean kernel source tree (or set KERNEL_SRC)
  --base <config>    base config to start from (default: arch defconfig)
  --fragment <file>  fragment to merge (repeatable; default: all of config/kernel/*.fragment)
  --out <path>       output config (default build/kernel/.config)
  --dry-run          print what would be merged

Requires a kernel source tree: fragments are merged with the kernel's own
scripts/kconfig/merge_config.sh, which validates symbols instead of silently
accepting typos (a mistyped CONFIG_ just does not get set).
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)      SRC="$2"; shift 2 ;;
        --base)     BASE="$2"; shift 2 ;;
        --fragment) FRAGMENTS+=("$2"); shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --dry-run)  DRYRUN=1; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$SRC" ]] || { echo "error: --src <kernel tree> or KERNEL_SRC is required" >&2; exit 1; }
[[ -x "$SRC/scripts/kconfig/merge_config.sh" ]] || {
    echo "error: $SRC does not look like a configured kernel tree" >&2
    echo "       (missing scripts/kconfig/merge_config.sh)" >&2
    exit 1
}
if [[ ${#FRAGMENTS[@]} -eq 0 ]]; then
    mapfile -t FRAGMENTS < <(ls config/kernel/*.fragment 2>/dev/null)
fi
[[ ${#FRAGMENTS[@]} -gt 0 ]] || { echo "error: no fragments found in config/kernel/" >&2; exit 1; }

if [[ -z "$BASE" ]]; then
    BASE="$SRC/arch/arm64/configs/defconfig"
    echo "==> base: arch/arm64/configs/defconfig"
else
    echo "==> base: $BASE"
fi
[[ -f "$BASE" ]] || { echo "error: base config not found: $BASE" >&2; exit 1; }

echo "==> fragments:"
printf '    %s\n' "${FRAGMENTS[@]}"
[[ $DRYRUN -eq 1 ]] && { echo "(dry run, nothing written)"; exit 0; }

mkdir -p "$(dirname "$OUT")"
cp "$BASE" "$OUT"

"$SRC/scripts/kconfig/merge_config.sh" -m -O "$(dirname "$OUT")" "$OUT" "${FRAGMENTS[@]}" 2>&1 \
    | sed 's/^/    /'

echo
echo "==> wrote $OUT"
echo "    verify before building:"
echo "      grep -E 'CONFIG_(ENERGY_MODEL|TYPEC|ANDROID_BINDERFS|PSTORE_RAM)=' $OUT"
echo "    then:  make -C $SRC O=$(dirname "$OUT" | xargs dirname) olddefconfig Image"
