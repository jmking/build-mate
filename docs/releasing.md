# Releasing Build Mate

Releases are Apple Silicon only, for macOS 26+. Build on a Mac with Xcode 27 and XcodeGen. Signing stays local; GitHub Actions builds and runs isolated tests without access to signing credentials.

## One-time setup

Install a **Developer ID Application** certificate in your Keychain using Xcode’s account settings. Store notarization credentials using `xcrun notarytool store-credentials` and its interactive prompts. Never put passwords, certificates or API keys in this repository or a shell script.

Set `SIGN_IDENTITY` to the matching identity from `security find-identity -v -p codesigning`, and `NOTARY_PROFILE` to the name of the stored Keychain profile. An existing profile from another app can be reused when it belongs to the same Apple developer team.

See Apple’s [notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) for account setup and signing requirements.

## Build the release

1. Update `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in `project.yml`. Run XcodeGen so the checked-in Info.plist stays consistent. Use `MAJOR.MINOR.PATCH` for the marketing version.
2. Update the README if support or setup changed. Write short release notes describing the user-facing changes and known limitations.
3. Run `./scripts/check.sh`. Inspect relevant UI in light/dark appearance and test the app from an isolated data directory. For a release candidate, test an installed copy on a clean Mac/account when available; the automated suite does not prove third-party account or permission behavior.
4. Scan the source/history for secrets (for example `gitleaks git --redact`), inspect the diff, and commit the release changes. Keep the working tree clean.
5. Run:

```sh
export SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-notary-profile'
./scripts/release.sh
```

The script builds `Release` for `arm64`, embeds the source commit, signs with hardened runtime and a secure timestamp, notarizes and staples the app, builds a drag-to-Applications DMG, then signs/notarizes/staples and checks that DMG. It fails if any required step fails; there is no unsigned fallback. GRDB’s license is bundled in the app.

Successful output is `dist/<version>/`: a DMG, `SHA256SUMS`, `BUILD.txt`, and Apple’s submission receipts. Existing output is never overwritten. Build logs may be redirected outside the repository. Artifacts and signing material are ignored by Git.

Mount the DMG read-only and verify its app has the expected version, source commit, arm64 architecture and valid signature. Do not launch against your usual app data while smoke-testing a new build.

## Publish the exact commit

Use the source commit in `BUILD.txt`. Do not tag a later commit just because it is now HEAD. For the first release, create the public repository without a generated README, license or .gitignore, then add its remote.

```sh
# Replace the example version and commit with the verified values.
git tag -a v0.1.0 <source-commit> -m 'Build Mate 0.1.0'
git push origin main v0.1.0
gh release create v0.1.0 \
  dist/0.1.0/Build-Mate-0.1.0-arm64.dmg \
  dist/0.1.0/SHA256SUMS dist/0.1.0/BUILD.txt \
  --verify-tag --draft --prerelease --title 'Build Mate 0.1.0' \
  --notes-file /path/to/release-notes.md
```

Review the uploaded assets and notes, then publish the draft. Keep preview builds marked as pre-releases. Stable releases can omit `--prerelease`. GitHub displays the Releases section once a release is published; do not commit DMGs into the source repository. After upload, compare the downloaded DMG’s SHA-256 with the local checksum.

Enable private vulnerability reporting in the repository’s security settings so the link in `SECURITY.md` works. Keep Actions permissions read-only and never expose signing secrets to fork pull requests. There is no auto-updater or signing workflow in CI; future releases use the same local script.
