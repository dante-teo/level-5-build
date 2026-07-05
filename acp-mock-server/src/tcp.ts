import net from "node:net";
import { AcpMockServer } from "./server.js";
import { StateStore } from "./state.js";
import { createLogger, resetMessageWriter, setMessageWriter } from "./rpc.js";

const host = process.env.ACP_MOCK_TCP_HOST ?? "127.0.0.1";
const port = Number(process.env.ACP_MOCK_TCP_PORT ?? "58945");
const statePath = process.env.ACP_MOCK_STATE_PATH ?? ".mock-acp-state.json";
const logger = createLogger(process.env.ACP_MOCK_LOG);
const store = new StateStore(statePath);

const server = net.createServer((socket) => {
	const peer = `${socket.remoteAddress ?? "unknown"}:${socket.remotePort ?? 0}`;
	const acp = new AcpMockServer(store, logger);
	let buffer = "";

	logger.info(`TCP client connected: ${peer}`);
	setMessageWriter((line) => {
		socket.write(line);
	});

	socket.setEncoding("utf8");
	socket.on("data", (chunk) => {
		buffer += chunk;
		while (buffer.includes("\n")) {
			const index = buffer.indexOf("\n");
			const line = buffer.slice(0, index).trim();
			buffer = buffer.slice(index + 1);
			if (line.length > 0) {
				void acp.handleLine(line).catch((error) => {
					logger.error(`unhandled TCP line error: ${error instanceof Error ? error.message : String(error)}`);
				});
			}
		}
	});

	socket.on("error", (error) => {
		logger.error(`TCP client error ${peer}: ${error.message}`);
	});
	socket.on("close", () => {
		logger.info(`TCP client disconnected: ${peer}`);
		resetMessageWriter();
	});
});

server.on("error", (error) => {
	logger.error(`TCP server error: ${error.message}`);
	process.exitCode = 1;
});

server.listen(port, host, () => {
	logger.info(`TCP ACP mock listening on ${host}:${port} with state at ${store.path}`);
});
