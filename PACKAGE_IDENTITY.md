# Own package and settings Bundle IDs (ui4)

User requested own Bundle ID while ui3 section-overlap fix was in progress.

| Surface | ui3 / old | ui4 |
|---|---|---|
| Debian package identifier | com.udevs.vedette | com.doimty.vedette |
| Settings CFBundleIdentifier | com.udevs.vedetteprefs | com.doimty.vedetteprefs |
| Maintainer | udevs | doimty |
| Original Author | udevs | udevs (preserved) |

## Compatibility, not a rule migration

- Old preference domain, file paths and Darwin notification names remain unchanged in Common.h/VDTShared/Vedette.xm, deliberately retaining existing rules and restore snapshots. They are an internal compatibility contract, not the new public bundle/package ID.
- BUNDLE_NAME/executable/load paths remain VedettePrefs/Vedette; PreferenceLoader and other existing loaders continue using the same bundle path. There is not an extra Preferences entry or second injected dylib.
- Conflicts + Replaces: com.udevs.vedette. The package manager must replace/remove the old package rather than installing both over the same payload. No manual deletion of user rules.
- Existing installation/removal scripts are byte-identical (they restart runningboardd); they contain no preference deletion. This workflow does not install or execute them on the device.
- Author attribution and licenses remain intact. No unrelated changes to upstream documentation URLs.

## Verification

`test_package_identity.py` validates control/Info identity, replacement declarations, and unchanged rule channels/loader paths. `test_compact_ui.py` only permits the single CFBundleIdentifier substitution in Info.plist. Real deb validation checks the packaged Info.plist and package control.

A separate local dpkg --root temporary database with inert text payloads and no maintainer scripts successfully replaced the synthetic old package with the new ID and preserved an unowned legacy preference fixture. This validates dpkg conflict/replacement semantics, not an iOS package manager transaction or runtime recovery.

No new CPU feature is part of ui4; existing disabled-rule/restore limitations are not solved by changing IDs. The section overlap fix is documented in SECTION_TEXT_FIX.md. The new bundle ID is not a claim of new functionality.
