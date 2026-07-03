import type { ElectrobunConfig } from "electrobun";

export default {
	app: {
		name: "Level5 Build",
		identifier: "io.anvia.level5.build",
		version: "0.0.0",
	},
	build: {
		bun: {
			entrypoint: "src/bun/index.ts",
		},
		// Vite builds to dist/, we copy from there
		copy: {
			"dist/index.html": "views/mainview/index.html",
			"dist/assets": "views/mainview/assets",
			"../acp-mock-server/src": "acp-mock-server/src",
			"../acp-mock-server/package.json": "acp-mock-server/package.json",
			"../acp-mock-server/start.sh": "acp-mock-server/start.sh",
			"../acp-mock-server/tsconfig.json": "acp-mock-server/tsconfig.json",
		},
		// Ignore Vite output in watch mode — HMR handles view rebuilds separately
		watchIgnore: ["dist/**"],
		mac: {
			codesign: process.env.ELECTROBUN_CODESIGN === "true",
			notarize: process.env.ELECTROBUN_NOTARIZE === "true",
			bundleCEF: false,
		},
		linux: {
			bundleCEF: false,
		},
		win: {
			bundleCEF: false,
		},
	},
	scripts: {
		postBuild: "scripts/apply-macos-icon.ts",
	},
} satisfies ElectrobunConfig;
