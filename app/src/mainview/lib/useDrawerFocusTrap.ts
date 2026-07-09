import type { RefObject } from "react";
import { useEffect, useRef } from "react";

const FOCUSABLE = "button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])";

type DrawerTabBoundary = {
	focusableCount: number;
	activeIndex: number;
	focusWithinPane: boolean;
	shiftKey: boolean;
};

/** Returns a focusable index to wrap to, -1 for the pane, or null to allow native tab order. */
export function drawerTabWrapTarget({
	focusableCount,
	activeIndex,
	focusWithinPane,
	shiftKey,
}: DrawerTabBoundary): number | null {
	if (focusableCount === 0) return -1;
	if (shiftKey) {
		return !focusWithinPane || activeIndex <= 0 ? focusableCount - 1 : null;
	}
	return !focusWithinPane || activeIndex < 0 || activeIndex === focusableCount - 1 ? 0 : null;
}

export function useDrawerFocusTrap(ref: RefObject<HTMLElement | null>, active: boolean, onClose: () => void) {
	const onCloseRef = useRef(onClose);
	onCloseRef.current = onClose;
	useEffect(() => {
		if (!active) return;
		const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
		const pane = ref.current;
		pane?.focus();
		function handleKeyDown(event: KeyboardEvent) {
			if (event.key === "Escape") {
				event.preventDefault();
				onCloseRef.current();
				return;
			}
			if (event.key !== "Tab" || !pane) return;
			const focusable = [...pane.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((element) => !element.hidden);
			const activeElement = document.activeElement instanceof HTMLElement ? document.activeElement : null;
			const targetIndex = drawerTabWrapTarget({
				focusableCount: focusable.length,
				activeIndex: activeElement ? focusable.indexOf(activeElement) : -1,
				focusWithinPane: activeElement ? pane.contains(activeElement) : false,
				shiftKey: event.shiftKey,
			});
			if (targetIndex !== null) {
				event.preventDefault();
				if (targetIndex === -1) pane.focus();
				else focusable[targetIndex]?.focus();
			}
		}
		document.addEventListener("keydown", handleKeyDown);
		return () => {
			document.removeEventListener("keydown", handleKeyDown);
			previousFocus?.focus();
		};
	}, [active, ref]);
}
