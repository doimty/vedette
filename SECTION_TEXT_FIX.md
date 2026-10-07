# ui3 section text overlap → ui4

## Evidence / hypothesis

User screenshots photo_466BD33B, photo_0CADA733 and photo_49E1C66D show doubled section titles and footers on detail, applications and root; ordinary rows and the new Action selection row are not doubled. ui3 source/build: 4ac149755d093995ce2b14f7971d8299d4df41ce, run37641593227.

The new VDTCompactSectionLabel subclasses UITableViewHeaderFooterView and adds its own caption. All five controllers provide viewForHeader/Footer but retain inherited titleForHeader/Footer. The base view's textLabel/detailTextLabel are not suppressed. Pinned AltList forwards title methods to PSListController; retaining source name/footerText plus the custom caption leaves two text owners. This fits the screenshots. No runtime view hierarchy was captured, so exact framework assignment timing is not asserted.

## Minimal correction

- The five custom-section controllers return nil from both titleForHeaderInSection and titleForFooterInSection; no optional super calls. Keep specifier names/footerText intact because the custom caption uses them.
- Only inside VDTCompactSectionLabel, hide/clear and disable accessibility for the two legacy built-in labels at layout after super. Do not hide arbitrary subviews, touch row labels or modify system appearance.
- Preserve the custom caption's text, accessibility, dynamic font and complete automatic-height constraints. No changes to compact row heights, process selection, search/grouping or CPU logic.
- Release ui4; ui3 is not recommended. No device install/restart.

## Validation / independent failure signals

- Before patch source regression must reject real ui3 controllers and custom view.
- After patch all five own the nil title path; actual suppression body should survive simulated framework repopulation/reuse without hiding the caption.
- Retain previous compact6/action5/UI9/lifecycle2, list/CPU C/auto-monitor tests and package markers; inspect actual compiled nil-return/suppression methods if possible.
- Original specifier/footer strings and read/write functions must remain unchanged. CPU file set frozen to ui2.
- Still requires device retest: static or mocked UIKit cannot prove final display. If duplicate text remains, inspect actual hierarchy rather than reducing line height or deleting help.

## Why previous tests missed it

They checked custom caption constraints and geometry, not inherited data-source titles or UIKit's built-in header labels. HTML only rendered one label and could not expose this UIKit interaction. A successful compiler/source test was not a device rendering pass.
