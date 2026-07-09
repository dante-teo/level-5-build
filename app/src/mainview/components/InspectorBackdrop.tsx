export function InspectorBackdrop({ label, onClose }: { label: string; onClose: () => void }) {
	return (
		<button
			type="button"
			aria-label={label}
			className="electrobun-webkit-app-region-no-drag fixed inset-0 z-40 bg-black/25"
			onClick={onClose}
		/>
	);
}
