import { pathToFileURL } from "node:url";
import type { AgentPromptAttachment } from "../../shared/rpc";
import type { JsonValue } from "../acp/transport";

export const PLAN_MODE_INSTRUCTION =
	"Plan mode is active. Do not make any edits, run commands, or call tools that change state. " +
	"Research and reason as needed, then respond with a clear, actionable plan for the request below and stop. " +
	"Wait for the user to approve before implementing anything.\n\n---\n\n";

export function buildPromptContent(
	prompt: string,
	attachments: AgentPromptAttachment[] | undefined,
	planMode: boolean,
): JsonValue[] {
	const content: JsonValue[] = [{ type: "text", text: planMode ? PLAN_MODE_INSTRUCTION + prompt : prompt }];
	for (const attachment of attachments ?? []) {
		content.push({
			type: "resource_link",
			uri: pathToFileURL(attachment.path).href,
			name: attachment.name,
			...(attachment.type === "directory" ? { description: "Directory" } : {}),
		});
	}
	return content;
}
