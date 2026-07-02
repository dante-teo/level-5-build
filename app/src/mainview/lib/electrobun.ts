import { Electroview } from "electrobun/view";
import type { AppRPC } from "@shared/rpc";

const rpc = Electroview.defineRPC<AppRPC>({
	maxRequestTime: 10 * 60 * 1000,
	handlers: {
		requests: {},
		messages: {},
	},
});

export const electroview = new Electroview({ rpc });
