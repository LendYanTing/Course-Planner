import { api } from "@/lib/api/http";
import type {
  AgentApplyResult,
  AgentPreview,
  ChangeSetEntry,
  Uuid,
} from "@/generated/entities";

/**
 * Agent write path (docs/mcp.md, docs/agent-behavior.md): AI-produced changes
 * are *previewed* (a rolled-back dry run returns a confirmationId), shown to
 * the user in one window, and only then atomically applied via apply_changes.
 */
export async function previewAgentChanges(
  changes: ChangeSetEntry[]
): Promise<AgentPreview> {
  return api.post<AgentPreview>("/agent/changes/preview", { changes });
}

export async function applyAgentChanges(
  confirmationId: Uuid
): Promise<AgentApplyResult> {
  return api.post<AgentApplyResult>("/agent/changes/apply", { confirmationId });
}
