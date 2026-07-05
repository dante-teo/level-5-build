import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { versionFromTag } from "./version-utils";

function replaceOrThrow(source: string, pattern: RegExp, replacement: string) {
	if (!pattern.test(source)) {
		throw new Error(`Could not find pattern ${pattern}`);
	}
	return source.replace(pattern, replacement);
}

const tag = process.argv[2] ?? process.env.GITHUB_REF_NAME ?? "v0.0.0";
const version = versionFromTag(tag);
const root = process.cwd();

const packagePath = resolve(root, "package.json");
const packageJson = JSON.parse(readFileSync(packagePath, "utf8"));
packageJson.version = version;
writeFileSync(packagePath, `${JSON.stringify(packageJson, null, "\t")}\n`);

const electrobunConfigPath = resolve(root, "electrobun.config.ts");
const electrobunConfig = readFileSync(electrobunConfigPath, "utf8");
writeFileSync(
	electrobunConfigPath,
	replaceOrThrow(
		electrobunConfig,
		/version: "[^"]+"/,
		`version: "${version}"`,
	),
);

const versionSourcePath = resolve(root, "src/shared/version.ts");
writeFileSync(versionSourcePath, `export const APP_VERSION = "${version}";\n`);

console.log(`Synced Level5 Build version to ${version}.`);
