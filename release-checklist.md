# Release checklist

Releases are signed with a Developer ID, notarized by Apple and published on GitHub Releases. Installed copies
update themselves with [Sparkle](https://sparkle-project.org) from `appcast.xml` on the latest release.

## One-time setup

- [ ] A "Developer ID Application" certificate in the login keychain.
- [ ] Notary credentials:
      `xcrun notarytool store-credentials palette-notary --apple-id <id> --team-id 36KWU56M5R`
- [ ] The Sparkle private key in the login keychain, account `palette`. Its public key is `SUPublicEDKey` in
      `Resources/Info.plist`. Back it up: `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account palette -x <file>`.

## Before the release

- [ ] `VERSION` holds the new version, committed and pushed to `main`. The release builds `origin/main`, not the
      working tree.
- [ ] CI is green on that commit (`make test` and `make e2e` locally).
- [ ] Optional release notes in `dist/releases/x.y.z/Palette-x.y.z.md`. Sparkle shows them in the update window.

## Build and publish

- [ ] `make release VERSION=x.y.z` (universal build, signing, notarization, stapling, appcast). It ends with
      "Palette x.y.z (…) is ready in dist/releases/x.y.z".
- [ ] `make publish VERSION=x.y.z` tags the built commit `vx.y.z` and creates the release with the zip, its
      checksum and `appcast.xml`.
- [ ] The release is not a draft or pre-release, otherwise `releases/latest` still points to the old version.

## Check

- [ ] The release contents hold nothing from this Mac. `scripts/release.sh` already fails if the bundle contains
      your home directory. Also look through `unzip -l dist/releases/x.y.z/Palette-x.y.z.zip`: no `__MACOSX`
      entries, and `Contents/Resources` has `LICENSE` and `ThirdPartyNotices.txt`.
- [ ] `codesign --verify --strict --deep --verbose=2` and `spctl --assess --type execute --verbose` pass on the
      unzipped app, and `xcrun stapler validate` finds the ticket.
- [ ] The feed shows the new version (public repository only):
      `curl -L https://github.com/builtbymax/palette/releases/latest/download/appcast.xml`
- [ ] Download the zip, unzip and open it. No Gatekeeper warning apart from "downloaded from the internet".
- [ ] An installed older version finds the update (menu → Check for Updates…), installs it and restarts.
- [ ] Accessibility still works without asking again, and a new terminal tab still gets suggestions.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Notarization fails | `xcrun notarytool log <submission-id> --keychain-profile palette-notary` lists the files with signing problems. |
| `generate_appcast` can't find a signing key | The Sparkle private key is missing from this Mac's keychain. Restore the backup with `generate_keys --account palette -f <file>` and run `make release` again. Never create a new key: installed copies only accept updates signed with the key matching their `SUPublicEDKey`. |
| "Update is improperly signed" in an installed copy | The archive's EdDSA signature doesn't match the copy's `SUPublicEDKey`, or the zip was changed after `make release`. Upload the zip and `appcast.xml` from the same `make release` run. If the original key is lost, older copies can't update and must be replaced by hand. |
| No update offered | Either the new build number (derived from the version: x.y.z → x·1000000 + y·1000 + z) isn't higher than the installed one, so raise the version, or `releases/latest` still points to the previous release because the new one is a draft or pre-release. Scheduled checks run once a day; **Check for Updates…** checks right away. |
| Update check fails with 404 | GitHub doesn't serve release assets of a private repository without signing in. Make the repository public, or publish releases in a public repository and change `SUFeedURL` and the URLs in `scripts/release.sh` (keep build numbers increasing). |
