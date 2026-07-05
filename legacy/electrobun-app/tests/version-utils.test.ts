import { describe, expect, test } from "bun:test";
import { tagFromVersion, versionFromTag } from "../scripts/version-utils";

describe("release version helpers", () => {
	test("extracts a semantic version from a release tag", () => {
		expect(versionFromTag("v0.0.0")).toBe("0.0.0");
		expect(versionFromTag("v1.2.3")).toBe("1.2.3");
	});

	test("rejects tags without a v prefix", () => {
		expect(() => versionFromTag("1.2.3")).toThrow();
	});

	test("creates a release tag from a version", () => {
		expect(tagFromVersion("0.0.0")).toBe("v0.0.0");
	});
});
