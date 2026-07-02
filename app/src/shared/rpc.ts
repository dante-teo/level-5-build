import type { RPCSchema } from "electrobun";

export type AppRPC = {
	// functions that execute in the main (bun) process, callable from the webview
	bun: RPCSchema<{
		requests: {
			toggleMaximizeWindow: {
				params: void;
				response: boolean;
			};
		};
	}>;
	// nothing needs to run in the webview for this app yet
	webview: RPCSchema;
};
