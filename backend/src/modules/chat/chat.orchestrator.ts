import { generateText, isStepCount, type LanguageModel, type ModelMessage } from "ai";
import { HttpError } from "../../lib/http-error";
import { discardPendingActions } from "./actions/pending-actions";
import { buildInstructions, identityAnswer, isMeaningful, stripWakeWords } from "./ai/identity";
import { getChatModels } from "./ai/models";
import { redactSecrets } from "./ai/redact";
import { generateTitle } from "./ai/title";
import {
  ChatMessageRole,
  addMessage,
  createConversation,
  deleteConversation,
  deleteMessage,
  getConversation,
  listMessages,
  renameConversation,
  type ConversationRecord,
  type MessageRecord,
} from "./chat.service";
import { checkRules, checkWithModel, guardReply, refusalFor, type GuardrailCategory } from "./guardrails/guardrails";
import { buildChatTools } from "./tools";
import type { PendingActionView, ToolContext, ToolEvent } from "./tools/types";

// One chat turn, from the user's text to the saved reply. Text and (later) voice both come
// through here: voice will be speech-to-text → handleChatTurn → text-to-speech, with no second
// copy of the AI logic.

export const chatSettings = {
  /** Upper bound for one model run, including all its tool calls. */
  timeoutMs: 45_000,
  /** Model steps per turn: each tool round trip is one step. */
  maxSteps: 6,
  /** Earlier messages sent to the model for context. */
  historyLimit: 20,
};

export interface ChatTurnInput {
  conversationId?: string;
  message: string;
  /** IANA time zone from the device, used to resolve "yesterday" and similar. */
  timeZone?: string;
  /** The device's current UTC offset in minutes, when it cannot name its time zone. */
  utcOffsetMinutes?: number;
}

export interface ChatTurnResult {
  conversationId: string;
  title: string | null;
  response: string;
  userMessage: MessageRecord;
  message: MessageRecord;
  pendingActions: PendingActionView[];
  toolsUsed: string[];
  /** What the app shows about the tools that ran (friendly categories, own data only). */
  toolEvents: ToolEvent[];
  guardrail: { blocked: true; category: GuardrailCategory } | null;
}

/** Runs one turn for the authenticated user. userId must come from the verified JWT. */
export async function handleChatTurn(userId: string, input: ChatTurnInput): Promise<ChatTurnResult> {
  // Secrets the user pasted by mistake are never stored or sent to Gemini.
  const text = redactSecrets(input.message.trim());

  // Ownership is checked here: someone else's conversation is a 404 before anything is written.
  let conversation: ConversationRecord;
  let createdConversation = false;
  if (input.conversationId) {
    conversation = await getConversation(userId, input.conversationId);
  } else {
    conversation = await createConversation(userId);
    createdConversation = true;
  }
  const conversationId = conversation.id;
  const userMessage = await addMessage(userId, conversationId, { role: ChatMessageRole.CHAT_USER, content: text });

  // Undo this turn when no answer could be produced, so a retry starts clean.
  const rollback = async () => {
    if (createdConversation) await deleteConversation(userId, conversationId).catch(() => undefined);
    else await deleteMessage(userId, userMessage.id).catch(() => undefined);
  };

  const finish = async (
    reply: string,
    extra: {
      pendingActions?: PendingActionView[];
      toolsUsed?: string[];
      toolEvents?: ToolEvent[];
      blocked?: GuardrailCategory;
      title?: Promise<string> | null;
    } = {},
  ): Promise<ChatTurnResult> => {
    const pendingActions = extra.pendingActions ?? [];
    const response = guardReply(reply, pendingActions.length > 0);
    const message = await addMessage(userId, conversationId, { role: ChatMessageRole.CHAT_ASSISTANT, content: response });

    let title = conversation.title;
    if (extra.title) {
      title = (await renameConversation(userId, conversationId, await extra.title)).title;
    }
    return {
      conversationId,
      title,
      response,
      userMessage,
      message,
      pendingActions,
      toolsUsed: extra.toolsUsed ?? [],
      toolEvents: extra.toolEvents ?? [],
      guardrail: extra.blocked ? { blocked: true, category: extra.blocked } : null,
    };
  };

  // 1. Deterministic guardrails: clear-cut abuse never reaches a model or a tool.
  const rules = checkRules(text);
  if (!rules.allowed && rules.category) {
    return finish(refusalFor(rules.category), { blocked: rules.category });
  }

  const models = getChatModels();
  // Named after the first meaningful message (without "Hey Child Assist"); never after a
  // blocked one or an identity question, so the first real question names the chat.
  const titleFor = () =>
    conversation.title === null && isMeaningful(text)
      ? generateTitle(models.guardrail ?? models.chat, stripWakeWords(text))
      : null;

  // 2. Identity questions have exact answers that must not depend on the model.
  const identity = identityAnswer(text);
  if (identity) return finish(identity);

  if (!models.chat) {
    await rollback();
    throw new HttpError(503, "Child Assist isn't set up on the server yet.", "AI_NOT_CONFIGURED");
  }

  // 3. Model guardrail, before any tool can run.
  if (models.guardrail) {
    const verdict = await checkWithModel(models.guardrail, text);
    if (verdict && !verdict.allowed && verdict.category) {
      return finish(refusalFor(verdict.category), { blocked: verdict.category });
    }
  }

  // 4. Gemini with tools (fallback model on failure); the title is generated alongside.
  const titlePromise = titleFor();
  const history = await loadHistory(userId, conversationId);
  const instructions = buildInstructions(new Date(), input.timeZone, input.utcOffsetMinutes);

  let outcome: { text: string; run: ToolContext["run"] };
  try {
    outcome = await runWithFallback(userId, conversationId, [models.chat, models.fallback], instructions, history);
  } catch (err) {
    await titlePromise?.catch(() => undefined);
    await rollback();
    throw toHttpError(err);
  }

  return finish(outcome.text, {
    pendingActions: outcome.run.pendingActions,
    toolsUsed: outcome.run.toolsUsed,
    toolEvents: outcome.run.events,
    title: titlePromise,
  });
}

async function loadHistory(userId: string, conversationId: string): Promise<ModelMessage[]> {
  const recent = await listMessages(userId, conversationId, { order: "desc", limit: chatSettings.historyLimit });
  return recent
    .reverse()
    .filter((m) => m.role === ChatMessageRole.CHAT_USER || m.role === ChatMessageRole.CHAT_ASSISTANT)
    .map((m) =>
      m.role === ChatMessageRole.CHAT_USER
        ? { role: "user" as const, content: m.content }
        : { role: "assistant" as const, content: m.content },
    );
}

async function runWithFallback(
  userId: string,
  conversationId: string,
  candidates: Array<LanguageModel | undefined>,
  instructions: string,
  messages: ModelMessage[],
): Promise<{ text: string; run: ToolContext["run"] }> {
  let lastError: unknown = new Error("No chat model configured");
  for (const model of candidates) {
    if (!model) continue;
    const ctx: ToolContext = { userId, conversationId, run: { toolsUsed: [], pendingActions: [], events: [] } };
    try {
      const result = await generateText({
        model,
        instructions,
        messages,
        tools: buildChatTools(ctx),
        stopWhen: isStepCount(chatSettings.maxSteps),
        timeout: { totalMs: chatSettings.timeoutMs },
        maxRetries: 1,
      });
      return { text: result.text, run: ctx.run };
    } catch (err) {
      lastError = err;
      const e = err instanceof Error ? err : new Error(String(err));
      console.error(`Chat model failed: ${e.name}: ${e.message}`);
      // Anything this attempt prepared must not stay confirmable.
      await discardPendingActions(userId, ctx.run.pendingActions.map((a) => a.id));
    }
  }
  throw lastError;
}

function isTimeout(err: unknown): boolean {
  if (!(err instanceof Error)) return false;
  return err.name === "TimeoutError" || err.name === "AbortError" || /time(?:d)?\s*out/i.test(err.message);
}

// Clients get a stable code and a friendly message; provider details stay in the server log.
function toHttpError(err: unknown): HttpError {
  if (err instanceof HttpError) return err;
  if (isTimeout(err)) {
    return new HttpError(504, "Child Assist took too long to answer. Please try again.", "AI_TIMEOUT");
  }
  return new HttpError(503, "Child Assist is unavailable right now. Please try again in a moment.", "AI_UNAVAILABLE");
}
