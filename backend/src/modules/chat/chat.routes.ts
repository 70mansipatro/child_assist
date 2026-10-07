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
chatRouter.post("/actions/:id/confirm", chatController.confirmAction);
chatRouter.post("/actions/:id/cancel", chatController.cancelAction);
