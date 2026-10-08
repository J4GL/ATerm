# App — application bundle

`scripts/bundle.sh` (run by `make app`) builds the release executable and
assembles `build/ATerm.app` with `Resources/Info.plist` and
`Resources/AppIcon.icns`, then signs it ad hoc so it runs on Apple silicon.
`scripts/make-icon.sh` (`make icon`, and `make app` when the logo is newer than
the icns) builds the icns from the logo `Resources/Logo.png`.

## APP-BUNDLE-001 — make app produces a signed, launchable ATerm.app

Implement: `scripts/bundle.sh`, `Resources/Info.plist`, `Resources/AppIcon.icns` and the `--version` flag of `Sources/ATerm/main.swift`.

Test: e2e · `scripts/test-bundle.sh` · "APP-BUNDLE-001 make app produces a signed launchable ATerm.app"
- Given: a clean `build/` directory
- When: `make app` runs
- Then: `build/ATerm.app/Contents/Info.plist` has `CFBundleIdentifier` `gl.j4.ATerm`, `CFBundleExecutable` `ATerm`, `CFBundleIconFile` `AppIcon`, `CFBundleShortVersionString` `1.0.0` and `NSHighResolutionCapable` true; `Contents/Resources/AppIcon.icns` exists; `codesign --verify` succeeds on the bundle; and `Contents/MacOS/ATerm --version` prints `ATerm 1.0.0`

## APP-BUNDLE-002 — The app icon is the logo in a macOS icon tile

Implement: `scripts/make-icon.swift` (run by `scripts/make-icon.sh`) drawing `Resources/Logo.png` aspect-filled into the standard macOS tile — the rounded rectangle at (100, 100), 824 × 824, corner radius 185 on a 1024 grid — with a soft shadow, at every iconset size; `scripts/bundle.sh` copying the icns into the app.

Test: e2e · `scripts/test-bundle.sh` · "APP-BUNDLE-002 the app icon is the logo in a macOS icon tile"
- Given: the design reference `Resources/Logo.png`, and the app built by `make app` (APP-BUNDLE-001)
- When: `Contents/Resources/AppIcon.icns` is converted with `iconutil -c iconset` and its `icon_512x512@2x.png` (1024 × 1024) is compared by `scripts/compare-icon.swift` with the logo drawn aspect-filled into the 824 × 824 tile at (100, 100)
- Then: inside the tile, inset 60 points from its edges (clear of the rounded corners), at most 2 % of the pixels differ from the reference by more than 16 on any channel; the pixels at (0, 0), (1023, 1023) and (110, 110) (outside the rounded corner) have alpha ≤ 0.05; the icns also holds the 16, 32, 128, 256 and 512 point sizes at 1× and 2×

## APP-BUNDLE-003 — make release produces a notarized, stapled ATerm zip and its release notes

`scripts/release.sh` (run by `make release`) needs a Developer ID Application
identity in the keychain (`SIGN_IDENTITY`, by default the first one found)
and notarytool credentials stored under the keychain profile `NOTARY_PROFILE`
(default `PLAY_NOTARY`, the team's profile, created once with `xcrun notarytool store-credentials`).

Implement: `scripts/release.sh`: `scripts/bundle.sh` building a universal executable (`ARCHS="arm64 x86_64"`), then the app signed with the Developer ID identity, the hardened runtime and a secure timestamp, zipped with `ditto`, submitted to `xcrun notarytool submit --wait`, stapled (`xcrun stapler staple`) and zipped again as `dist/ATerm-<version>.zip`, `<version>` being `CFBundleShortVersionString`; the section `## [<version>]` of `CHANGELOG.md` written to `dist/RELEASE_NOTES-<version>.md`. The script stops at the first failing step.
Uses: [APP-BUNDLE-001](#app-bundle-001--make-app-produces-a-signed-launchable-atermapp)

Test: e2e · `scripts/test-release.sh` · "APP-BUNDLE-003 make release produces a notarized stapled ATerm zip and its release notes"
- Given: a Developer ID Application identity and the notarytool profile, an empty `dist/`
- When: `make release` runs
- Then: `dist/ATerm-1.0.0.zip` holds exactly `ATerm.app`; once unzipped, `codesign --verify --strict --deep` succeeds on it, `codesign -dvv` shows an authority starting with `Developer ID Application:`, the `runtime` flag and a timestamp; `lipo -archs` of `Contents/MacOS/ATerm` lists `arm64` and `x86_64`; `xcrun stapler validate` succeeds; `spctl --assess --type execute` accepts it with the source `Notarized Developer ID`; `Contents/MacOS/ATerm --version` prints `ATerm 1.0.0`; `dist/RELEASE_NOTES-1.0.0.md` is the `## [1.0.0]` section of `CHANGELOG.md` without its heading, and is not empty
