import { createLogger } from "./rpc.js";
import { AcpMockServer, runServer } from "./server.js";
import { StateStore } from "./state.js";

const statePath = process.env.ACP_MOCK_STATE_PATH ?? ".mock-acp-state.json";
const logger = createLogger(process.env.ACP_MOCK_LOG);
const store = new StateStore(statePath);
const server = new AcpMockServer(store, logger);

logger.info(`starting ACP mock server with state at ${store.path}`);
await runServer(server);
