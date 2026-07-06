# Native macOS Release

Releases are driven by `.github/workflows/release.yml`. A pushed release tag builds the native Xcode app target, signs it with Developer ID, notarizes and staples the app and DMG, publishes a GitHub Release, and updates the stable Homebrew cask in `dante-teo/homebrew-tap`.

Manual `workflow_dispatch` runs are dry-run only: they build, sign, notarize, package, staple, and validate the artifact, but they do not create or update a GitHub Release and do not push Homebrew changes.

## Required Secrets

The workflow reuses the existing release secrets:

- `APPLE_CERTIFICATE_P12`: base64-encoded Developer ID Application `.p12`.
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12`.
- `MACOS_KEYCHAIN_PASSWORD`: temporary CI keychain password.
- `ELECTROBUN_DEVELOPER_ID`: full codesign identity, for example `Developer ID Application: <name> (<team id>)`.
- `ELECTROBUN_TEAMID`: Apple Developer Team ID.
- `ELECTROBUN_APPLEID`: Apple ID used with `notarytool`.
- `ELECTROBUN_APPLEIDPASS`: app-specific password for notarization.
- `HOMEBREW_TAP_TOKEN`: token that can push to `dante-teo/homebrew-tap`.

Stable tag releases require all secrets. Prerelease tag releases do not require `HOMEBREW_TAP_TOKEN` because they do not update the stable cask.

## Versioning

Release tags must match one of these formats:

- Stable: `vMAJOR.MINOR.PATCH`
- Prerelease: `vMAJOR.MINOR.PATCH-IDENTIFIER`

The pushed tag is authoritative: the release workflow applies the tag's version to its own checkout of `app/project.yml` before building (via `./script/sync_native_version.sh`), regardless of what's committed, so the artifact always embeds the tagged version. After a successful non-dry-run release, the workflow also pushes a follow-up commit to `main` (`Sync native app version to X.Y.Z [skip ci]`) if the committed `app/project.yml` was out of sync, so history stays consistent without a required manual step.

Manually bumping the version before tagging is now optional, but still recommended so that local Xcode builds off `main` show a sensible version in the meantime:

```bash
./script/sync_native_version.sh 1.0.0
```

The script updates only `app/project.yml`:

- `MARKETING_VERSION` is set to the supplied version.
- `CURRENT_PROJECT_VERSION` increments by `1` when the marketing version changes.

The first native release is `MARKETING_VERSION=1.0.0` and `CURRENT_PROJECT_VERSION=1`.

**Caveat:** if `main` has branch protection that requires PR review or otherwise blocks direct pushes, the workflow's sync-back push will fail. The release itself (build, sign, notarize, GitHub Release, Homebrew cask) still succeeds since that push happens last, but `app/project.yml` on `main` won't be updated automatically — in that case, keep bumping the version manually before tagging.

### Known limitations of the sync-back step

- **No ancestry/monotonicity check.** The sync-back step assumes every tag is cut from `main`'s current tip, which matches this project's tag-from-tip flow. It does not verify the tag's commit descends from `main` or that its version is newer than what's committed. A tag cut from an older commit (e.g. a future hotfix/maintenance-branch workflow) would push a version *regression* to `main`. Not a concern today, but worth revisiting before adopting maintenance branches.
- **Not gated on prerelease.** Unlike the Homebrew cask steps, the sync-back step runs for prerelease tags too. Pushing `v1.0.0-beta.1` will sync that literal prerelease string onto `main`'s committed `MARKETING_VERSION` until the next stable tag corrects it.
- **`CURRENT_PROJECT_VERSION` is recomputed independently, not reused.** The sync-back step reruns `sync_native_version.sh` against a fresh `main` checkout rather than reusing the value actually embedded in the build. If `main` moves between the tag push and this step running (e.g. a rapid follow-up release, or someone bumping `app/project.yml` on `main` mid-build), the `CURRENT_PROJECT_VERSION` pushed to `main` isn't guaranteed to match what was actually shipped in that release's artifact.

## Publishing

The minimal path for a stable release is just tagging and pushing:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow syncs `app/project.yml` to `1.0.0` for the build and, on success, pushes a follow-up commit to `main` to match. If you'd rather commit the bump yourself (e.g. `main` is branch-protected, see the caveat above), do it before tagging:

```bash
./script/sync_native_version.sh 1.0.0
git add app/project.yml
git commit -m "Bump native app to 1.0.0"
git tag v1.0.0
git push origin main v1.0.0
```

The published artifact is named:

```text
Level5-Build-vMAJOR.MINOR.PATCH-macos-arm64.dmg
```

For example:

```text
Level5-Build-v1.0.0-macos-arm64.dmg
```

Stable releases update the Homebrew cask:

```ruby
cask "level5-build" do
  app "Level5 Build.app"
  depends_on arch: :arm64
end
```

Prerelease tags such as `v1.0.0-beta.1` create GitHub prereleases but skip Homebrew cask updates.

## Local Validation

From the repo root:

```bash
bash -n script/build_and_run.sh
bash -n script/sync_native_version.sh
bash -n script/generate_homebrew_cask.sh
```

From `app/`:

```bash
swift test
xcodebuild test \
  -project "Level5 Build.xcodeproj" \
  -scheme "Level5 Build" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

Release workflow validation checks include:

```bash
codesign --verify --deep --strict --verbose=2 "Level5 Build.app"
spctl -a -vv "Level5 Build.app"
xcrun stapler validate "Level5 Build.app"
xcrun stapler validate "Level5-Build-v1.0.0-macos-arm64.dmg"
spctl -a -t open --context context:primary-signature -vv "Level5-Build-v1.0.0-macos-arm64.dmg"
hdiutil attach "Level5-Build-v1.0.0-macos-arm64.dmg" -readonly
```

Use the explicit `-t open --context context:primary-signature` Gatekeeper assessment for DMGs. The default `spctl -a` assessment is for executable code and can reject a valid signed, notarized disk image as non-executable.

## Full Check Suite

Before merging release automation changes, run the root and native app checks:

```bash
bash -n script/build_and_run.sh
bash -n script/sync_native_version.sh
bash -n script/generate_homebrew_cask.sh
ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path) }' .github/workflows/ci.yml .github/workflows/release.yml app/project.yml
git diff --check
```

From `app/`:

```bash
swift test
xcodebuild test \
  -project "Level5 Build.xcodeproj" \
  -scheme "Level5 Build" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

From `acp-mock-server/`:

```bash
pnpm install --frozen-lockfile
bunx tsc --noEmit -p tsconfig.json
bun test
bash -n start.sh
```
