import { describe, expect, test } from "bun:test";
import { drawerTabWrapTarget } from "./useDrawerFocusTrap";

describe("drawerTabWrapTarget", () => {
	test("wraps Shift+Tab from the pane itself to the last control", () => {
		expect(drawerTabWrapTarget({ focusableCount: 3, activeIndex: -1, focusWithinPane: true, shiftKey: true })).toBe(2);
	});

	test("pulls reverse focus back from behind the drawer", () => {
		expect(drawerTabWrapTarget({ focusableCount: 3, activeIndex: -1, focusWithinPane: false, shiftKey: true })).toBe(2);
	});

	test("wraps forward focus from the last control to the first", () => {
		expect(drawerTabWrapTarget({ focusableCount: 3, activeIndex: 2, focusWithinPane: true, shiftKey: false })).toBe(0);
	});

	test("leaves ordinary tab movement inside the drawer alone", () => {
		expect(drawerTabWrapTarget({ focusableCount: 3, activeIndex: 1, focusWithinPane: true, shiftKey: false })).toBeNull();
	});

	test("keeps focus on the pane when there are no controls", () => {
		expect(drawerTabWrapTarget({ focusableCount: 0, activeIndex: -1, focusWithinPane: true, shiftKey: true })).toBe(-1);
	});
});
