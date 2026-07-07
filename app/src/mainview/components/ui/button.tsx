import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
	"electrobun-webkit-app-region-no-drag inline-flex shrink-0 items-center justify-center gap-2 whitespace-nowrap rounded-button text-body font-semibold outline-none transition-colors focus-visible:ring-2 focus-visible:ring-l5-accent/35 disabled:pointer-events-none disabled:opacity-40 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
	{
		variants: {
			variant: {
				default: "bg-foreground text-background shadow-e2 hover:bg-foreground/90",
				destructive: "bg-destructive text-primary-foreground shadow-e2 hover:bg-destructive/90",
				outline: "border border-border bg-l5-surface text-foreground shadow-e1 hover:bg-muted/70",
				secondary: "bg-muted text-foreground hover:bg-muted/80",
				ghost: "text-muted-foreground hover:bg-muted/70 hover:text-foreground",
				glass: "text-l5-glass-muted hover:bg-l5-glass-control-hover hover:text-l5-glass-text",
			},
			size: {
				default: "h-10 px-4",
				sm: "h-8 rounded-medium px-3 text-caption",
				lg: "h-11 px-5",
				icon: "size-10 rounded-2xl",
				"icon-sm": "size-8 rounded-medium",
				"icon-xs": "size-5 rounded-full",
			},
		},
		defaultVariants: {
			variant: "default",
			size: "default",
		},
	},
);

function Button({
	className,
	variant,
	size,
	asChild = false,
	...props
}: React.ComponentProps<"button"> &
	VariantProps<typeof buttonVariants> & {
		asChild?: boolean;
	}) {
	const Comp = asChild ? Slot : "button";
	return <Comp data-slot="button" className={cn(buttonVariants({ variant, size, className }))} {...props} />;
}

export { Button, buttonVariants };
