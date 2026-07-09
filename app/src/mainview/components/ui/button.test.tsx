import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { TopBarGlassButton } from "@/components/TopBarGlassButton";
import { Button, buttonVariants } from "./button";

test("button variants expose Level5 semantic styles", () => {
	expect(buttonVariants({ variant: "destructive" })).toContain("bg-l5-danger");
	expect(buttonVariants({ variant: "ghost", size: "icon" })).toContain("size-9");
	expect(renderToStaticMarkup(<Button variant="outline">Open</Button>)).toContain("border-border");
});

test("top-bar controls keep the tokenized liquid-glass surface and shared size", () => {
	const markup = renderToStaticMarkup(<TopBarGlassButton tooltip="Review">R</TopBarGlassButton>);
	expect(markup).toContain("l5-top-control");
	expect(markup).toContain("width:36px");
	expect(markup).toContain("height:36px");
});
