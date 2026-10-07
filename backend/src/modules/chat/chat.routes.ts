import { Router } from "express";
import { requireAuth } from "../../middleware/auth.middleware";
import * as chatController from "./chat.controller";

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
chatRouter.post("/actions/:id/confirm", chatController.confirmAction);
chatRouter.post("/actions/:id/cancel", chatController.cancelAction);
chatRouter.post("/actions/:id/handoff", chatController.actionHandoff);
