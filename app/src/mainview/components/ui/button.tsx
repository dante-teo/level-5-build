import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

export const buttonVariants = cva(
	"inline-flex shrink-0 items-center justify-center gap-2 rounded-medium text-body font-semibold outline-none transition-colors focus-visible:ring-2 focus-visible:ring-l5-accent/45 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0",
	{
		variants: {
			variant: {
				default: "bg-l5-accent text-l5-accent-foreground hover:bg-l5-accent/90",
				destructive: "bg-l5-danger text-l5-danger-foreground hover:bg-l5-danger/90",
				outline: "border border-border bg-l5-surface text-foreground hover:bg-muted",
				secondary: "bg-muted text-foreground hover:bg-muted/75",
				ghost: "text-muted-foreground hover:bg-muted/70 hover:text-foreground",
			},
			size: {
				default: "h-9 px-4",
				sm: "h-8 px-3 text-caption",
				icon: "size-9",
			},
		},
		defaultVariants: { variant: "default", size: "default" },
	},
);

export type ButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> & VariantProps<typeof buttonVariants>;

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(({ className, variant, size, type = "button", ...props }, ref) => (
	<button ref={ref} type={type} className={cn(buttonVariants({ variant, size }), className)} {...props} />
));
Button.displayName = "Button";
