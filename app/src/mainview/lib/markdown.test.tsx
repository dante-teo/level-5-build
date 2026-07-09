import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./markdown";

/** Render the Markdown component to a static HTML string for assertion. */
function render(md: string): string {
	return renderToStaticMarkup(<Markdown>{md}</Markdown>);
}

describe("Markdown", () => {
	test("renders a GFM pipe table as an HTML table", () => {
		const md = "| Item | Action |\n|---|---|\n| `foo` | **Keep** |\n| `bar` | Skip |";
		const html = render(md);
		expect(html).toContain("<table");
		expect(html).toContain("<thead");
		expect(html).toContain("<th");
		expect(html).toContain("<td");
		expect(html).toContain("foo");
		expect(html).toContain("Keep");
	});

	test("renders headings with appropriate classes", () => {
		const html = render("## Section title");
		expect(html).toContain("<h2");
		expect(html).toContain("font-semibold");
		expect(html).toContain("Section title");
	});

	test("renders inline code with styling", () => {
		const html = render("Use `bun test` to run");
		expect(html).toContain("<code");
		expect(html).toContain("rounded-small");
		expect(html).toContain("bun test");
	});

	test("renders a horizontal rule", () => {
		const html = render("above\n\n---\n\nbelow");
		expect(html).toContain("<hr");
		expect(html).toContain("border-border");
	});

	test("renders links with target=_blank", () => {
		const html = render("[docs](https://example.com)");
		expect(html).toContain('target="_blank"');
		expect(html).toContain('href="https://example.com"');
		expect(html).toContain("docs");
	});

	test("applies custom className to wrapper div", () => {
		const html = renderToStaticMarkup(
			<Markdown className="custom-class">hello</Markdown>,
		);
		expect(html).toMatch(/^<div class="custom-class">/);
	});
});
