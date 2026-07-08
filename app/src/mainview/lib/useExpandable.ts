import { useState } from "react";

/**
 * Tri-state expand/collapse: `null` (the default) defers to `defaultExpanded`
 * (typically a derived signal like "in progress" or "failed"); once the user
 * clicks, their choice is a hard override that ignores `defaultExpanded`
 * entirely until this component instance unmounts (a fresh instance -- e.g.
 * a new turn's row -- always starts back at `null`). Used by every
 * expandable row in the transcript working section (see docs/DESIGN.md
 * "Chat"): `WorkingSection`, `ToolRow`, `ToolGroupRow`, `SubItemRow`.
 */
export function useExpandable(defaultExpanded: boolean): [boolean, () => void] {
	const [manualExpanded, setManualExpanded] = useState<boolean | null>(null);
	const isExpanded = manualExpanded ?? defaultExpanded;
	return [isExpanded, () => setManualExpanded(!isExpanded)];
}
