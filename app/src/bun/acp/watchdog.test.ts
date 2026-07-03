import { describe, expect, test } from "bun:test";
import { evaluateAcpTurnIdleTick } from "./watchdog";

describe("ACP turn idle watchdog", () => {
	test("stops once the turn is no longer active", () => {
		expect(
			evaluateAcpTurnIdleTick({
				isTurnActive: false,
				isAwaitingHuman: false,
				idleMs: 60_000,
				idleTimeoutMs: 30_000,
			}),
		).toBe("stop");
	});

	test("touches activity while the turn is waiting for human input", () => {
		expect(
			evaluateAcpTurnIdleTick({
				isTurnActive: true,
				isAwaitingHuman: true,
				idleMs: 60_000,
				idleTimeoutMs: 30_000,
			}),
		).toBe("touch");
	});

	test("times out silent active turns after the idle budget", () => {
		expect(
			evaluateAcpTurnIdleTick({
				isTurnActive: true,
				isAwaitingHuman: false,
				idleMs: 30_000,
				idleTimeoutMs: 30_000,
			}),
		).toBe("timeout");
	});

	test("continues active turns with recent inbound activity", () => {
		expect(
			evaluateAcpTurnIdleTick({
				isTurnActive: true,
				isAwaitingHuman: false,
				idleMs: 29_999,
				idleTimeoutMs: 30_000,
			}),
		).toBe("continue");
	});
});
