import * as React from "react";
import { cn } from "@/lib/utils";

function Empty({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="empty" className={cn("flex flex-col items-center justify-center gap-2 text-center text-body text-muted-foreground", className)} {...props} />;
}
function EmptyHeader({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="empty-header" className={cn("font-semibold text-foreground", className)} {...props} />;
}
function EmptyDescription({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="empty-description" className={cn("text-caption font-medium text-muted-foreground", className)} {...props} />;
}

export { Empty, EmptyDescription, EmptyHeader };
