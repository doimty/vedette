# Best-effort uninstall (1.1.12-3)

A kernel nice value belongs to a running process. When the process exits, is
replaced, or the device reboots, that value is gone on its own. Vedette must
therefore not be able to block `dpkg` forever because it cannot hand a value
back at that exact moment.

## What changed

- `prerm` still asks `vedette-nicectl restore-for-removal` to hand managed
  processes back, but a failure is now a warning: `dpkg` continues and the
  package is removed.
- `postinst` resume is advisory in the same way, so a control failure can no
  longer leave the package half-configured.
- Both environments (roothide and rootless) behave identically.
- The journal and a failed `restore-request.plist` are never deleted by these
  scripts. Recovery evidence stays on disk for later inspection.

## What deliberately did not change

- Applying, updating and removing a nice value inside the daemon still
  revalidates PID lifetime, executable path and readback, and still refuses to
  overwrite a value changed by something else.
- The in-app rule workflow still reports `conflict`, `verify-failed` and
  `store-failed` instead of claiming success.
- No global `.jbroot` link, no blanket `exit 0` for a corrupted store, and no
  silent journal deletion were added. The tool still reports the real errno.

## Residual risk

A removal that happens while Vedette is still adjusting processes may leave a
temporary limit or priority on a live process until it exits. That is bounded
by process lifetime and by a reboot, and it is the accepted trade-off for not
wedging package management.
