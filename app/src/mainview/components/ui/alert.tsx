import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const alertVariants = cva("relative w-full rounded-card border p-4 text-body", {
	variants: {
		variant: {
			default: "border-border bg-muted/40 text-foreground",
			destructive: "border-destructive/20 bg-destructive/10 text-destructive",
		},
	},
	defaultVariants: { variant: "default" },
});

function Alert({ className, variant, ...props }: React.ComponentProps<"div"> & VariantProps<typeof alertVariants>) {
	return <div data-slot="alert" role="alert" className={cn(alertVariants({ variant, className }))} {...props} />;
}
function AlertTitle({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="alert-title" className={cn("mb-1 font-medium text-foreground", className)} {...props} />;
}
function AlertDescription({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="alert-description" className={cn("text-muted-foreground", className)} {...props} />;
}

export { Alert, AlertDescription, AlertTitle };
