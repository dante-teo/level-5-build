import { describe, expect, test } from "bun:test";

// This file cannot import app/src/bun/index.ts (it constructs Electrobun's
// native ApplicationMenu/Updater/BrowserWindow at module scope, which throws
// outside a real Electrobun-hosted process). Instead it mirrors, verbatim,
// the promise-chain "setup lock" that ProjectAgentConnection uses in
// app/src/bun/index.ts:
//
//   private connectionSetupChain: Promise<void> = Promise.resolve();
//
//   private withConnectionSetupLock<T>(fn: () => Promise<T>): Promise<T> {
//     const ready = this.connectionSetupChain.catch(() => undefined);
//     const result = ready.then(fn);
//     this.connectionSetupChain = result.then(
//       () => undefined,
//       () => undefined,
//     );
//     return result;
//   }
//
//   awaitSetup(): Promise<void> {
//     return this.connectionSetupChain.catch(() => undefined);
//   }
//
// AgentAcpClient.listSlashCommands()/listConfigOptions() call
// `await connection?.awaitSetup()` before reading connection state. Before
// the fix, they read connection state with no wait at all, which is exactly
// the "stale snapshot" reader below.
class SetupLock {
	private chain: Promise<void> = Promise.resolve();

	withLock<T>(fn: () => Promise<T>): Promise<T> {
		const ready = this.chain.catch(() => undefined);
		const result = ready.then(fn);
		this.chain = result.then(
			() => undefined,
			() => undefined,
		);
		return result;
	}

	awaitSetup(): Promise<void> {
		return this.chain.catch(() => undefined);
	}
}

describe("connection setup race (mirrors ProjectAgentConnection.awaitSetup)", () => {
	test("a reader awaiting an idle setup chain proceeds immediately, then observes a later setup's effects once it resolves", async () => {
		const lock = new SetupLock();
		let configOptions: string[] = [];

		// Nothing is in flight yet: awaitSetup must resolve immediately
		// against the initial Promise.resolve() chain.
		await lock.awaitSetup();
		expect(configOptions).toEqual([]);

		await lock.withLock(async () => {
			configOptions = ["model"];
		});

		// A fresh awaitSetup call after setup has completed observes the
		// updated state -- proves the queuing chain itself works.
		await lock.awaitSetup();
		expect(configOptions).toEqual(["model"]);
	});

	test("a reader awaiting setup sees the fully-populated config, while a reader that doesn't await sees a stale empty snapshot", async () => {
		const lock = new SetupLock();
		let configOptions: string[] = [];

		// Deterministic stand-in for "spawn + initialize + session/new taking
		// real wall-clock time against a real omp/devin backend" -- a
		// manually-resolved promise instead of a real timer, so the test
		// controls exactly when the handshake settles rather than guessing a
		// duration.
		const handshake = Promise.withResolvers<void>();

		// Fire-and-forget setup kickoff, exactly like the eager warm-up in
		// index.ts: the caller never awaits withLock's returned promise
		// directly; a real call site wraps it in try/catch (see
		// ensureSession/prepareSession/startNewChat in index.ts), mirrored
		// here with .catch() so an eventual rejection doesn't surface as an
		// unhandled rejection.
		void lock
			.withLock(async () => {
				await handshake.promise;
				configOptions = ["model", "max-tokens"];
			})
			.catch(() => undefined);

		// OLD buggy behavior: AgentAcpClient.listConfigOptions() used to read
		// connection.listConfigOptions() with no wait at all. Reading the
		// snapshot immediately after kickoff -- before the handshake settles
		// -- reliably loses the race and observes the empty initial value.
		const staleSnapshot = configOptions;
		expect(staleSnapshot).toEqual([]);

		// NEW fixed behavior: a reader that awaits the setup lock first
		// queues behind the in-flight setup and only reads state once it
		// settles.
		const awaitingReader = lock.awaitSetup().then(() => configOptions);

		// Let the simulated handshake complete.
		handshake.resolve();

		const populatedSnapshot = await awaitingReader;
		expect(populatedSnapshot).toEqual(["model", "max-tokens"]);
	});

	test("awaitSetup resolves without throwing when the in-flight setup rejects, letting a queued reader proceed to read whatever state resulted", async () => {
		const lock = new SetupLock();
		let configOptions: string[] = [];

		const handshake = Promise.withResolvers<void>();

		// Setup that fails partway through (e.g. ensureProcess throwing
		// because the real backend's CLI isn't available) must not leave
		// awaitSetup() rejecting for good -- connectionSetupChain always
		// resolves to undefined via the .then(() => undefined, () =>
		// undefined) re-assignment, and awaitSetup()'s own .catch(() =>
		// undefined) is a second line of defense.
		void lock
			.withLock(async () => {
				await handshake.promise;
				throw new Error("spawn failed");
			})
			.catch(() => undefined);

		const awaitingReader = lock.awaitSetup().then(() => configOptions);

		handshake.reject(new Error("spawn failed"));

		// Must resolve, not reject -- and the reader observes state as it
		// was left (setup never reached the line that would have populated
		// configOptions).
		await expect(awaitingReader).resolves.toEqual([]);
	});
});
