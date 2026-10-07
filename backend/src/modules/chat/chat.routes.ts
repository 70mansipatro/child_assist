import express, { Router } from "express";
import { requireAuth } from "../../middleware/auth.middleware";
import * as chatController from "./chat.controller";

/** Room for the largest text a document read may carry (150,000 characters, JSON-escaped). */
export const DOCUMENT_READ_BODY_LIMIT = "1mb";
/** Only this path may exceed the app-wide JSON limit. */
export const DOCUMENT_READ_ANSWER_PATH = /^\/api\/chat\/document-reads\/[^/]+\/answer$/;

export const chatRouter = Router();

chatRouter.use(requireAuth);
chatRouter.post("/", chatController.chat);
chatRouter.post("/conversations", chatController.createConversation);
chatRouter.get("/conversations", chatController.listConversations);
chatRouter.get("/conversations/:id", chatController.getConversation);
chatRouter.patch("/conversations/:id", chatController.updateConversation);
chatRouter.delete("/conversations/:id", chatController.deleteConversation);
// Side-effect actions prepared by the assistant only run after one of these explicit calls.
// The recipient is the one contact the user picked on the phone; handoff reports that WhatsApp (or
// the share sheet) was opened for a confirmed message, which the user then sends themselves.
chatRouter.post("/actions/:id/recipient", chatController.chooseActionRecipient);
// For "send A's number to B": the contact (A) and number the user picked, kept apart from B.
chatRouter.post("/actions/:id/shared-contact", chatController.chooseSharedContact);
// For a document share: the one document the user picked on the phone (opaque id, name, type).
chatRouter.post("/actions/:id/document", chatController.chooseActionDocument);
chatRouter.post("/actions/:id/confirm", chatController.confirmAction);
chatRouter.post("/actions/:id/cancel", chatController.cancelAction);
chatRouter.post("/actions/:id/handoff", chatController.actionHandoff);
// Reading one document for the assistant: the phone posts the text it extracted from the one
// document the request is about (or why it could not). Its own, larger body limit; see app.ts.
chatRouter.post(
  "/document-reads/:id/answer",
  express.json({ limit: DOCUMENT_READ_BODY_LIMIT }),
  chatController.answerDocumentReadRequest,
);
chatRouter.post("/document-reads/:id/fail", chatController.failDocumentReadRequest);
