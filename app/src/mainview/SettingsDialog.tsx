import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { Separator } from "@/components/ui/separator";
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

	return (
		<Dialog open onOpenChange={(open) => !open && onClose()}>
			<DialogContent className="max-w-sm" onDoubleClick={(event) => event.stopPropagation()}>
				<div className="flex items-start justify-between gap-3">
					<div>
						<DialogTitle>Settings</DialogTitle>
						<DialogDescription className="mt-1">Configure how Level5 runs coding sessions.</DialogDescription>
					</div>
					<Button
						aria-label="Close settings"
						variant="ghost"
						size="icon"
						className="size-8"
						onClick={onClose}
					>
						<ICONS.close className="size-4" strokeWidth={1.9} />
					</Button>
				</div>

				<Separator className="my-5" />
				<section aria-labelledby="agent-settings-title">
					<h3 id="agent-settings-title" className="text-body font-semibold text-foreground">Agent</h3>
					<p className="mt-1 text-caption text-muted-foreground">Changes apply immediately to the next connection setup.</p>
					<label className="mt-4 block text-caption font-semibold text-muted-foreground" htmlFor="agent-provider">
						Provider
					</label>
					<Select value={provider} disabled={isLoading} onValueChange={(value) => void handleChange(value as AcpProviderId)}>
						<SelectTrigger
							id="agent-provider"
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
				</section>
			</DialogContent>
		</Dialog>
	);
}
