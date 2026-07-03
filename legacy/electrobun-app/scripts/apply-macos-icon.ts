import { copyFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

function walk(directory: string, matches: string[] = []) {
	if (!existsSync(directory)) {
		return matches;
	}

	for (const entry of readdirSync(directory)) {
		const path = join(directory, entry);
		const stat = statSync(path);
		if (stat.isDirectory() && entry.endsWith(".app")) {
			matches.push(path);
			continue;
		}
		if (stat.isDirectory()) {
			walk(path, matches);
		}
	}

	return matches;
}

if (process.platform !== "darwin") {
	console.log("Skipping macOS icon patch on non-macOS host.");
	process.exit(0);
}

const root = process.cwd();
const iconPath = resolve(root, "assets/App.icns");
const appBundles = walk(resolve(root, "build"));

if (!existsSync(iconPath)) {
	throw new Error(`Missing icon at ${iconPath}`);
}

for (const appBundle of appBundles) {
	const resourcesPath = join(appBundle, "Contents/Resources/AppIcon.icns");
	const plistPath = join(appBundle, "Contents/Info.plist");

	copyFileSync(iconPath, resourcesPath);

	for (const [key, value] of [
		["CFBundleIconFile", "AppIcon"],
		["CFBundleIconName", "AppIcon"],
	]) {
		const set = Bun.spawnSync({
			cmd: ["/usr/libexec/PlistBuddy", "-c", `Set :${key} ${value}`, plistPath],
			stdout: "ignore",
			stderr: "ignore",
		});

		if (!set.success) {
			const add = Bun.spawnSync({
				cmd: [
					"/usr/libexec/PlistBuddy",
					"-c",
					`Add :${key} string ${value}`,
					plistPath,
				],
				stdout: "ignore",
				stderr: "inherit",
			});

			if (!add.success) {
				throw new Error(`Failed to set ${key} in ${plistPath}`);
			}
		}
	}

	console.log(`Applied macOS icon to ${appBundle}`);
}
