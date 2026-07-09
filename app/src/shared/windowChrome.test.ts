import { expect, test } from "bun:test";
import {
	WINDOW_TOP_BAR_HEIGHT,
	WINDOW_TOP_CONTROL_SIZE,
	WINDOW_TOP_CONTROL_TOP,
	WINDOW_TRAFFIC_LIGHT_CENTER_Y,
	WINDOW_TRAFFIC_LIGHT_DIAMETER,
	WINDOW_TRAFFIC_LIGHT_OFFSET,
} from "./windowChrome";

test("native traffic lights and renderer controls share a 28px optical centerline", () => {
	expect(WINDOW_TRAFFIC_LIGHT_OFFSET.y + WINDOW_TRAFFIC_LIGHT_DIAMETER / 2).toBe(28);
	expect(WINDOW_TRAFFIC_LIGHT_CENTER_Y).toBe(28);
	expect(WINDOW_TOP_CONTROL_TOP + WINDOW_TOP_CONTROL_SIZE / 2).toBe(28);
	expect(WINDOW_TOP_BAR_HEIGHT).toBe(56);
});
