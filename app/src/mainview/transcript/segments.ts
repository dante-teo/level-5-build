import type { TranscriptItem } from "@/App";

export type TurnSegment =
	| { type: "item"; item: Extract<TranscriptItem, { type: "message" | "error" }> }
	| { type: "working"; key: string; items: Array<Extract<TranscriptItem, { type: "tool" | "thought" }>> };

export function segmentTranscript(items: TranscriptItem[]): TurnSegment[] {
	const segments: TurnSegment[] = [];
	for (const item of items) {
		if (item.type === "tool" || item.type === "thought") {
			const lastSegment = segments[segments.length - 1];
			if (lastSegment?.type === "working") {
				lastSegment.items.push(item);
			} else {
				segments.push({ type: "working", key: item.key, items: [item] });
			}
			continue;
		}
		segments.push({ type: "item", item });
	}
	return segments;
}
