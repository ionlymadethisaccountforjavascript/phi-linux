#!/usr/bin/env bash
# Live power state of a Phi Linux device.
#
# Exists so battery work is measurement-driven: every claim about "efficient"
# has to show up as fewer milliamps at the same screen brightness and workload.
# Run in phone mode, then docked, and diff the two.
set -uo pipefail

WATCH=0
TOP=5
CSV=0

usage() {
    cat <<'EOF'
usage: power-report.sh [--watch <seconds>] [--top <n>] [--csv]

  --watch <s>   repeat every s seconds
  --top <n>     show the n busiest wakeup sources (default 5)
  --csv         one machine-readable line per sample (for logging regressions)
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH="$2"; shift 2 ;;
        --top)   TOP="$2"; shift 2 ;;
        --csv)   CSV=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

r() { [[ -r "$1" ]] && cat "$1" 2>/dev/null | head -1 | tr -d '\n'; }

# microvolts/microamps -> human
fmt_ua() { awk -v v="$1" 'BEGIN{ if (v=="") print "n/a"; else printf "%+.0f mA", v/1000 }'; }
fmt_mhz() { awk -v v="$1" 'BEGIN{ if (v=="") print "n/a"; else printf "%d MHz", v/1000 }'; }

battery_supply() {
    for d in /sys/class/power_supply/*/; do
        [[ "$(r "$d/type")" == "Battery" ]] && { echo "${d%/}"; return; }
    done
}

row() { printf '  %-22s %s\n' "$1" "$2"; }

main_report() {
    local bat cap status cur volt power
    bat="$(battery_supply)"

    if [[ -n "$bat" ]]; then
        cap="$(r "$bat/capacity")"; status="$(r "$bat/status")"
        cur="$(r "$bat/current_now")"; volt="$(r "$bat/voltage_now")"; power="$(r "$bat/power_now")"
        local watts="n/a"
        if [[ -n "$power" && "$power" != "0" ]]; then
            watts="$(awk -v p="$power" 'BEGIN{printf "%.2f W", p/1000000}')"
        elif [[ -n "$cur" && -n "$volt" ]]; then
            watts="$(awk -v i="$cur" -v v="$volt" 'BEGIN{printf "%.2f W", (i/1000000)*(v/1000000)}')"
        fi
        echo "battery"
        row "charge" "${cap:-?}%  ${status:-?}"
        row "current" "$(fmt_ua "$cur")"
        row "voltage" "$(awk -v v="$volt" 'BEGIN{ if(v=="") print "n/a"; else printf "%.2f V", v/1000000 }')"
        row "power" "$watts"
    else
        echo "battery: no power_supply device (VM or desktop host)"
    fi

    echo
    echo "cpu"
    local gov epp cur_f of
    local policies=(/sys/devices/system/cpu/cpufreq/policy*/)
    if [[ -e "${policies[0]}" ]]; then
        for p in "${policies[@]}"; do
            gov="$(r "$p/scaling_governor")"; epp="$(r "$p/energy_performance_preference")"
            cur_f="$(r "$p/scaling_cur_freq")"
            printf '  %-22s %s  %s  %s\n' "$(basename "$p")" "$gov" "${epp:-epp:n/a}" "$(fmt_mhz "$cur_f")"
        done
    else
        echo "  no cpufreq policies exposed"
    fi

    echo
    echo "gpu / devfreq"
    local found=0
    for d in /sys/class/devfreq/*/; do
        [[ -d "$d" ]] || continue
        found=1
        printf '  %-22s %s  %s\n' "$(r "$d/name")" "$(r "$d/governor")" "$(fmt_mhz "$(r "$d/cur_freq")")"
    done
    [[ $found -eq 0 ]] && echo "  no devfreq devices"

    echo
    echo "thermal"
    local tz t
    for tz in /sys/class/thermal/thermal_zone*/; do
        t="$(r "$tz/temp")"
        [[ -z "$t" ]] && continue
        printf '  %-22s %.1f C\n' "$(r "$tz/type")" "$(awk -v x="$t" 'BEGIN{print x/1000}')"
    done 2>/dev/null | head -8

    echo
    echo "suspend"
    local sp=/sys/power/suspend_stats
    row "success" "$(r "$sp/success")"
    row "fail" "$(r "$sp/fail")"
    row "last failed device" "$(r "$sp/last_failed_dev")"
    row "mem sleep supported" "$(grep -qw mem /sys/power/state 2>/dev/null && echo yes || echo no)"
    row "s2idle supported" "$(grep -qw freeze /sys/power/state 2>/dev/null && echo yes || echo no)"

    echo
    echo "convergence"
    local conn=0 name st
    for d in /sys/class/drm/card*-*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"; st="$(r "$d/status")"
        [[ -z "$st" ]] && continue
        case "$name" in
            *DSI*|*eDP*|*LVDS*|*DPI*|*Writeback*) continue ;;
        esac
        printf '  %-22s %s\n' "$name" "$st"
        [[ "$st" == "connected" ]] && conn=1
    done
    row "external display" "$([[ $conn -eq 1 ]] && echo connected || echo none)"
    for p in /sys/class/typec/port*/; do
        [[ -d "$p" ]] || continue
        row "typec $(basename "$p") data_role" "$(r "$p/data_role")"
    done

    echo
    echo "top $TOP wakeup sources"
    local w
    for w in /sys/class/wakeup/*/; do
        [[ -r "$w/active_count" ]] || continue
        printf '%s\t%s\n' "$(cat "$w/active_count" 2>/dev/null)" "$(r "$w/name")"
    done 2>/dev/null | sort -rn | head -"$TOP" | awk -F'\t' '{printf "  %-32s %s\n", $2, $1}'
}

csv_line() {
    local bat cap cur volt
    bat="$(battery_supply)"
    cap="$(r "$bat/capacity")"; cur="$(r "$bat/current_now")"; volt="$(r "$bat/voltage_now")"
    printf '%s,%s,%s,%s,%s\n' "$(date +%s)" "${cap:-}" "${cur:-}" "${volt:-}" "$(r /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)"
}

if [[ $WATCH -eq 0 ]]; then
    [[ $CSV -eq 1 ]] && { csv_line; exit 0; }
    printf '\033[1mPhi power report\033[0m  %s\n\n' "$(date '+%F %T')"
    main_report
    exit 0
fi

while :; do
    if [[ $CSV -eq 1 ]]; then
        csv_line
    else
        clear 2>/dev/null || true
        printf '\033[1mPhi power report\033[0m  %s  (ctrl-c to stop)\n\n' "$(date '+%T')"
        main_report
    fi
    sleep "$WATCH"
done
