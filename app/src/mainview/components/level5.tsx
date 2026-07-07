import type { ButtonHTMLAttributes, ReactNode } from "react";
import { Button, type buttonVariants } from "@/components/ui/button";
import { Badge, type badgeVariants } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import type { VariantProps } from "class-variance-authority";

type IconButtonProps = Omit<ButtonHTMLAttributes<HTMLButtonElement>, "type"> &
	VariantProps<typeof buttonVariants> & {
		children: ReactNode;
		label: string;
	};

function IconButton({ children, label, className, variant = "ghost", size = "icon", ...props }: IconButtonProps) {
	return (
		<Button type="button" aria-label={label} title={label} variant={variant} size={size} className={className} {...props}>
			{children}
		</Button>
	);
}

function SidebarNavButton({ className, ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
	return (
		<Button
			type="button"
			variant="glass"
			className={cn("h-11 w-full justify-start gap-3 px-3 text-left", className)}
			{...props}
		/>
	);
}

function SurfaceCard({ className, ...props }: React.ComponentProps<"div">) {
	return <Card className={cn("bg-l5-elevated-surface", className)} {...props} />;
}

function StatusBadge({ className, ...props }: React.ComponentProps<typeof Badge> & VariantProps<typeof badgeVariants>) {
	return <Badge className={className} {...props} />;
}

function AttachmentBadge({ className, ...props }: React.ComponentProps<typeof Badge>) {
	return <Badge variant="secondary" className={cn("max-w-full gap-1.5 px-3 py-1.5 text-[13px] text-foreground", className)} {...props} />;
}

export { AttachmentBadge, IconButton, SidebarNavButton, StatusBadge, SurfaceCard };
