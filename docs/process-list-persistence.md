# Process List Persistence And Reconciliation

Status: implementation candidate on feature/process-list-reconciliation; host tests are local, Apple package build and device behavior are pending.

## Decision

Vedette persists stable rules, not process IDs. The existing preferences plist remains authoritative for app bundle identifiers, daemon names, enabled state, CPU policy, percentage, and interval. PIDs, process handles, and the process-to-rule index are runtime state only.

At runningboardd startup, after a preference reload, and after a process-table change, Vedette enumerates current processes and rebuilds the in-memory PID-to-rule view. Each cached live entry includes PID, kernel process start time, stable app/daemon identity, and rule signature. The cache is never written to disk. Process start time prevents a reused PID from inheriting a prior process's cache entry.

## Process change delivery

The old Darwin notification stored one PID in notification state. That is a single shared slot, so concurrent process starts could overwrite/coalesce payloads and leave a matching process unhandled.

The new notification carries no PID. It is only a hint that the process table may have changed. The runningboardd listener coalesces callbacks onto the existing serial queue and rescans the live process table. Coalescing is safe because the scan observes the current set rather than relying on delivery of each PID event. The listener is registered before the initial scan to close the startup gap.

A full rescan may encounter already-managed processes. The in-memory start-time/identity/rule-signature cache suppresses duplicate CPU syscalls. Config reloads force a single scan, restore old managed settings for still-live matching processes, clear the runtime cache, and apply the newly resolved rules.

## Fail-closed rule application

A CPU action requires all of the following:

- Global monitoring is enabled (missing global key retains the existing default-on behavior; malformed values disable action).
- The current live process resolves to a stable identity with a stored rule.
- That rule is enabled.
- The policy is exactly Monitor-and-terminate or Throttle.
- Percentage is positive; Monitor-and-terminate also requires a positive interval.

Unmatched, unresolved, disabled, malformed, and unknown-policy processes do not receive a new action. The previous implicit default of Monitor-and-terminate for any reported PID is removed. On config reload, previously managed constraints are restored before applying the new policy; reset/uninstall restoration continues to use the saved preferences snapshot.

When switching between Monitor-and-terminate and Throttle, the opposite mechanism is cleared before applying the requested one. None restores both mechanisms for a currently matched configured process.

## PID enumeration contract

proc_listpids reports byte counts. The implementation allocates a pid_t buffer with checked multiplication, retries a bounded number of times if the process table fills the buffer, rejects invalid/short/error results, and iterates only returnedBytes / sizeof(pid_t) entries. Allocation and lookup failures fail closed. PID identity is re-read immediately before applying an action; delayed notification payloads no longer exist.

## Recovery

- runningboardd startup force-rebuilds from the durable preferences file.
- Preference changes force-reconcile the current live process set.
- Process-table notifications trigger a coalesced reconciliation against a live PID snapshot.
- Reset/uninstall restoration uses the saved old preferences and validates process identity before clearing limits.
- No PID list is persisted, so stale PIDs cannot survive a reboot or be reused as durable targets.

## Tests

The process_persistence test compiles the PID-list and rule-policy helpers as C11 with warnings as errors, covering byte conversion, malformed sizes, allocation overflow, truncation/retry, unmatched processes, disabled rules, invalid policies, and valid monitor/throttle decisions. It also enforces the runtime event, identity, startup-rebuild, and restoration contracts.

The roothide workflow runs these host contracts before the Apple package build on this branch. The current Linux host cannot run Xcode/Theos; CI and a jailbroken-device run are still required before release or runtime claims.

## Scope boundaries

This change does not alter the preference UI, persisted rule schema, CPU thresholds, violation policy UI, process filter, package version, or the meaning of the stored settings. It does not claim a durable process list; it makes process state recoverable by rebuilding it from durable rules and the OS live process table.
