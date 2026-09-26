import { JSONSchema7 } from "json-schema";
import { ChatContext } from "../chat-context";
import { DialogueParams, DialogueTool, ToolResult } from "../../types";

export const TOOL_NAME = "opensurferAutomation";

const OS_BASE = "http://localhost:4173";

export default class OpenSurferTool implements DialogueTool {
  readonly name: string = TOOL_NAME;
  readonly description: string;
  readonly parameters: JSONSchema7;
  private chatContext: ChatContext;
  private params: DialogueParams;

  constructor(chatContext: ChatContext, params: DialogueParams) {
    this.chatContext = chatContext;
    this.params = params;
    this.description = `Create a recurring background automation (trigger/workflow) using the OpenSurfer server. Use this tool instead of deepAction when the user asks for something that should run automatically, repeatedly, or in the background — such as "every time X happens, do Y", "whenever a PR opens...", "monitor X and create Y". This tool composes a workflow plan from natural language, saves it as a persistent trigger on the server, and runs it asynchronously without any browser UI interaction. The user can manage saved automations in the Workflows tab.`;
    this.parameters = {
      type: "object",
      properties: {
        goal: {
          type: "string",
          description:
            "The full natural-language description of the automation the user wants, e.g. 'every time a PR opens in opensurfer/browser, create a Linear task in the test project'"
        },
        triggerType: {
          type: "string",
          enum: ["poll", "webhook"],
          description:
            "How the automation fires: 'poll' checks a capability on an interval (default), 'webhook' fires on incoming HTTP POST",
          default: "poll"
        },
        pollSystem: {
          type: "string",
          description:
            "For poll triggers: the system to poll, e.g. 'api.github.com'. If omitted, the compose step will figure it out."
        },
        pollCapability: {
          type: "string",
          description:
            "For poll triggers: the capability to poll, e.g. 'pr.list'. If omitted, the compose step will figure it out."
        },
        pollInterval: {
          type: "integer",
          description: "For poll triggers: seconds between polls (default 60)",
          default: 60
        }
      },
      required: ["goal"]
    };
  }

  async execute(args: Record<string, unknown>): Promise<ToolResult> {
    const goal = args.goal as string;
    const triggerType = (args.triggerType as string) || "poll";
    const pollInterval = (args.pollInterval as number) || 60;

    try {
      const pingRes = await fetch(`${OS_BASE}/api/caps`);
      if (!pingRes.ok) throw new Error("OpenSurfer server not reachable");
    } catch {
      return {
        content: [
          {
            type: "text",
            text: "Error: OpenSurfer server is not running at localhost:4173. Start it with: cd ~/opensurfer && node server.mjs"
          }
        ],
        isError: true
      };
    }

    try {
      const composeRes = await fetch(`${OS_BASE}/api/compose`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ goal })
      });
      const plan = await composeRes.json();
      if (plan.error) {
        return {
          content: [
            {
              type: "text",
              text: `Compose error: ${plan.error}${
                plan.missing ? ` (missing: ${plan.missing})` : ""
              }`
            }
          ],
          isError: true
        };
      }

      const trigger: Record<string, unknown> =
        triggerType === "webhook"
          ? { type: "webhook" }
          : {
              type: "poll",
              pollRequest: plan.poll || undefined,
              system:
                (args.pollSystem as string) ||
                plan.trigger?.system ||
                undefined,
              capability:
                (args.pollCapability as string) ||
                plan.trigger?.capability ||
                undefined,
              interval: pollInterval
            };

      const createRes = await fetch(`${OS_BASE}/api/triggers`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          name: goal.slice(0, 80),
          trigger,
          composeGoal: goal,
          workflowPlan: plan
        })
      });

      if (!createRes.ok) {
        const err = await createRes.json();
        return {
          content: [
            { type: "text", text: `Failed to save trigger: ${err.error}` }
          ],
          isError: true
        };
      }

      const saved = await createRes.json();
      const pollDesc = trigger.pollRequest
        ? (trigger.pollRequest as Record<string, string>).url
        : `${trigger.system}/${trigger.capability}`;
      const summary =
        triggerType === "poll"
          ? `Polling ${pollDesc} every ${pollInterval}s`
          : `Webhook trigger (POST to /api/webhooks/${saved.id})`;

      return {
        content: [
          {
            type: "text",
            text: `Automation saved and running in the background.\n\nName: ${saved.name}\nType: ${summary}\nGoal: ${goal}\n\nYou can manage it in the Workflows tab (enable/disable/delete).`
          }
        ]
      };
    } catch (e: any) {
      return {
        content: [
          {
            type: "text",
            text: `Error creating automation: ${e.message}`
          }
        ],
        isError: true
      };
    }
  }
}
