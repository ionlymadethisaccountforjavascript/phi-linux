# Posture hooks

`phi-moded` runs every executable file in these directories when it switches
mode, sorted by filename (`10-`, `20-` ...). Files that are not executable are
ignored, which is what the `.sample` files here rely on.

| directory | runs when |
| --- | --- |
| `enter-desktop.d/` | the device becomes docked / a display attaches |
| `leave-desktop.d/` | the device returns to phone posture |

## Contract

```
PHI_MODE=desktop|phone     the posture being entered
PHI_REASON=dock-detected|dock-removed|override:manual|boot
```

- Exit `0` for success. A non-zero exit is logged and **does not** abort the
  switch: a broken hook must not leave the user stuck in the wrong posture.
- Hooks run as **root**, from systemd, with a minimal environment. They are for
  system-level changes (kernel knobs, service toggles, charging limits).
- For anything that needs the compositor, the session bus or `XDG_RUNTIME_DIR`,
  use the user-side unit instead (`systemd/user/phi-session-mode.path` ->
  `scripts/phi-session-apply.sh`). A root hook calling `kscreen-doctor` will
  silently do nothing; this is the most common mistake here.
- Keep hooks fast. The target isolation completes before they run, so a hook
  that sleeps delays the visible switch.

## Enabling a sample

```sh
install -m 755 hooks/enter-desktop.d/10-charge-limit.sample \
               /usr/lib/phi/moded/hooks/enter-desktop.d/10-charge-limit
```
