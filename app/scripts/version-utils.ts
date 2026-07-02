const RELEASE_TAG_PATTERN = /^v(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/;

export function versionFromTag(tag: string): string {
	const match = RELEASE_TAG_PATTERN.exec(tag.trim());
	if (!match) {
		throw new Error(`Expected a release tag like v0.0.0, received "${tag}".`);
	}
	return match[1];
}

export function tagFromVersion(version: string): string {
	return `v${versionFromTag(`v${version}`)}`;
}
