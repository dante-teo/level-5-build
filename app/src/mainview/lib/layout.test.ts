import { describe, expect, test } from "bun:test";
import { resolveInspectorLayout } from "./layout";

describe("resolveInspectorLayout", () => {
	test("keeps both panels when the readable workspace fits", () => {
		expect(resolveInspectorLayout({
			viewportWidth: 1800, sidebarExpanded: true, sidebarWidth: 280,
			dashboardOpen: true, reviewOpen: true, dashboardOpenedAt: 1, reviewOpenedAt: 2,
		})).toMatchObject({ dashboard: "panel", review: "panel", closedForFit: null });
	});

	test("collapses the sidebar before dropping an inspector", () => {
		expect(resolveInspectorLayout({
			viewportWidth: 1540, sidebarExpanded: true, sidebarWidth: 300,
			dashboardOpen: true, reviewOpen: true, dashboardOpenedAt: 1, reviewOpenedAt: 2,
		})).toMatchObject({ shouldCollapseSidebar: true, dashboard: "panel", review: "panel" });
	});

	test("retains only the most recently opened inspector when both cannot fit", () => {
		expect(resolveInspectorLayout({
			viewportWidth: 1200, sidebarExpanded: false, sidebarWidth: 0,
			dashboardOpen: true, reviewOpen: true, dashboardOpenedAt: 4, reviewOpenedAt: 9,
		})).toMatchObject({ dashboard: "closed", review: "panel", closedForFit: "dashboard" });
	});

	test("uses a drawer at compact widths", () => {
		expect(resolveInspectorLayout({
			viewportWidth: 760, sidebarExpanded: true, sidebarWidth: 280,
			dashboardOpen: true, reviewOpen: false, dashboardOpenedAt: 3, reviewOpenedAt: 0,
		})).toMatchObject({ dashboard: "drawer", review: "closed", shouldCollapseSidebar: true });
	});

	test("uses a drawer when one inspector cannot preserve the workspace", () => {
		expect(resolveInspectorLayout({
			viewportWidth: 1000, sidebarExpanded: false, sidebarWidth: 0,
			dashboardOpen: false, reviewOpen: true, dashboardOpenedAt: 0, reviewOpenedAt: 3,
		})).toMatchObject({ dashboard: "closed", review: "drawer" });
	});

	test("turns the surviving inspector into a drawer when closing the older one is not enough", () => {
		expect(resolveInspectorLayout({
			viewportWidth: 1000, sidebarExpanded: false, sidebarWidth: 0,
			dashboardOpen: true, reviewOpen: true, dashboardOpenedAt: 1, reviewOpenedAt: 2,
		})).toMatchObject({ dashboard: "closed", review: "drawer", closedForFit: "dashboard" });
	});
});
