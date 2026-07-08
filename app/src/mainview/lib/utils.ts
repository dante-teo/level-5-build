import { clsx, type ClassValue } from "clsx";
import { extendTailwindMerge } from "tailwind-merge";

/**
 * tailwind-merge must be taught the project's custom theme scales or it
 * misclassifies them and silently drops classes: `text-body`, `text-caption`,
 * etc. are font-size utilities here (see index.css `@theme`'s `--text-*`
 * keys), but stock tailwind-merge parses unknown `text-*` values as text
 * *colors*, so `cn("text-body", "text-l5-glass-text")` deleted the font-size
 * class entirely and let browser-default 16px leak through the type scale.
 */
const twMerge = extendTailwindMerge({
	extend: {
		classGroups: {
			"font-size": [{ text: ["display", "h1", "h2", "h3", "body", "caption", "mono"] }],
		},
	},
});

export function cn(...inputs: ClassValue[]) {
	return twMerge(clsx(inputs));
}
