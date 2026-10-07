# ui1 iOS 15.1.1 Preferences crash → ui2 fix

## Evidence

User installed `1.1.10-1+ui1` from successful run 37578064632 (commit 3b2182c). Preferences crashed while opening the settings page on iOS15.1.1.

The crash's VedettePrefs arm64e UUID is `25F8556C-5D99-3822-A4A1-E0C99C592789`, matching the actual downloaded build. The last exception trace is `doesNotRecognizeSelector:` → VedettePrefs return offset `0x85a4` → UITableView cell preparation. At `0x85a0` the binary calls `objc_msgSendSuper2`. ARM64E_USERLAND24 chained references decode the class as VDTRootListController and selector as `tableView:willDisplayCell:forRowAtIndexPath:`.

This is the new UI's unconditional super call to an optional delegate method not implemented by the parent in this device environment, not evidence of a CPU-policy fault. VM resource-shortage notes do not override the concrete exception call chain.

## Minimal fix / success criterion

Move styling in Root/Process/About controllers into `tableView:cellForRowAtIndexPath:`, call the existing parent cell factory, apply VDTStyleCell, return the same cell. Keep all layout, grouping, localization, settings and CPU code otherwise unchanged. Set new version `1.1.10-1+ui2` because ui1 was already installed.

Independent failure signal: any of the three controllers still sends optional willDisplayCell to super, or the built UI binary retains that selector. Add source red/green checks using the exact crashing commit as negative control, and reject the selector in the real deb resource validator.

## Validation boundary

- Before fix, the new source test rejected all three current controllers; the crashing baseline is retained as a negative control.
- After fix, all three must use the required UITableViewDataSource cell factory and preserve return value.
- Host/source tests and an iOS build cannot prove the whole preferences UI works on a device. User retest is required for opening home/detail/about, searching and pinning.
- Earlier source review and build succeeded because an optional protocol method can compile without an implementation in the actual superclass. This failure was not covered by those tests. ui1 is superseded and is not the recommended package.

No user device identifiers or raw crash log are committed. No device install/restart is executed by this workflow.
