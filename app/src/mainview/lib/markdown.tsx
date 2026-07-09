import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import { cn } from "./utils";

// Chat message bodies render Markdown (bold/italic, inline code, links,
// lists, headings, blockquotes, code blocks, tables) rather than raw text,
// mirroring the native app's L5MarkdownTheme (see docs/DESIGN.md "Chat").
// Component overrides keep sizing/spacing consistent with the surrounding
// bubble instead of relying on a Tailwind Typography plugin this project
// does not have installed.
export const MARKDOWN_COMPONENTS: Components = {
	p: ({ children }) => <p className="mb-2 last:mb-0">{children}</p>,
	a: ({ children, href }) => (
		<a
			href={href}
			target="_blank"
			rel="noreferrer"
			className="text-l5-accent underline decoration-l5-accent/40 underline-offset-2 transition-colors duration-quick hover:decoration-l5-accent"
		>
			{children}
		</a>
	),
	code: ({ className, children }) => {
		const isBlock = Boolean(className);
		return isBlock ? (
			<code className={cn("font-mono text-mono", className)}>{children}</code>
		) : (
			<code className="rounded-small bg-muted px-1 py-0.5 font-mono text-mono">{children}</code>
		);
	},
	pre: ({ children }) => (
		<pre className="app-scrollbar-transparent my-2 overflow-x-auto rounded-medium border border-border/60 bg-muted/50 p-3 leading-relaxed last:mb-0">
			{children}
		</pre>
	),
	ul: ({ children }) => <ul className="mb-2 list-disc space-y-1 pl-5 last:mb-0">{children}</ul>,
	ol: ({ children }) => <ol className="mb-2 list-decimal space-y-1 pl-5 last:mb-0">{children}</ol>,
	li: ({ children }) => <li>{children}</li>,
	// Markdown headings inside chat map onto the compact end of the type
	// scale (DESIGN.md "Typography": match display text to its container).
	h1: ({ children }) => <h1 className="mb-2 mt-4 text-h3 font-semibold first:mt-0 last:mb-0">{children}</h1>,
	h2: ({ children }) => <h2 className="mb-2 mt-3 text-body font-semibold first:mt-0 last:mb-0">{children}</h2>,
	h3: ({ children }) => <h3 className="mb-2 mt-3 text-body font-semibold text-muted-foreground first:mt-0 last:mb-0">{children}</h3>,
	blockquote: ({ children }) => (
		<blockquote className="mb-2 border-l-2 border-l5-accent/30 pl-3 text-muted-foreground last:mb-0">
			{children}
		</blockquote>
	),
	hr: () => <hr className="my-3 border-border/60" />,
	table: ({ children }) => (
		<div className="app-scrollbar-transparent my-2 overflow-x-auto rounded-medium border border-border/60 last:mb-0">
			<table className="w-full border-collapse text-caption">{children}</table>
		</div>
	),
	thead: ({ children }) => <thead className="bg-muted/50">{children}</thead>,
	tbody: ({ children }) => <tbody>{children}</tbody>,
	tr: ({ children }) => <tr className="border-b border-border/40 last:border-b-0">{children}</tr>,
	th: ({ children }) => <th className="px-3 py-1.5 text-left font-semibold text-muted-foreground">{children}</th>,
	td: ({ children }) => <td className="px-3 py-1.5">{children}</td>,
};

const REMARK_PLUGINS = [remarkGfm];

/** Shared markdown renderer with GFM (tables, strikethrough, autolinks). */
export function Markdown({ children, className }: { children: string; className?: string }) {
	return (
		<div className={className}>
			<ReactMarkdown remarkPlugins={REMARK_PLUGINS} components={MARKDOWN_COMPONENTS}>
				{children}
			</ReactMarkdown>
		</div>
	);
}
