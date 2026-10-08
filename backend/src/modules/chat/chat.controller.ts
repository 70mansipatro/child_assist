import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import {
  cancelPendingAction,
  completeHandoff,
  confirmPendingAction,
  setActionDocument,
  setActionRecipient,
  setSharedContact,
} from "./actions/pending-actions";
import { handleChatTurn } from "./chat.orchestrator";
import { answerDocumentRead, failDocumentRead } from "./documents/document-reads";
import { selectPhoto } from "./photos/photo-references";
import { answerPhotoAnalysis, failPhotoRequest, recordPhotoSearch } from "./photos/photo-requests";
import * as chatService from "./chat.service";
import {
  actionDocumentSchema,
  actionHandoffSchema,
  actionRecipientSchema,
  actionScopeSchema,
  actionSharedContactSchema,
  chatRequestSchema,
  createConversationSchema,
  documentReadAnswerSchema,
  documentReadFailSchema,
  idParamsSchema,
  listConversationsQuerySchema,
  photoAnalysisAnswerSchema,
  photoAnalysisFailSchema,
  photoParamsSchema,
  photoSearchResultSchema,
  updateConversationSchema,
} from "./chat.validation";

// The user is always the one identified by the verified JWT, never an ID from the request.

export async function chat(req: Request, res: Response): Promise<void> {
  const input = chatRequestSchema.parse(req.body);
  const result = await handleChatTurn(getAuth(req).userId, input);
  res.status(200).json(result);
}

export async function createConversation(req: Request, res: Response): Promise<void> {
  const input = createConversationSchema.parse(req.body ?? {});
  const conversation = await chatService.createConversation(getAuth(req).userId, input);
  res.status(201).json({ conversation });
}

export async function listConversations(req: Request, res: Response): Promise<void> {
  const { limit } = listConversationsQuerySchema.parse(req.query);
  const conversations = await chatService.listConversations(getAuth(req).userId, { limit });
  res.status(200).json({ conversations });
}

export async function getConversation(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const userId = getAuth(req).userId;
  const conversation = await chatService.getConversation(userId, id);
  const messages = await chatService.listMessages(userId, id);
  res.status(200).json({ conversation, messages });
}

export async function updateConversation(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { title } = updateConversationSchema.parse(req.body);
  const conversation = await chatService.renameConversation(getAuth(req).userId, id, title);
  res.status(200).json({ conversation });
}

export async function deleteConversation(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  await chatService.deleteConversation(getAuth(req).userId, id);
  res.status(200).json({ success: true });
}

export async function chooseActionRecipient(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, name, address } = actionRecipientSchema.parse(req.body ?? {});
  const action = await setActionRecipient(getAuth(req).userId, id, { name, address }, { conversationId });
  res.status(200).json({ action });
}

export async function chooseSharedContact(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, name, phone } = actionSharedContactSchema.parse(req.body ?? {});
  const action = await setSharedContact(getAuth(req).userId, id, { name, phone }, { conversationId });
  res.status(200).json({ action });
}

export async function chooseActionDocument(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, documentId, name, type } = actionDocumentSchema.parse(req.body ?? {});
  const action = await setActionDocument(getAuth(req).userId, id, { documentId, name, type }, { conversationId });
  res.status(200).json({ action });
}

export async function answerDocumentReadRequest(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, truncated, ...document } = documentReadAnswerSchema.parse(req.body ?? {});
  const result = await answerDocumentRead(getAuth(req).userId, id, { ...document, truncated: truncated ?? false }, { conversationId });
  res.status(200).json(result);
}

export async function failDocumentReadRequest(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, reason } = documentReadFailSchema.parse(req.body ?? {});
  const result = await failDocumentRead(getAuth(req).userId, id, reason, { conversationId });
  res.status(200).json(result);
}

export async function confirmAction(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const scope = actionScopeSchema.parse(req.body ?? {});
  const action = await confirmPendingAction(getAuth(req).userId, id, scope);
  res.status(200).json({ action });
}

export async function cancelAction(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const scope = actionScopeSchema.parse(req.body ?? {});
  const action = await cancelPendingAction(getAuth(req).userId, id, scope);
  res.status(200).json({ action });
}

export async function actionHandoff(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, result } = actionHandoffSchema.parse(req.body ?? {});
  const action = await completeHandoff(getAuth(req).userId, id, result, { conversationId });
  res.status(200).json({ action });
}

export async function reportPhotoSearch(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, ...report } = photoSearchResultSchema.parse(req.body ?? {});
  const result = await recordPhotoSearch(getAuth(req).userId, id, report, { conversationId });
  res.status(200).json(result);
}

export async function choosePhoto(req: Request, res: Response): Promise<void> {
  const { photoId } = photoParamsSchema.parse(req.params);
  const { conversationId } = actionScopeSchema.parse(req.body ?? {});
  const photo = await selectPhoto(getAuth(req).userId, photoId, { conversationId });
  res.status(200).json({ photo });
}

export async function answerPhotoAnalysisRequest(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, photoId, image } = photoAnalysisAnswerSchema.parse(req.body ?? {});
  const result = await answerPhotoAnalysis(getAuth(req).userId, id, { photoId, image }, { conversationId });
  res.status(200).json(result);
}

export async function failPhotoAnalysisRequest(req: Request, res: Response): Promise<void> {
  const { id } = idParamsSchema.parse(req.params);
  const { conversationId, reason } = photoAnalysisFailSchema.parse(req.body ?? {});
  const result = await failPhotoRequest(getAuth(req).userId, id, reason, { conversationId });
  res.status(200).json(result);
}
