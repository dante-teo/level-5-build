#import <Cocoa/Cocoa.h>

// Native macOS window-effects bridge, loaded via Bun FFI from
// src/bun/macWindowEffects.ts. Electrobun's public BrowserWindow API only
// exposes `titleBarStyle: "hiddenInset"` and `transparent: true` -- it has
// no public vibrancy API, so a real NSVisualEffectView-backed sidebar
// material (matching Apple's own apps, e.g. Photos/Finder/Maps) requires
// this small Objective-C++ bridge instead. Adapted from the approach in
// https://github.com/mayfer/electrobun-macos-native-blur.
//
// Deliberately scoped to just vibrancy + shadow: window dragging stays on
// Electrobun's existing CSS-region-based drag (see AGENTS.md's "Window
// chrome" notes) rather than a native NSView drag overlay, since a blind
// native drag-catching view would sit above the WKWebView and swallow
// clicks on the interactive controls (sidebar toggle, dashboard/review
// triggers, etc.) that live inside the same draggable strip today.

static NSString *const kElectrobunVibrancyViewIdentifier = @"ElectrobunVibrancyView";

static NSVisualEffectView *findVibrancyView(NSView *contentView) {
	for (NSView *subview in [contentView subviews]) {
		if ([subview isKindOfClass:[NSVisualEffectView class]] &&
			[[subview identifier] isEqualToString:kElectrobunVibrancyViewIdentifier]) {
			return (NSVisualEffectView *)subview;
		}
	}

	return nil;
}

extern "C" bool enableWindowVibrancy(void *windowPtr) {
	if (windowPtr == nullptr) {
		return false;
	}

	__block BOOL success = NO;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSWindow *window = (__bridge NSWindow *)windowPtr;
		if (![window isKindOfClass:[NSWindow class]]) {
			return;
		}

		[window setOpaque:NO];
		[window setBackgroundColor:[NSColor clearColor]];
		[window setTitlebarAppearsTransparent:YES];
		[window setHasShadow:YES];

		NSView *contentView = [window contentView];
		if (contentView == nil) {
			return;
		}

		NSVisualEffectView *effectView = findVibrancyView(contentView);

		if (effectView == nil) {
			effectView = [[NSVisualEffectView alloc] initWithFrame:[contentView bounds]];
			[effectView setIdentifier:kElectrobunVibrancyViewIdentifier];
			[effectView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
		}

		// Sidebar material most closely matches the frosted-glass look of
		// Apple's own sidebars (Finder/Photos/Maps); see docs/DESIGN.md's
		// "liquid glass" guidance.
		[effectView setMaterial:NSVisualEffectMaterialSidebar];
		[effectView setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
		[effectView setState:NSVisualEffectStateActive];

		if ([effectView superview] == nil) {
			NSView *relativeView = [[contentView subviews] firstObject];
			if (relativeView != nil) {
				[contentView addSubview:effectView positioned:NSWindowBelow relativeTo:relativeView];
			} else {
				[contentView addSubview:effectView];
			}
		}

		[window invalidateShadow];
		success = YES;
	});

	return success;
}

extern "C" bool ensureWindowShadow(void *windowPtr) {
	if (windowPtr == nullptr) {
		return false;
	}

	__block BOOL success = NO;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSWindow *window = (__bridge NSWindow *)windowPtr;
		if (![window isKindOfClass:[NSWindow class]]) {
			return;
		}

		[window setHasShadow:YES];
		[window invalidateShadow];
		success = YES;
	});

	return success;
}
