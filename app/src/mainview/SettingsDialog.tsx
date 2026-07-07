import { useEffect, useState } from "react";
import {
	Dialog,
	DialogContent,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { electroview } from "@/lib/electrobun";
import { ACP_PROVIDER_LABELS, type AcpProviderId } from "@shared/rpc";

const ACP_PROVIDER_OPTIONS: Array<{ value: AcpProviderId; label: string }> = [
	{ value: "devin", label: ACP_PROVIDER_LABELS.devin },
	{ value: "omp", label: ACP_PROVIDER_LABELS.omp },
];

export function SettingsDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
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
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogContent aria-describedby={undefined}>
				<DialogHeader>
					<DialogTitle>Settings</DialogTitle>
				</DialogHeader>

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
			</DialogContent>
		</Dialog>
	);
}
