import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { versionFromTag } from "./version-utils";

const tag = process.env.GITHUB_REF_NAME ?? process.argv[2] ?? "v0.0.0";
const version = versionFromTag(tag);
const root = process.cwd();
const arch = (process.env.RUNNER_ARCH ?? process.arch).toLowerCase();
const artifactName = `Level5-Build-v${version}-macos-${arch}.dmg`;
const artifactPath = resolve(root, "artifacts", artifactName);
const electrobunDmgPath = resolve(
	root,
	"artifacts",
	`stable-macos-${arch}-Level5Build.dmg`,
);

mkdirSync(resolve(root, "artifacts"), { recursive: true });

if (!existsSync(electrobunDmgPath)) {
	throw new Error(`Could not find Electrobun DMG at ${electrobunDmgPath}`);
}

copyFileSync(electrobunDmgPath, artifactPath);

console.log(`artifact_name=${artifactName}`);
console.log(`artifact_path=${artifactPath}`);
