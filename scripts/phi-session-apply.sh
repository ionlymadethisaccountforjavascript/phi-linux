#!/usr/bin/env bash
# Apply the current Phi posture inside the Plasma session.
#
# Runs as the logged-in user (systemd --user unit), triggered by a path unit
# watching /run/phi/mode-state.json. It is the only place that talks to the
# compositor, because kscreen-doctor needs the session bus and XDG_RUNTIME_DIR.
#
# Two things happen here:
#   1. output layout: enable the external display, and *power off the phone
#      panel* while docked (a 6" AMOLED at 50% is one of the biggest drains)
#   2. optional shell handoff between Plasma Mobile and Plasma Desktop
set -uo pipefail

STATE="${PHI_STATE_FILE:-/run/phi/mode-state.json}"
INTERNAL_PREFIXES="DSI eDP LVDS DPI"

log() { printf '[phi-session] %s\n' "$*"; }

[[ -r "$STATE" ]] || { log "no state file at $STATE yet"; exit 0; }

mode="$(python3 - "$STATE" <<'PY' 2>/dev/null || echo phone
import json,sys
print(json.load(open(sys.argv[1])).get("mode","phone"))
PY
)"
log "mode=$mode"

# --- discover connected connectors straight from the kernel ------------------
drm_root="${PHI_DRM_ROOT:-/sys/class/drm}"
external=()
internal=()
for d in "$drm_root"/card*-*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"; name="${name#*-}"
    [[ "$(cat "$d/status" 2>/dev/null)" == "connected" ]] || continue
    is_internal=0
    for p in $INTERNAL_PREFIXES; do [[ "$name" == "$p"* ]] && is_internal=1; done
    if [[ $is_internal -eq 1 ]]; then internal+=("$name"); else external+=("$name"); fi
done
log "internal: ${internal[*]:-none}  external: ${external[*]:-none}"

# --- output layout ----------------------------------------------------------
if command -v kscreen-doctor >/dev/null 2>&1; then
    case "$mode" in
        desktop)
            for out in "${external[@]:-}"; do
                [[ -n "$out" ]] || continue
                # preferred mode, primary, left of the phone panel
                kscreen-doctor "output.$out.enable" "output.$out.primary" \
                               "output.$out.position.0,0" 2>/dev/null \
                    && log "enabled $out as primary"
            done
            if [[ "${PHI_SCREEN_OFF_WHEN_DOCKED:-1}" == "1" ]]; then
                for out in "${internal[@]:-}"; do
                    [[ -n "$out" ]] || continue
                    kscreen-doctor "output.$out.disable" 2>/dev/null \
                        && log "panel $out off (saves battery while docked)"
                done
            fi
            ;;
        phone)
            for out in "${internal[@]:-}"; do
                [[ -n "$out" ]] || continue
                kscreen-doctor "output.$out.enable" "output.$out.primary" 2>/dev/null \
                    && log "enabled $out"
            done
            for out in "${external[@]:-}"; do
                [[ -n "$out" ]] || continue
                kscreen-doctor "output.$out.disable" 2>/dev/null \
                    && log "disabled $out"
            done
            ;;
    esac
else
    log "kscreen-doctor not found; skipping output layout"
    # wlroots-based shells (sway, a custom compositor) would use wlr-randr here
fi

# --- shell handoff ----------------------------------------------------------
# Restarting plasmashell swaps the shell (panel, launcher, homescreen) between
# the mobile and desktop variants. Application windows are children of KWin,
# not plasmashell, so they survive the restart -- this is why a full "shell
# switch" is cheaper than it looks. It is still visibly a restart: expect a
# flash and a task list that reorders.
switch_shell() {
    local script="$1"
    command -v qdbus >/dev/null 2>&1 || command -v qdbus6 >/dev/null 2>&1 || return 1
    local qdbus; qdbus="$(command -v qdbus6 || command -v qdbus)"
    "$qdbus" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$script" 2>/dev/null
}

if [[ "${PHI_SWITCH_SHELL:-0}" == "1" ]]; then
    case "$mode" in
        desktop)
            log "switching to the desktop shell"
            switch_shell 'panels()[0].height = 32' \
                || log "shell handoff failed; staying on the mobile shell"
            ;;
        phone)
            log "switching to the mobile shell"
            switch_shell '' \
                || log "shell handoff failed"
            ;;
    esac
else
    log "shell handoff disabled (PHI_SWITCH_SHELL=0); Kirigami apps adapt on their own"
fi

exit 0
