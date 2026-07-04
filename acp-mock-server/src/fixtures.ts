import type { JsonObject } from "./types.js";

export const supportedModes = [
	{
		id: "ask",
		name: "Ask",
		description: "Request permission before simulated edits, commands, and mode switches."
	},
	{
		id: "architect",
		name: "Architect",
		description: "Produce plans, tradeoffs, and review notes without simulated implementation."
	},
	{
		id: "code",
		name: "Code",
		description: "Simulate reading, editing, testing, and reporting concrete implementation progress."
	},
	{
		id: "auto",
		name: "Auto",
		description: "Proceed through routine simulated tools without asking for permission."
	}
] as const;

export const defaultConfig = {
	mode: "ask",
	model: "mock-pro",
	reasoning: "high",
	verbosity: "balanced",
	autonomy: "guided",
	skillset: "full-stack"
};

export const mockModels = [
	{ id: "mock-fast", name: "Mock Fast", description: "Shorter responses and quicker tool updates.", contextWindow: 64000 },
	{ id: "mock-pro", name: "Mock Pro", description: "Balanced testing behavior.", contextWindow: 200000 },
	{ id: "mock-deep", name: "Mock Deep", description: "More planning and richer tool narratives.", contextWindow: 1000000 }
] as const;

export function modelContextWindow(modelId: string): number {
	return mockModels.find((model) => model.id === modelId)?.contextWindow ?? mockModels[1].contextWindow;
}

export function buildConfigOptions(config: Record<string, string>): JsonObject[] {
	return [
		{
			id: "model",
			name: "Model",
			description: "Mock model personality used for timing and confidence claims.",
			category: "model",
			type: "select",
			currentValue: config.model ?? defaultConfig.model,
			options: mockModels.map(({ id, name, description }) => ({ value: id, name, description }))
		}
	];
}

export function buildAllConfigOptions(config: Record<string, string>): JsonObject[] {
	return [
		{
			id: "mode",
			name: "Session Mode",
			description: "Controls how the mock agent asks for permission.",
			category: "mode",
			type: "select",
			currentValue: config.mode ?? defaultConfig.mode,
			options: supportedModes.map((mode) => ({
				value: mode.id,
				name: mode.name,
				description: mode.description
			}))
		},
		...buildConfigOptions(config),
		{
			id: "reasoning",
			name: "Reasoning",
			description: "How much visible planning the mock streams.",
			category: "thought_level",
			type: "select",
			currentValue: config.reasoning ?? defaultConfig.reasoning,
			options: [
				{ value: "low", name: "Low", description: "Minimal plan updates." },
				{ value: "medium", name: "Medium", description: "A normal amount of progress reporting." },
				{ value: "high", name: "High", description: "Detailed plan and tool updates." }
			]
		},
		{
			id: "verbosity",
			name: "Verbosity",
			description: "Controls the length of final mock answers.",
			category: "model_config",
			type: "select",
			currentValue: config.verbosity ?? defaultConfig.verbosity,
			options: [
				{ value: "concise", name: "Concise", description: "Short answer." },
				{ value: "balanced", name: "Balanced", description: "Practical summary with key details." },
				{ value: "detailed", name: "Detailed", description: "Longer test payloads." }
			]
		},
		{
			id: "autonomy",
			name: "Autonomy",
			description: "How readily the mock pretends to take actions.",
			category: "model_config",
			type: "select",
			currentValue: config.autonomy ?? defaultConfig.autonomy,
			options: [
				{ value: "read-only", name: "Read Only", description: "Analysis and search only." },
				{ value: "guided", name: "Guided", description: "Ask before sensitive simulated actions." },
				{ value: "eager", name: "Eager", description: "Move through edit/test flows quickly." }
			]
		},
		{
			id: "skillset",
			name: "Skillset",
			description: "Mock skill profile exposed to clients.",
			category: "_mock_skillset",
			type: "select",
			currentValue: config.skillset ?? defaultConfig.skillset,
			options: [
				{ value: "full-stack", name: "Full Stack", description: "Web app, API, test, and docs skills." },
				{ value: "reviewer", name: "Reviewer", description: "Code review and risk analysis." },
				{ value: "designer", name: "Designer", description: "Frontend UX and polish-oriented behavior." },
				{ value: "infra", name: "Infra", description: "Build, CI, release, and deployment workflows." }
			]
		}
	];
}

export const availableCommands = [
	{ name: "help", description: "Show mock agent capabilities and command examples." },
	{ name: "plan", description: "Create a detailed implementation plan.", input: { hint: "feature or fix to plan" } },
	{ name: "review", description: "Review code and report risks.", input: { hint: "file, diff, or area to review" } },
	{ name: "fix", description: "Simulate a code edit with a diff.", input: { hint: "bug or failing behavior" } },
	{ name: "test", description: "Simulate running tests and reporting results.", input: { hint: "test target or command" } }
] as const;

export const hiddenScenarioCommands = [
	{ name: "search", description: "Simulate searching the workspace.", input: { hint: "query" } },
	{ name: "web", description: "Simulate fetching current external information.", input: { hint: "query to fetch" } },
	{ name: "explain", description: "Explain a file, error, or concept.", input: { hint: "thing to explain" } },
	{ name: "skills", description: "List the mock skill profiles this server can pretend to use." },
	{ name: "mode", description: "Switch mock mode by text, for example /mode code.", input: { hint: "ask, architect, code, or auto" } },
	{ name: "fail", description: "Force a failed tool call for client error-state testing." },
	{ name: "progress-demo", description: "Run one deterministic turn with plan, tools, usage, permission, and completion states." },
	{ name: "refuse", description: "Force a refusal stop reason." },
	{ name: "tokens", description: "Force a max_tokens stop reason." }
];

export const mockSkills = [
	{
		id: "workspace-search",
		name: "Workspace Search",
		description: "Finds files, symbols, and references across a project."
	},
	{
		id: "code-editor",
		name: "Code Editor",
		description: "Produces diff content and explains simulated file changes."
	},
	{
		id: "test-runner",
		name: "Test Runner",
		description: "Streams command-style progress and pass/fail summaries."
	},
	{
		id: "reviewer",
		name: "Reviewer",
		description: "Reports severity-ranked findings with file locations."
	},
	{
		id: "web-fetch",
		name: "Web Fetch",
		description: "Pretends to retrieve current references for UI testing."
	},
	{
		id: "planner",
		name: "Planner",
		description: "Streams complete ACP plan replacement updates."
	}
];
