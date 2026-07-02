export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export type RpcId = string | number | null;

export type RpcRequest = {
	jsonrpc: "2.0";
	id: RpcId;
	method: string;
	params?: JsonValue;
};

export type RpcNotification = {
	jsonrpc: "2.0";
	method: string;
	params?: JsonValue;
};

export type RpcSuccess = {
	jsonrpc: "2.0";
	id: RpcId;
	result: JsonValue;
};

export type RpcError = {
	jsonrpc: "2.0";
	id: RpcId;
	error: {
		code: number;
		message: string;
		data?: JsonValue;
	};
};

export type RpcResponse = RpcSuccess | RpcError;
export type RpcMessage = RpcRequest | RpcNotification | RpcResponse;

export type ContentBlock =
	| { type: "text"; text: string }
	| { type: "image"; mimeType: string; data: string; uri?: string }
	| { type: "audio"; mimeType: string; data: string }
	| { type: "resource"; resource: { uri: string; text?: string; blob?: string; mimeType?: string } }
	| { type: "resource_link"; uri: string; name: string; title?: string; description?: string; mimeType?: string; size?: number };

export type SessionRecord = {
	sessionId: string;
	cwd: string;
	additionalDirectories: string[];
	title?: string | null;
	updatedAt: string;
	deleted?: boolean;
	modeId: string;
	config: Record<string, string>;
	messages: Array<{
		role: "user" | "agent";
		messageId: string;
		content: ContentBlock[];
		createdAt: string;
	}>;
	_meta: JsonObject;
};

export type MockState = {
	nextSession: number;
	nextMessage: number;
	nextTool: number;
	nextTerminal: number;
	sessions: Record<string, SessionRecord>;
};

export type Logger = {
	debug: (message: string) => void;
	info: (message: string) => void;
	error: (message: string) => void;
};
