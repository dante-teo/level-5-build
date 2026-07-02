import { Electroview } from "electrobun/view";
import type { AppRPC } from "@shared/rpc";

const rpc = Electroview.defineRPC<AppRPC>({
	handlers: {
		requests: {},
	},
});

export const electroview = new Electroview({ rpc });
