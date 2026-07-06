export type AcpTurnIdleTickDecision = "stop" | "touch" | "timeout" | "continue";

export function evaluateAcpTurnIdleTick(input: {
	readonly isTurnActive: boolean;
	readonly isAwaitingHuman: boolean;
	readonly idleMs: number;
	readonly idleTimeoutMs: number;
}): AcpTurnIdleTickDecision {
	if (!input.isTurnActive) {
		return "stop";
	}
	if (input.isAwaitingHuman) {
		return "touch";
	}
	return input.idleMs >= input.idleTimeoutMs ? "timeout" : "continue";
}

export type AcpTurnIdleWatchdog = {
	readonly touch: () => void;
	readonly setAwaitingHuman: (awaitingHuman: boolean) => void;
	readonly stop: () => void;
};

export function startAcpTurnIdleWatchdog(input: {
	readonly idleTimeoutMs: number;
	readonly checkIntervalMs: number;
	readonly isTurnActive: () => boolean;
	readonly onIdleTimeout: (idleMs: number) => void;
}): AcpTurnIdleWatchdog {
	let lastActivityAt = Date.now();
	let awaitingHuman = false;
	let stopped = false;
	const timer = setInterval(() => {
		if (stopped) {
			return;
		}
		const idleMs = Date.now() - lastActivityAt;
		const decision = evaluateAcpTurnIdleTick({
			isTurnActive: input.isTurnActive(),
			isAwaitingHuman: awaitingHuman,
			idleMs,
			idleTimeoutMs: input.idleTimeoutMs,
		});
		if (decision === "stop") {
			clearInterval(timer);
			stopped = true;
			return;
		}
		if (decision === "touch") {
			lastActivityAt = Date.now();
			return;
		}
		if (decision === "timeout") {
			clearInterval(timer);
			stopped = true;
			input.onIdleTimeout(idleMs);
		}
	}, input.checkIntervalMs);

	return {
		touch: () => {
			lastActivityAt = Date.now();
		},
		setAwaitingHuman: (next) => {
			awaitingHuman = next;
			if (next) {
				lastActivityAt = Date.now();
			}
		},
		stop: () => {
			stopped = true;
			clearInterval(timer);
		},
	};
}
