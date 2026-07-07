import { useEffect, useState } from "react";
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { electroview } from "@/lib/electrobun";
import { ICONS } from "@/lib/icon-map";
import { ACP_PROVIDER_LABELS, type AcpProviderId } from "@shared/rpc";

const ACP_PROVIDER_OPTIONS: Array<{ value: AcpProviderId; label: string }> = [
	{ value: "devin", label: ACP_PROVIDER_LABELS.devin },
	{ value: "omp", label: ACP_PROVIDER_LABELS.omp },
];

export function SettingsDialog({ onClose }: { onClose: () => void }) {
	const [provider, setProvider] = useState<AcpProviderId>("devin");
	const [isLoading, setIsLoading] = useState(true);

	useEffect(() => {
		let cancelled = false;
		electroview.rpc?.request
			.getAcpProvider()
			.then((value) => {
				if (!cancelled && value) setProvider(value);
			})
			.finally(() => {
				if (!cancelled) setIsLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, []);

	async function handleChange(next: AcpProviderId) {
		setProvider(next);
		await electroview.rpc?.request.setAcpProvider({ provider: next });
	}

	useEffect(() => {
		function handleKeyDown(event: KeyboardEvent) {
			if (event.key === "Escape") onClose();
		}
		window.addEventListener("keydown", handleKeyDown);
		return () => window.removeEventListener("keydown", handleKeyDown);
	}, [onClose]);

	return (
		<div
			className="electrobun-webkit-app-region-no-drag fixed inset-0 z-40 flex items-center justify-center bg-foreground/18 p-6 backdrop-blur-md"
			role="presentation"
			onDoubleClick={(event) => event.stopPropagation()}
			onMouseDown={(event) => {
				if (event.target === event.currentTarget) onClose();
			}}
		>
			<section
				role="dialog"
				aria-modal="true"
				aria-labelledby="settings-title"
				className="l5-adaptive-surface w-full max-w-sm rounded-panel border border-border p-5 shadow-e3"
			>
				<div className="flex items-start justify-between gap-3">
					<h2 id="settings-title" className="text-h3 font-semibold text-foreground">
						Settings
					</h2>
					<button
						type="button"
						aria-label="Close settings"
						className="flex size-8 shrink-0 items-center justify-center rounded-2xl text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
						onClick={onClose}
					>
						<ICONS.close className="size-4" strokeWidth={1.9} />
					</button>
				</div>

				<div className="mt-5">
					<div className="block text-caption font-semibold text-muted-foreground">
						Agent provider
					</div>
					<Select value={provider} disabled={isLoading} onValueChange={(value) => void handleChange(value as AcpProviderId)}>
						<SelectTrigger
							aria-label="Agent provider"
							className="mt-2 h-10 w-full border-border bg-l5-surface px-3 text-body font-medium"
						>
							<SelectValue />
						</SelectTrigger>
						<SelectContent position="popper" align="start">
							<SelectGroup>
								{ACP_PROVIDER_OPTIONS.map((option) => (
									<SelectItem key={option.value} value={option.value}>
										{option.label}
									</SelectItem>
								))}
							</SelectGroup>
						</SelectContent>
					</Select>
				</div>
			</section>
		</div>
	);
}
