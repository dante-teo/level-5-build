import * as React from "react";
import { cn } from "@/lib/utils";

function Textarea({ className, ...props }: React.ComponentProps<"textarea">) {
	return (
		<textarea
			data-slot="textarea"
			className={cn("electrobun-webkit-app-region-no-drag min-h-20 w-full resize-none rounded-input border border-border bg-l5-surface px-3 py-2 text-body text-foreground outline-none transition-[border-color,box-shadow] placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-l5-accent/35 disabled:cursor-not-allowed disabled:opacity-50", className)}
			{...props}
		/>
	);
}

export { Textarea };
