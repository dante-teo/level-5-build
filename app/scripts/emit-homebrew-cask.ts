import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { versionFromTag } from "./version-utils";

const tapPath = process.argv[2];
if (!tapPath) {
	throw new Error("Usage: bun scripts/emit-homebrew-cask.ts <homebrew-tap-path>");
}

const tag = process.env.GITHUB_REF_NAME ?? "v0.0.0";
const version = versionFromTag(tag);
const sha256 = process.env.HOMEBREW_CASK_SHA256;
const artifactName = process.env.HOMEBREW_CASK_ARTIFACT;

if (!sha256 || !artifactName) {
	throw new Error("HOMEBREW_CASK_SHA256 and HOMEBREW_CASK_ARTIFACT are required.");
}

const repository = process.env.GITHUB_REPOSITORY ?? "dante-teo/level-5-build";
const caskPath = resolve(tapPath, "Casks", "level5-build.rb");
const cask = `cask "level5-build" do
  version "${version}"
  sha256 "${sha256}"

  url "https://github.com/${repository}/releases/download/v#{version}/${artifactName}"
  name "Level5 Build"
  desc "Open-source desktop app for AI coding workflows"
  homepage "https://github.com/${repository}"

  depends_on arch: :arm64

  app "Level5 Build.app"
end
`;

mkdirSync(dirname(caskPath), { recursive: true });
writeFileSync(caskPath, cask);

console.log(`Wrote ${caskPath}`);
