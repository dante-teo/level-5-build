import * as React from "react";
import { cn } from "@/lib/utils";

function Command({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="command" className={cn("flex h-full w-full flex-col overflow-hidden rounded-panel text-foreground", className)} {...props} />;
}
function CommandInput({ className, ...props }: React.ComponentProps<"input">) {
	return <input data-slot="command-input" className={cn("h-10 w-full bg-transparent text-body font-medium text-foreground outline-none placeholder:text-muted-foreground", className)} {...props} />;
}
function CommandList({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="command-list" className={cn("app-scrollbar-transparent max-h-56 overflow-y-auto", className)} {...props} />;
}
function CommandEmpty({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="command-empty" className={cn("flex h-10 items-center rounded-2xl px-2 text-body font-semibold text-muted-foreground", className)} {...props} />;
}
function CommandGroup({ className, ...props }: React.ComponentProps<"div">) {
	return <div data-slot="command-group" className={cn("flex flex-col gap-1", className)} {...props} />;
}
function CommandItem({ className, ...props }: React.ComponentProps<"button">) {
	return <button type="button" data-slot="command-item" className={cn("flex h-10 w-full items-center gap-2 rounded-2xl px-2 text-left text-body font-semibold text-foreground outline-none transition-colors hover:bg-muted/70 focus-visible:ring-2 focus-visible:ring-l5-accent/35 disabled:pointer-events-none disabled:opacity-40", className)} {...props} />;
}

export { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList };
