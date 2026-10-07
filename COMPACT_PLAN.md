# Compact UI candidate and CPU efficiency review

Project status and later CPU/features: [ROADMAP.md](ROADMAP.md). The compact UI and native action-selection row are already implemented locally; their next step is build/device validation, not another redesign. Future roadmap items are documentation only, not placeholder runtime code.

Base: ui2 `cd0b34807c031d2e179f1ae397ea8c6847be35e3` (user confirmed home, app and daemon lists work).

## Scope
- User asks whether CPU/efficiency can improve: read-only CPU audit first, not automatic tighter throttling, no new sampling/IPC/timers.
- Current authorization: push the compact UI on `feat/compact-prefs`; ui4 includes the observed ui3 section-overlap fix and user-requested own package/Bundle IDs. Preserve legacy rule/notification compatibility, see PACKAGE_IDENTITY.md and SECTION_TEXT_FIX.md. No device install/restart, APT publication or CPU-feature implementation. Keep stable ui2 intact.

## Hypothesis
The header has 20pt top/bottom padding and 48pt icon; native section spacing and standard Preferences row sizes produce the visible blank space. Setting only estimatedRowHeight would not change real row heights. Use explicitly scaled compact rows and small automatic-size section labels without negative content insets or forcing all cells to a clipping fixed height.

## Design
- Header padding 20→12pt, icon48→40pt, title22→20pt. Keep complete Auto Layout and automaticDimension; no manual width/height guesses.
- Ordinary row target44pt at default type size, scaled up with Dynamic Type; never smaller than44pt. Ordinary row title single line with ellipsis; full process name/identifier retained in the detail header and accessibility label.
- Preserve special header automatic height and native edit-field height. After user's detail-screen feedback, replace the standalone large segment with PSLinkListCell + the existing PSListItemsController: a compact Action/current value/disclosure row in the Limits group. Keep enum values, defaults, getters, setters and both help paragraphs unchanged.
- Custom local reusable header/footer views measure multiline text through Auto Layout. Empty top/group spacers8/12pt, no negative safe-area/nav insets. Retain all translations and caution text.
- Keep cell styling in required cellForRowAtIndexPath, never reintroduce optional willDisplayCell super call. No global UIAppearance or new dependency.

## Success / failure signals
- All5 pages use same compact section layout, no new unknown super selector.
- Default rows >=44pt, large type does not shrink and header/footer text not clipped.
- App/daemon enabled-first, search state, original IDs/defaults/save actions unchanged.
- CPU source, filter, package metadata, scripts, workflow and existing tests unchanged; freeze checked against ui2.
- Fail: source touched outside stated UI scope, static metrics nonfinite or <44, negative inset workaround, lost warning/localization, old optional selector returning.

## Verification
Production metric pure-C fixtures, negative controls, source/resource/lifecycle contracts, original identity/policy/list suites. Independently review UIKit integration. HTML density preview can demonstrate intent only, not native rendering. Actual iOS layout remains unverified until user-authorized cloud build and device testing.
