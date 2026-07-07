import * as React from "react";
import * as DropdownMenuPrimitive from "@radix-ui/react-dropdown-menu";
import { CheckIcon, ChevronRightIcon, CircleIcon } from "lucide-react";
import { cn } from "@/lib/utils";

function DropdownMenu(props: React.ComponentProps<typeof DropdownMenuPrimitive.Root>) {
	return <DropdownMenuPrimitive.Root data-slot="dropdown-menu" {...props} />;
}
function DropdownMenuTrigger(props: React.ComponentProps<typeof DropdownMenuPrimitive.Trigger>) {
	return <DropdownMenuPrimitive.Trigger data-slot="dropdown-menu-trigger" {...props} />;
}
function DropdownMenuGroup(props: React.ComponentProps<typeof DropdownMenuPrimitive.Group>) {
	return <DropdownMenuPrimitive.Group data-slot="dropdown-menu-group" {...props} />;
}
function DropdownMenuPortal(props: React.ComponentProps<typeof DropdownMenuPrimitive.Portal>) {
	return <DropdownMenuPrimitive.Portal data-slot="dropdown-menu-portal" {...props} />;
}
function DropdownMenuRadioGroup(props: React.ComponentProps<typeof DropdownMenuPrimitive.RadioGroup>) {
	return <DropdownMenuPrimitive.RadioGroup data-slot="dropdown-menu-radio-group" {...props} />;
}
function DropdownMenuSub(props: React.ComponentProps<typeof DropdownMenuPrimitive.Sub>) {
	return <DropdownMenuPrimitive.Sub data-slot="dropdown-menu-sub" {...props} />;
}
function DropdownMenuSubTrigger({ className, inset, children, ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.SubTrigger> & { inset?: boolean }) {
	return (
		<DropdownMenuPrimitive.SubTrigger className={cn("flex h-10 cursor-default select-none items-center gap-2 rounded-2xl px-2 text-body font-semibold outline-none focus:bg-muted/70 data-[state=open]:bg-muted/70", inset && "pl-8", className)} {...props}>
			{children}
			<ChevronRightIcon className="ml-auto size-4" />
		</DropdownMenuPrimitive.SubTrigger>
	);
}
function DropdownMenuSubContent({ className, ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.SubContent>) {
	return (
		<DropdownMenuPrimitive.SubContent className={cn("l5-adaptive-surface electrobun-webkit-app-region-no-drag z-50 min-w-[8rem] rounded-panel border border-border p-2 text-foreground shadow-e2", className)} {...props} />
	);
}
function DropdownMenuContent({ className, sideOffset = 8, ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.Content>) {
	return (
		<DropdownMenuPrimitive.Portal>
			<DropdownMenuPrimitive.Content
				data-slot="dropdown-menu-content"
				sideOffset={sideOffset}
				className={cn("l5-adaptive-surface electrobun-webkit-app-region-no-drag z-50 min-w-[8rem] rounded-panel border border-border p-2 text-foreground shadow-e2", className)}
				onDoubleClick={(event) => event.stopPropagation()}
				{...props}
			/>
		</DropdownMenuPrimitive.Portal>
	);
}
function DropdownMenuItem({ className, inset, variant = "default", ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.Item> & { inset?: boolean; variant?: "default" | "destructive" }) {
	return (
		<DropdownMenuPrimitive.Item
			data-variant={variant}
			className={cn("relative flex h-10 cursor-default select-none items-center gap-2 rounded-2xl px-2 text-body font-semibold outline-none transition-colors focus:bg-muted/70 data-[disabled]:pointer-events-none data-[disabled]:opacity-40 data-[variant=destructive]:text-destructive data-[variant=destructive]:focus:bg-destructive/10", inset && "pl-8", className)}
			{...props}
		/>
	);
}
function DropdownMenuCheckboxItem({ className, children, checked, ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.CheckboxItem>) {
	return (
		<DropdownMenuPrimitive.CheckboxItem className={cn("relative flex h-10 cursor-default select-none items-center gap-2 rounded-2xl py-1.5 pl-8 pr-2 text-body font-semibold outline-none focus:bg-muted/70 data-[disabled]:pointer-events-none data-[disabled]:opacity-40", className)} checked={checked} {...props}>
			<span className="absolute left-2 flex size-4 items-center justify-center">
				<DropdownMenuPrimitive.ItemIndicator><CheckIcon className="size-4" /></DropdownMenuPrimitive.ItemIndicator>
			</span>
			{children}
		</DropdownMenuPrimitive.CheckboxItem>
	);
}
function DropdownMenuRadioItem({ className, children, ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.RadioItem>) {
	return (
		<DropdownMenuPrimitive.RadioItem className={cn("relative flex cursor-default select-none items-start gap-3 rounded-2xl py-2.5 pl-8 pr-2 text-body outline-none focus:bg-muted/70 data-[disabled]:pointer-events-none data-[disabled]:opacity-40", className)} {...props}>
			<span className="absolute left-2 top-3 flex size-4 items-center justify-center">
				<DropdownMenuPrimitive.ItemIndicator><CircleIcon className="size-2 fill-current" /></DropdownMenuPrimitive.ItemIndicator>
			</span>
			{children}
		</DropdownMenuPrimitive.RadioItem>
	);
}
function DropdownMenuLabel({ className, inset, ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.Label> & { inset?: boolean }) {
	return <DropdownMenuPrimitive.Label className={cn("px-2 py-1.5 text-caption font-semibold text-muted-foreground", inset && "pl-8", className)} {...props} />;
}
function DropdownMenuSeparator({ className, ...props }: React.ComponentProps<typeof DropdownMenuPrimitive.Separator>) {
	return <DropdownMenuPrimitive.Separator className={cn("-mx-1 my-2 h-px bg-border", className)} {...props} />;
}
function DropdownMenuShortcut({ className, ...props }: React.ComponentProps<"span">) {
	return <span className={cn("ml-auto text-caption tracking-widest text-muted-foreground", className)} {...props} />;
}

export {
	DropdownMenu,
	DropdownMenuCheckboxItem,
	DropdownMenuContent,
	DropdownMenuGroup,
	DropdownMenuItem,
	DropdownMenuLabel,
	DropdownMenuPortal,
	DropdownMenuRadioGroup,
	DropdownMenuRadioItem,
	DropdownMenuSeparator,
	DropdownMenuShortcut,
	DropdownMenuSub,
	DropdownMenuSubContent,
	DropdownMenuSubTrigger,
	DropdownMenuTrigger,
};
