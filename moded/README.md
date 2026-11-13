# phi-moded

The mode manager: decides whether the device is a phone or a desktop, and moves
the system between the two.

```
phi_moded/
  config.py    moded.toml -> dataclasses (stdlib tomllib, no deps)
  detect.py    sysfs: DRM connectors + USB-C altmode  -> DockState
  policy.py    debounce + override -> Decision        (pure, no I/O)
  actions.py   systemd targets, hooks, cpufreq knobs
  notify.py    sd_notify (READY/WATCHDOG/STATUS)
  main.py      daemon loop + CLI
```

## Why poll sysfs

sysfs has no inotify, and DRM hotplug events are only visible on a netlink
socket that the compositor already owns. Polling three or four small files
every two seconds costs effectively nothing, and the udev rule
(`udev/99-phi-drm.rules`) sends `SIGHUP` so real docks are picked up
immediately instead of waiting out the interval. If the polling ever shows up
in a power trace, move to `NETLINK_KOBJECT_UEVENT` — the interface in
`detect.py` is the seam for that change.

## Install layout

```
/usr/bin/phi-moded -> /usr/lib/phi/moded/phi-moded
/usr/lib/phi/moded/phi_moded/*.py
/etc/phi/moded.toml
/usr/lib/systemd/system/{phi-moded.service,phi-phone.target,phi-desktop.target}
/usr/lib/systemd/user/{phi-session-mode.path,phi-session-mode.service}
/usr/lib/udev/rules.d/99-phi-drm.rules
/usr/lib/phi/session/apply-mode.sh
/usr/lib/phi/moded/hooks/{enter-desktop.d,leave-desktop.d}/
```

There is no `make install` yet: until P1 on real hardware, the files are copied
by hand so it stays obvious what the OS is made of.

## Commands

```sh
phi-moded status                      # posture, connectors, override
phi-moded set desktop --ttl 3600      # force, with expiry
phi-moded clear
phi-moded run --once --dry-run        # one evaluation, no changes
phi-moded run --dry-run               # full loop, log only
```

## Tests

```sh
make test            # from the repo root
python3 -m unittest discover -s moded/tests -t moded -v
```

The suite runs with no phone and no root: sysfs is replaced by a fixture tree
(`--simulate`), `systemctl` by a recording double, and the policy is tested as
a pure function of (time, docked, override).
