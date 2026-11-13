# Phi Linux — battery model

"Battery efficient" is a requirement with a number attached, otherwise it is a
vibe. This document defines the number, where the watts go, and how to prove a
change helped.

## 1. The budget

Targets for the reference device (4000-4500 mAh class), measured as battery
percentage per hour with the screen off unless stated:

| Scenario | Target | Unacceptable |
| --- | --- | --- |
| idle, screen off, airplane mode | ≤ 0.7 %/h | > 2 %/h |
| idle, screen off, LTE standby | ≤ 1.5 %/h | > 3 %/h |
| idle, screen off, Wi-Fi + notifications | ≤ 2.0 %/h | > 4 %/h |
| screen on, reading, 150 nits | ≤ 10 %/h | > 16 %/h |
| docked, external display, idle | mains power — no target | — |

A phone that loses 20 % overnight is broken regardless of how good the desktop
mode is. These are the numbers that decide whether Phi is usable.

## 2. Where the power goes

Typical mainline-Linux phone distribution, in rough order of magnitude — treat
these as a map of *where to look*, not as values to quote:

| Load | Idle cost | Scales with |
| --- | --- | --- |
| Modem (standby, paging) | 10-40 mW | signal quality, network mode |
| Wi-Fi (associated, powersave off) | 20-80 mW | beacons missed, DTIM, latency needs |
| Display panel (on) | 150-800 mW | brightness, refresh rate, content |
| SoC idle (clusters not collapsing) | 20-200 mW | cpuidle depth, wakeup rate |
| DRAM in self-refresh | 5-30 mW | memory size, suspend state |
| GPU (idle clock left high) | 5-50 mW | devfreq governor |
| Sensors / always-on subsystems | 5-20 mW | polling intervals |
| Userspace wakeups | variable | *anything* waking every 100 ms |

The first four rows are where the wins are. Userspace tweaks are worth single
digits of a percent in comparison — which is why `docs/ARCHITECTURE.md` puts
the panel-off-when-docked behaviour ahead of every governor tuning.

## 3. Levers, in priority order

### 3.1 Kill userspace wakeups first

A process waking the CPU every 100 ms costs more than a governor change and is
invisible in `top`. Before tuning anything:

```sh
# who is waking the system
sudo powertop --auto-tune     # try it, then *review* what it changed
sudo cat /sys/kernel/debug/wakeup_sources | sort -k6 -n -r | head -20
```

Common offenders on a Linux phone: `upowerd` (change it to event-driven),
`ModemManager` polling, `powerdevil` at 30 s intervals (acceptable),
NetworkManager scanning for Wi-Fi when not connected (set the scan interval),
and any Electron/Flatpak app left running.

### 3.2 CPU: EAS must actually be active

This is a **silent** failure. The kernel boots fine without an energy model; it
just never picks the small cores.

```sh
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor   # expect schedutil
ls /sys/kernel/debug/energy_model/                             # expect per-cpu entries
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
```

If `energy_model` is empty, `capacity-dmips-mhz` is missing from the device
tree. Fix the DT, not the governor: a `performance` governor workaround will
cost you 2-3× the battery.

Per-posture EPP, applied by `phi-moded`:

| Posture | governor | EPP | Why |
| --- | --- | --- | --- |
| phone | `schedutil` | `power` | minimise watts; UI is not latency-critical at idle |
| desktop | `schedutil` | `balance_performance` | a desktop UI spikes hard on window drags |

### 3.3 Idle: get the clusters to collapse

```sh
cpuidle-info                             # or: cat /sys/devices/system/cpu/cpu0/cpuidle/state*/usage
```

Deep idle states must be entered a lot, and the deepest must not be blocked.
Blockers show up as a nonzero `cpu_dma_latency` PM-QoS constraint held by a
driver or by a userspace process (`powerdevil` historically held one).

### 3.4 Suspend: s2idle, and know why it fails

```sh
cat /sys/power/state                     # expect "freeze mem" (use freeze)
cat /sys/power/suspend_stats/{success,fail,last_failed_dev}
echo freeze | sudo tee /sys/power/state  # test manually
```

Typical mainline blockers, in the order they bite: modem remoteproc refusing
to suspend, Wi-Fi WoWLAN misconfiguration, a touchscreen or USB-C PD interrupt
declared as a wakeup source, and a sensor hub without a proper driver. Each is
a per-device fix; `scripts/power-report.sh` prints the suspend counters and the
busiest wakeup sources so the hunt has a starting point.

### 3.5 Wi-Fi power save is a posture, not a constant

Phone mode: `iw dev wlan0 set power_save on` (missed beacons cost latency the
user does not perceive while the screen is off).
Desktop mode: off, because a remote session or SSH with 300 ms of added jitter
is worse than the watts. `phi-moded` applies exactly this from `moded.toml`.

### 3.6 Docked mode is about longevity, not watts

Docked means mains power, so the constraint changes from energy to **battery
wear and heat**:

- the phone panel goes off (`apply-mode.sh`, `PHI_SCREEN_OFF_WHEN_DOCKED=1`)
- charge capped at 80 % by the docked hook — a battery held at 100 % and 30 °C
  for eight hours a day is the fastest way to lose 20 % of capacity in a year
- the external display is the dominant load; prefer 60 Hz and DPMS the output
  when idle rather than cranking output scaling

## 4. Measurement protocol

Numbers only count if they are comparable. The protocol:

```sh
# 1. settle
sudo systemctl isolate phi-phone.target     # known posture
# screen off, airplane mode, unplugged, 30 min settle

# 2. sample for an hour, machine readable
scripts/power-report.sh --csv --watch 60 >> /tmp/idle-$(date +%F).csv

# 3. read the delta
awk -F, 'NR==1{p=$2} END{print (p-$2) " % over " (($1-s)/3600) " h"}' s=<first ts> /tmp/idle-*.csv
```

Rules that make the result trustworthy:

- same starting charge (±2 %), same ambient temperature, same SIM state
- ≥ 60 minutes, because the first minutes after boot are not steady state
- one change at a time
- record the kernel config hash and the commit; a kernel bump invalidates every
  previous number

## 5. Regression gate

A change that moves idle drain by more than +0.3 %/h does not land, regardless
of what it fixes elsewhere, unless it is fixing a broken boot. This is the same
principle as a performance budget in a web project: the number is the review
criterion, not an afterthought.

## 6. Things that look like optimisations and are not

| "Optimisation" | Why it is wrong |
| --- | --- |
| `performance` governor to fix UI stutter | fixes the symptom, doubles idle draw; fix EAS instead |
| running `tlp` and `powerdevil` together | two writers to the same sysfs knobs, undefined result |
| disabling `s2idle` because resume is flaky | you just moved the bug to "drains while asleep" |
| zram with a huge `swappiness` | compressing everything burns CPU; keep it for pressure, not for fun |
| turning off Bluetooth/Wi-Fi *always* | the user's phone stops being a phone |
| `powertop --auto-tune` in a systemd unit | it enables aggressive USB autosuspend that breaks input devices; review what it does |
