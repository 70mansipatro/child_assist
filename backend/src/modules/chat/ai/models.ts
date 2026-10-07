import { createGoogleVertex } from "@ai-sdk/google-vertex";
import type { LanguageModel } from "ai";
import { chatAiConfig } from "../../../config/env";

// The Gemini models the assistant uses, all reached through Vertex AI from the backend only.
// The app never talks to Gemini and never holds Google credentials.

export interface ChatModels {
  /** Answers the user and decides which tools to call. Required for /api/chat. */
  chat?: LanguageModel;
  /** Tried when the chat model fails or times out. */
  fallback?: LanguageModel;
  /** Screens each message before any tool can run. */
  guardrail?: LanguageModel;
}

let override: ChatModels | null = null;
let cached: ChatModels | null = null;

/** The configured models. Missing environment variables simply leave a slot empty. */
export function getChatModels(): ChatModels {
  if (override) return override;
  if (cached) return cached;

  const config = chatAiConfig();
  // Without a project ID there is nothing to call; the chat endpoint then reports 503.
  if (!config.vertexProject) {
    cached = {};
    return cached;
  }

  // Credentials come from Application Default Credentials (see .env.example).
  const vertex = createGoogleVertex({ project: config.vertexProject, location: config.vertexLocation });
  cached = {
    chat: config.chatModel ? vertex(config.chatModel) : undefined,
    fallback: config.fallbackModel ? vertex(config.fallbackModel) : undefined,
    guardrail: config.guardrailModel ? vertex(config.guardrailModel) : undefined,
  };
  return cached;
}

/** Replaces the models (tests use mock models; null restores the configured ones). */
export function setChatModels(models: ChatModels | null): void {
  override = models;
}
