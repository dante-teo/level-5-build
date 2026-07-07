import * as React from "react";
import { cn } from "@/lib/utils";

function Input({ className, type, ...props }: React.ComponentProps<"input">) {
	return (
		<input
			type={type}
			data-slot="input"
			className={cn("electrobun-webkit-app-region-no-drag flex h-10 w-full rounded-input border border-border bg-l5-surface px-3 py-1.5 text-body text-foreground outline-none transition-[border-color,box-shadow] placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-l5-accent/35 disabled:cursor-not-allowed disabled:opacity-50", className)}
			{...props}
		/>
	);
}

export { Input };
