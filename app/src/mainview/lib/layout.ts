export type InspectorId = "dashboard" | "review";
export type InspectorPresentation = "closed" | "panel" | "drawer";

export type InspectorLayout = {
	dashboard: InspectorPresentation;
	review: InspectorPresentation;
	shouldCollapseSidebar: boolean;
	closedForFit: InspectorId | null;
};

export type InspectorLayoutInput = {
	viewportWidth: number;
	sidebarExpanded: boolean;
	sidebarWidth: number;
	dashboardOpen: boolean;
	reviewOpen: boolean;
	dashboardOpenedAt: number;
	reviewOpenedAt: number;
	dashboardWidth?: number;
	reviewWidth?: number;
	minimumWorkspaceWidth?: number;
	compactBreakpoint?: number;
};

function mostRecentlyOpenedInspector({
	dashboardOpen,
	reviewOpen,
	dashboardOpenedAt,
	reviewOpenedAt,
}: Pick<InspectorLayoutInput, "dashboardOpen" | "reviewOpen" | "dashboardOpenedAt" | "reviewOpenedAt">): InspectorId | null {
	if (!dashboardOpen) return reviewOpen ? "review" : null;
	if (!reviewOpen) return "dashboard";
	return dashboardOpenedAt >= reviewOpenedAt ? "dashboard" : "review";
}

export function resolveInspectorLayout({
	viewportWidth,
	sidebarExpanded,
	sidebarWidth,
	dashboardOpen,
	reviewOpen,
	dashboardOpenedAt,
	reviewOpenedAt,
	dashboardWidth = 384,
	reviewWidth = 600,
	minimumWorkspaceWidth = 520,
	compactBreakpoint = 900,
}: InspectorLayoutInput): InspectorLayout {
	const result: InspectorLayout = {
		dashboard: dashboardOpen ? "panel" : "closed",
		review: reviewOpen ? "panel" : "closed",
		shouldCollapseSidebar: false,
		closedForFit: null,
	};
	const requiredPanelWidth = minimumWorkspaceWidth + (dashboardOpen ? dashboardWidth : 0) + (reviewOpen ? reviewWidth : 0);
	const availableWithSidebar = viewportWidth - (sidebarExpanded ? sidebarWidth : 0);
	const mostRecentInspector = mostRecentlyOpenedInspector({
		dashboardOpen,
		reviewOpen,
		dashboardOpenedAt,
		reviewOpenedAt,
	});
	if (requiredPanelWidth > availableWithSidebar && sidebarExpanded && requiredPanelWidth <= viewportWidth) {
		result.shouldCollapseSidebar = true;
	}

	if (viewportWidth < compactBreakpoint) {
		result.dashboard = mostRecentInspector === "dashboard" ? "drawer" : "closed";
		result.review = mostRecentInspector === "review" ? "drawer" : "closed";
		result.closedForFit = dashboardOpen && reviewOpen
			? mostRecentInspector === "dashboard"
				? "review"
				: "dashboard"
			: null;
		result.shouldCollapseSidebar = sidebarExpanded && mostRecentInspector !== null;
		return result;
	}

	if (requiredPanelWidth > viewportWidth && dashboardOpen && reviewOpen && mostRecentInspector) {
		const survivingInspectorWidth = mostRecentInspector === "dashboard" ? dashboardWidth : reviewWidth;
		const presentation: InspectorPresentation =
			minimumWorkspaceWidth + survivingInspectorWidth <= viewportWidth ? "panel" : "drawer";
		result.dashboard = mostRecentInspector === "dashboard" ? presentation : "closed";
		result.review = mostRecentInspector === "review" ? presentation : "closed";
		result.closedForFit = mostRecentInspector === "dashboard" ? "review" : "dashboard";
		result.shouldCollapseSidebar = sidebarExpanded;
	} else if (requiredPanelWidth > viewportWidth) {
		result.dashboard = dashboardOpen ? "drawer" : "closed";
		result.review = reviewOpen ? "drawer" : "closed";
		result.shouldCollapseSidebar = sidebarExpanded;
	}
	return result;
}
