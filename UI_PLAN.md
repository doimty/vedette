# Vedette modern preferences plan

Baseline: d54fc36cb03e75fbe8699099abc747199ae570b6 (1.1.10), branch feat/localized-modern-prefs.

## Scope and assumptions
- User requests enabled items pinned at top, UI localization, new settings design inspired by Kayoko/Pullover X from mlgm66.github.io.
- Treat enabled as stored per-process switch, independent of global master switch; never label as verified runtime monitoring.
- Both app and daemon lists should group enabled items first, retain searching, stable alphabetic order within groups, and refresh after changing a rule/returning.
- Use zh-Hans + English fallback. Identifiers/process names, product names and URLs are not translated.
- Native Preferences/UIKit, iOS15+ dynamic colors and accessible type; no continuous animations, network UI, new permission, or CPU daemon behavior changes.
- Original visual implementation; reference author's settings pages only, no copying unlicensed code/assets.
- 2026-10-07: user authorized commit/push and roothide cloud build on the new branch. Version 1.1.10-1+ui1; release metadata/workflow and its checks may change. No device install/restart or source-repository publication authorized.

## Work ownership
- Parent: root/process settings UI, shared styling/localization, English/Chinese resources, plan/report.
- List subagent: daemon/application list controllers and enabled partition helpers/tests, pinned AltList source inspection. No root/process/shared locale resource changes.
- Reference subagent: external UI research only; outside repository.

## Success criteria
1. Enabled groups first; each item appears once; search filters both groups; returning rebuilds order.
2. Empty/all-enabled/all-disabled/duplicate/malformed settings fixtures fail safely; global off doesn't reorder all to disabled.
3. Every authored UI label/footer/prompt uses bundle localization; format placeholders match; process identity keys unchanged.
4. Native header and cards adapt dark/light, narrow screens and Dynamic Type; no global appearance leakage.
5. Existing identity, policy and auto-monitor tests unchanged and pass; runtime/config serialization/filter/scripts byte-identical to baseline.

## Independent failure signals
- Enabled row remains below disabled row, duplicate rows, lost query, wrong config identifier, stale order after toggle.
- UI shows enabled as proof of kernel enforcement, changes policy defaults, or touches daemon/runtime code.
- Missing zh-Hans key, English placeholder mismatch, fixed huge logo/clipped labels, unreadable dark mode.

## Verification
Execute host tests and new list/localization tests; source invariants and git diff --check. Inspect preview when available, explicitly not native iOS proof. No Xcode runtime here; actual iOS build and navigation remain outstanding until authorized cloud build/device validation.
