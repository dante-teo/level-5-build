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

Before tagging, update the native app version from the repo root:

```bash
./script/sync_native_version.sh 1.0.0
```

The script updates only `app/project.yml`:

- `MARKETING_VERSION` is set to the supplied version.
- `CURRENT_PROJECT_VERSION` increments by `1` when the marketing version changes.

The first native release is `MARKETING_VERSION=1.0.0` and `CURRENT_PROJECT_VERSION=1`.

The release workflow fails if the tag version does not match the committed `MARKETING_VERSION`. It does not mutate source after a tag is pushed.

## Publishing

For a stable release:

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
