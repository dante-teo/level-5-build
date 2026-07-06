# macOS Release

Releases are driven by `.github/workflows/release.yml`. A pushed release tag installs dependencies, syncs the release version, builds and signs `app/` with Electrobun (`bun run build:stable`, which codesigns and notarizes internally), packages a DMG, publishes a GitHub Release, and updates the stable Homebrew cask in `dante-teo/homebrew-tap`.

Manual `workflow_dispatch` runs are dry-run only: they build, sign, notarize, and package the artifact, but they do not create or update a GitHub Release and do not push Homebrew changes.

## Required Secrets

- `APPLE_CERTIFICATE_P12`: base64-encoded Developer ID Application `.p12`.
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12`.
- `MACOS_KEYCHAIN_PASSWORD`: temporary CI keychain password.
- `ELECTROBUN_DEVELOPER_ID`: full codesign identity, for example `Developer ID Application: <name> (<team id>)`. Read directly by Electrobun's build step.
- `ELECTROBUN_TEAMID`: Apple Developer Team ID. Read directly by Electrobun.
- `ELECTROBUN_APPLEID`: Apple ID used for notarization. Read directly by Electrobun.
- `ELECTROBUN_APPLEIDPASS`: app-specific password for notarization. Read directly by Electrobun.
- `HOMEBREW_TAP_TOKEN`: token that can push to `dante-teo/homebrew-tap`.

Stable tag releases require all secrets. Prerelease tag releases do not require `HOMEBREW_TAP_TOKEN` because they do not update the stable cask.

## Versioning

Release tags must match one of these formats:

- Stable: `vMAJOR.MINOR.PATCH`
- Prerelease: `vMAJOR.MINOR.PATCH-IDENTIFIER`

The pushed tag is authoritative: the release workflow applies the tag's version to its own checkout of `app/package.json`, `app/electrobun.config.ts`, and `app/src/shared/version.ts` before building (via `bun run version:sync -- <tag>`, i.e. `app/scripts/sync-version.ts`), regardless of what's committed, so the artifact always embeds the tagged version. After a successful non-dry-run release, the workflow also pushes a follow-up commit to `main` (`Sync app version to X.Y.Z [skip ci]`) if the committed version was out of sync, so history stays consistent without a required manual step.

Manually bumping the version before tagging is optional, but recommended so local builds off `main` show a sensible version in the meantime:

```bash
cd app
bun run version:sync -- v1.1.0
```

**Caveat:** if `main` has branch protection that requires PR review or otherwise blocks direct pushes, the workflow's sync-back push will fail. The release itself (build, sign, notarize, package, GitHub Release, Homebrew cask) still succeeds since that push happens last, but the committed version on `main` won't be updated automatically — in that case, keep bumping the version manually before tagging.

## Publishing

The minimal path for a stable release is just tagging and pushing:

```bash
git tag v1.1.0
git push origin v1.1.0
```

The workflow syncs `app/`'s version to `1.1.0` for the build and, on success, pushes a follow-up commit to `main` to match. If you'd rather commit the bump yourself (e.g. `main` is branch-protected, see the caveat above), do it before tagging:

```bash
cd app
bun run version:sync -- v1.1.0
git add package.json electrobun.config.ts src/shared/version.ts
git commit -m "Bump app to 1.1.0"
git tag v1.1.0
git push origin main v1.1.0
```

The published artifact is named:

```text
Level5-Build-vMAJOR.MINOR.PATCH-macos-ARCH.dmg
```

For example:

```text
Level5-Build-v1.1.0-macos-arm64.dmg
```

Stable releases update the Homebrew cask:

```ruby
cask "level5-build" do
  app "Level5 Build.app"
  depends_on arch: :arm64
end
```

Prerelease tags such as `v1.1.0-beta.1` create GitHub prereleases but skip Homebrew cask updates.

## Local Validation

From `app/`:

```bash
bun install
bun run typecheck
bun test
bun run build:macos-effects
bun run build:web
```

Release workflow validation checks include:

```bash
codesign --verify --deep --strict --verbose=2 "Level5 Build.app"
spctl -a -vv "Level5 Build.app"
xcrun stapler validate "Level5 Build.app"
xcrun stapler validate "Level5-Build-v1.1.0-macos-arm64.dmg"
spctl -a -t open --context context:primary-signature -vv "Level5-Build-v1.1.0-macos-arm64.dmg"
hdiutil attach "Level5-Build-v1.1.0-macos-arm64.dmg" -readonly
```

Use the explicit `-t open --context context:primary-signature` Gatekeeper assessment for DMGs. The default `spctl -a` assessment is for executable code and can reject a valid signed, notarized disk image as non-executable.

## Full Check Suite

Before merging release automation changes, run:

```bash
ruby -e 'require "yaml"; ARGV.each { |path| YAML.load_file(path) }' .github/workflows/ci.yml .github/workflows/release.yml
git diff --check
```

From `app/`:

```bash
bun install
bun run typecheck
bun test
bun run build:macos-effects
bun run build:web
```

From `acp-mock-server/`:

```bash
bun install --frozen-lockfile
bunx tsc --noEmit -p tsconfig.json
bun test
bash -n start.sh
```
