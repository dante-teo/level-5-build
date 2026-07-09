import type { ButtonHTMLAttributes, ReactNode } from "react";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { WINDOW_TOP_CONTROL_SIZE } from "@shared/windowChrome";

type TopBarGlassButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
	children: ReactNode;
	tooltip: string;
};

export function TopBarGlassButton({ children, className, style, tooltip, ...props }: TopBarGlassButtonProps) {
	return (
		<TooltipProvider delayDuration={450}>
			<Tooltip>
				<TooltipTrigger asChild>
					<button
						type="button"
						className={cn(
							"l5-top-control electrobun-webkit-app-region-no-drag flex shrink-0 items-center justify-center rounded-full text-l5-topbar-control transition-colors hover:text-l5-topbar-control focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-l5-accent/45 disabled:cursor-not-allowed",
							className,
						)}
						style={{ width: WINDOW_TOP_CONTROL_SIZE, height: WINDOW_TOP_CONTROL_SIZE, ...style }}
						{...props}
					>
						{children}
					</button>
				</TooltipTrigger>
				<TooltipContent>{tooltip}</TooltipContent>
			</Tooltip>
		</TooltipProvider>
	);
}
