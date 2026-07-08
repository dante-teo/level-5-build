// Browser-harness shim: emulates the Electrobun webview bridge so the real
// mainview UI renders in a plain browser tab with realistic mock data.
// Injected via page.evaluateOnNewDocument by design/QA tooling only —
// never loaded by the real app (the native shell injects a real
// window.__electrobun before main.tsx runs, and this file is not imported
// anywhere in src/).
//
// Wire protocol (see electrobun/dist/api/shared/rpc.ts):
//   outgoing (webview -> bun): window.__electrobunBunBridge.postMessage(jsonString)
//     { type: "request", id, method, params } | { type: "response", ... }
//   incoming (bun -> webview): window.__electrobun.receiveMessageFromBun(object)
//     { type: "response", id, success, payload } | { type: "message", id, payload }
//
// Scenario is chosen via localStorage("l5-harness-scenario") or
// window.__L5_SCENARIO set before load: "empty" | "conversation".

(() => {
	const now = Date.now();
	const iso = (msAgo) => new Date(now - msAgo).toISOString();

	const scenario =
		typeof window.__L5_SCENARIO === "string"
			? window.__L5_SCENARIO
			: (() => {
					try {
						return localStorage.getItem("l5-harness-scenario") || "empty";
					} catch {
						return "empty";
					}
				})();

	const HOME = "/Users/dev";
	const PROJECT = `${HOME}/Projects/level-5-build`;

	const sessions = [
		{ sessionId: "s-current", title: "Polish the composer focus ring", cwd: PROJECT, updatedAt: iso(60_000), messageCount: 6 },
		{ sessionId: "s-2", title: "Fix review pane diff overflow", cwd: PROJECT, updatedAt: iso(3_600_000), messageCount: 14 },
		{ sessionId: "s-3", title: "Add keyboard shortcuts for panels", cwd: PROJECT, updatedAt: iso(7_200_000), messageCount: 9 },
		{ sessionId: "s-4", title: "Investigate slow git status calls", cwd: `${HOME}/Projects/acp-mock-server`, updatedAt: iso(86_400_000), messageCount: 22 },
		{ sessionId: "s-5", title: "Rename provider setting copy", cwd: PROJECT, updatedAt: iso(172_800_000), messageCount: 4 },
	];

	const recentProjects = [
		{ path: PROJECT, displayName: "level-5-build" },
		{ path: `${HOME}/Projects/acp-mock-server`, displayName: "acp-mock-server" },
		{ path: `${HOME}/Projects/dotfiles`, displayName: "dotfiles" },
	];

	const configOptions = [
		{
			id: "model",
			name: "Model",
			currentValue: "claude-sonnet-4",
			options: [
				{ value: "claude-sonnet-4", name: "Claude Sonnet 4" },
				{ value: "claude-opus-4", name: "Claude Opus 4" },
				{ value: "gpt-5", name: "GPT-5" },
			],
		},
	];

	const slashCommands = [
		{ name: "review", description: "Review the current local diff" },
		{ name: "plan", description: "Draft an implementation plan first" },
		{ name: "test", description: "Write tests for recent changes" },
	];

	const transcript = [
		{ kind: "message", role: "user", messageId: "u1", content: { type: "text", text: "Polish the composer so the focus ring uses the accent token, and make sure dark mode still passes contrast." } },
		{ kind: "thought", messageId: "t1", content: { type: "text", text: "The composer currently uses a hardcoded blue for its focus ring. I should swap it to the accent token and verify both themes." } },
		{ kind: "tool", tool: { toolCallId: "tc1", title: "Read index.css", kind: "read", status: "completed", content: [{ type: "content", content: { type: "text", text: "--l5-accent: #3f5cf5;\n--l5-accent-foreground: #ffffff;" } }] } },
		{ kind: "tool", tool: { toolCallId: "tc2", title: "Read App.tsx", kind: "read", status: "completed" } },
		{ kind: "tool", tool: { toolCallId: "tc3", title: "Edit App.tsx", kind: "edit", status: "completed", content: [{ type: "diff", path: "src/mainview/App.tsx", oldText: "focus:ring-blue-500", newText: "focus-visible:ring-l5-accent/35" }] } },
		{ kind: "tool", tool: { toolCallId: "tc4", title: "Edit index.css", kind: "edit", status: "completed", content: [{ type: "diff", path: "src/mainview/index.css", oldText: ".ring { color: blue; }", newText: ".ring { color: var(--l5-accent); }" }] } },
		{ kind: "message", role: "agent", messageId: "a1", content: { type: "text", text: "Done. I swapped the composer's focus ring to `ring-l5-accent/35` and verified both themes:\n\n- **Light**: ring renders at 35% accent over `#FAFAFC` — passes AA.\n- **Dark**: accent token flips to `#6F8DFF`, ring stays visible on `#131416`.\n\nNo other hardcoded focus colors remain in the composer." } },
		{ kind: "message", role: "user", messageId: "u2", content: { type: "text", text: "Great — now check the sidebar selected state too." } },
		{ kind: "thought", messageId: "t2", content: { type: "text", text: "Looking at the sidebar row styles for the selected state treatment now." } },
		{ kind: "tool", tool: { toolCallId: "tc5", title: "grep selected-surface", kind: "search", status: "in_progress" } },
		{ kind: "plan", items: [
			{ title: "Swap composer focus ring to accent token", status: "completed" },
			{ title: "Verify light/dark contrast", status: "completed" },
			{ title: "Audit sidebar selected state", status: "in_progress" },
			{ title: "Run typecheck and tests", status: "pending" },
		] },
		{ kind: "usage", used: 46_000, size: 200_000 },
	];

	const gitStatus = {
		ok: true,
		root: PROJECT,
		branch: "feat/design-polish",
		isDetached: false,
		changedFiles: 4,
		additions: 182,
		deletions: 57,
		hasUntracked: true,
	};

	const reviewSnapshot = {
		isAvailable: true,
		root: PROJECT,
		branch: "feat/design-polish",
		isDetached: false,
		totalChangedFiles: 4,
		overflowCount: 0,
		files: [
			{ path: "app/src/mainview/App.tsx", indexStatus: " ", workingTreeStatus: "M", changeKind: "modified", contentKind: "text", additions: 96, deletions: 40 },
			{ path: "app/src/mainview/index.css", indexStatus: "M", workingTreeStatus: "M", changeKind: "modified", contentKind: "text", additions: 62, deletions: 17 },
			{ path: "app/src/mainview/lib/motion.ts", indexStatus: "?", workingTreeStatus: "?", changeKind: "untracked", contentKind: "text", additions: 24, deletions: 0 },
			{ path: "docs/DESIGN.md", indexStatus: "M", workingTreeStatus: " ", changeKind: "modified", contentKind: "text", additions: 0, deletions: 0 },
		],
	};

	const sampleDiff = `diff --git a/app/src/mainview/App.tsx b/app/src/mainview/App.tsx
index 3c1a2b4..9f8e7d6 100644
--- a/app/src/mainview/App.tsx
+++ b/app/src/mainview/App.tsx
@@ -12,7 +12,7 @@ function Composer() {
 	return (
 		<div
 			className={cn(
-				"focus:ring-blue-500",
+				"focus-visible:ring-l5-accent/35",
 				className,
 			)}
 		>
@@ -40,6 +40,8 @@ function Composer() {
 	const ring = useAccentRing();
+	const reduceMotion = usePrefersReducedMotion();
+	const duration = reduceMotion ? 0 : 180;
 	return ring;
 }`;

	const handlers = {
		toggleMaximizeWindow: () => true,
		selectProjectFolder: () => PROJECT,
		selectAttachmentFile: () => `${PROJECT}/docs/DESIGN.md`,
		selectAttachmentFolder: () => `${PROJECT}/app/src`,
		startAgentPrompt: () => ({ accepted: true, sessionId: "s-current" }),
		prepareAgentSession: () => ({ prepared: true, sessionId: "s-current" }),
		cancelAgentPrompt: () => true,
		respondToAgentPermission: () => true,
		listAgentSessions: () => sessions,
		listRecentProjects: () => recentProjects,
		getAcpProvider: () => "devin",
		setAcpProvider: () => true,
		listAgentSlashCommands: () => slashCommands,
		listAgentConfigOptions: () => configOptions,
		listAgentSkills: () => [],
		getSessionTranscript: () => transcript,
		deleteAgentSession: () => ({ deleted: true }),
		startNewAgentChat: () => true,
		resetAgentChat: () => true,
		getProjectGitStatus: () => gitStatus,
		getProjectReviewSnapshot: () => reviewSnapshot,
		getFileDiffPreview: (params) => ({
			file: params.file,
			content: { kind: "unifiedDiff", diff: sampleDiff },
		}),
	};

	function deliver(packet) {
		const receive = window.__electrobun && window.__electrobun.receiveMessageFromBun;
		if (typeof receive === "function") {
			receive(packet);
		}
	}

	window.__electrobun = window.__electrobun || {};
	window.__electrobunBunBridge = {
		postMessage(jsonString) {
			let packet;
			try {
				packet = JSON.parse(jsonString);
			} catch {
				return;
			}
			if (packet.type !== "request") {
				return;
			}
			const handler = handlers[packet.method];
			// Deliver asynchronously like a real IPC round trip.
			setTimeout(() => {
				if (!handler) {
					deliver({ type: "response", id: packet.id, success: false, error: `The requested method has no handler: ${packet.method}` });
					return;
				}
				deliver({ type: "response", id: packet.id, success: true, payload: handler(packet.params) });
			}, 10);
		},
	};

	// Push channel helper for scenario scripts / manual driving from the
	// devtools console: window.__l5Push({ sessionId, update }).
	window.__l5Push = (payload) => deliver({ type: "message", id: "agentUpdate", payload });

	if (scenario === "conversation") {
		// Simulate selecting the current session shortly after mount so the
		// transcript hydrates through the app's own selection path.
		window.__l5LoadConversation = () => {
			for (const update of transcript) {
				deliver({ type: "message", id: "agentUpdate", payload: { sessionId: "s-current", update } });
			}
		};
	}
})();
