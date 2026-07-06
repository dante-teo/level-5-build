import { dlopen, FFIType } from "bun:ffi";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";

// Electrobun's public BrowserWindow API has no vibrancy option (only
// `titleBarStyle: "hiddenInset"` and `transparent: true`), so a real
// NSVisualEffectView-backed sidebar material (matching Apple's own
// Finder/Photos/Maps sidebars) needs a small native bridge, built by
// scripts/build-macos-effects.sh from native/macos/window-effects.mm and
// loaded here via bun:ffi. Resolution mirrors
// agent/runtime.ts's resolveMockAcpStartPath: try the packaged app
// Resources layout first, then dev-from-source locations.
export function resolveMacWindowEffectsDylibPath(
	input: { execPath?: string; cwd?: string } = {},
): string {
	const cwd = input.cwd ?? process.cwd();
	const execPath = input.execPath ?? process.execPath;
	const candidates = [
		resolve(dirname(execPath), "../Resources/app/libMacWindowEffects.dylib"),
		resolve(dirname(execPath), "Resources/app/libMacWindowEffects.dylib"),
		resolve(cwd, "src/bun/libMacWindowEffects.dylib"),
		resolve(cwd, "libMacWindowEffects.dylib"),
	];

	return candidates.find((candidate) => existsSync(candidate)) ?? candidates[candidates.length - 1]!;
}

export type MacWindowEffectsHandle = {
	enableWindowVibrancy(windowPtr: unknown): boolean;
	ensureWindowShadow(windowPtr: unknown): boolean;
};

/**
 * Best-effort: returns null (never throws) if the platform isn't macOS, the
 * dylib hasn't been built (see scripts/build-macos-effects.sh), or loading
 * it fails for any reason. Callers should treat a null result the same as
 * "native effects unavailable" and fall back to the existing
 * transparent-only/opaque behavior.
 */
export function loadMacWindowEffects(
	dylibPath: string = resolveMacWindowEffectsDylibPath(),
): MacWindowEffectsHandle | null {
	if (process.platform !== "darwin" || !existsSync(dylibPath)) {
		return null;
	}
	try {
		const lib = dlopen(dylibPath, {
			enableWindowVibrancy: { args: [FFIType.ptr], returns: FFIType.bool },
			ensureWindowShadow: { args: [FFIType.ptr], returns: FFIType.bool },
		});
		return {
			enableWindowVibrancy: (windowPtr) => Boolean(lib.symbols.enableWindowVibrancy(windowPtr as never)),
			ensureWindowShadow: (windowPtr) => Boolean(lib.symbols.ensureWindowShadow(windowPtr as never)),
		};
	} catch (error) {
		console.warn("Failed to load native macOS window effects:", error);
		return null;
	}
}

/**
 * Applies real NSVisualEffectView vibrancy (sidebar material) plus a window
 * shadow to `window`, so translucent surfaces (the sidebar, floating
 * capsules) reveal genuine frosted glass instead of flatly blurring an
 * opaque backdrop. Never throws; a failure just leaves the window in its
 * default opaque/transparent-only state.
 */
export function applyMacWindowEffects(window: { ptr: unknown }): { vibrancy: boolean; shadow: boolean } {
	const lib = loadMacWindowEffects();
	if (!lib) {
		return { vibrancy: false, shadow: false };
	}
	try {
		const vibrancy = lib.enableWindowVibrancy(window.ptr);
		const shadow = lib.ensureWindowShadow(window.ptr);
		return { vibrancy, shadow };
	} catch (error) {
		console.warn("Failed to apply native macOS window effects:", error);
		return { vibrancy: false, shadow: false };
	}
}
