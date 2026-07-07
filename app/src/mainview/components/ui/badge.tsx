import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const badgeVariants = cva("inline-flex items-center rounded-chip px-2 py-0.5 text-caption font-medium", {
	variants: {
		variant: {
			default: "bg-l5-selected-surface text-l5-accent",
			secondary: "bg-muted text-muted-foreground",
			success: "bg-l5-success/10 text-l5-success",
			warning: "bg-l5-warning/10 text-l5-warning",
			destructive: "bg-destructive/10 text-destructive",
			outline: "border border-border text-muted-foreground",
		},
	},
	defaultVariants: { variant: "default" },
});

function Badge({ className, variant, ...props }: React.ComponentProps<"span"> & VariantProps<typeof badgeVariants>) {
	return <span data-slot="badge" className={cn(badgeVariants({ variant, className }))} {...props} />;
}

export { Badge, badgeVariants };
