// Integration points the assistant's tools call through. Each one is an interface with an honest
// "not available" default, so the assistant reports what it cannot do instead of inventing data.
// Real implementations plug in via configureChatProviders() without touching tool or AI code.

// ---------------------------------------------------------------------------------------------
// Device data. Photos (Phase 5) and documents (Phase 6) live only on the user's phone: the app
// keeps metadata and a private file reference locally and uploads nothing. The backend therefore
// has no copy of them, and there is not yet a secure channel for the phone to answer a request
// from the backend. A future DeviceGateway (e.g. the app answering tool requests over an
// authenticated round trip) implements this interface.

export type DocumentKind = "PDF" | "DOC" | "DOCX" | "TXT";

export interface DevicePhoto {
  id: string;
  name?: string | null;
  mimeType?: string | null;
  fileSize?: number | null;
  width?: number | null;
  height?: number | null;
  createdAt: Date;
  modifiedAt?: Date | null;
}

export interface DeviceDocument {
  id: string;
  name: string;
  type: DocumentKind;
  size?: number | null;
  modifiedAt?: Date | null;
  addedAt: Date;
  /** False when the OS no longer grants access to the file (moved, deleted or revoked). */
  available: boolean;
}

export interface DeviceDocumentContent extends DeviceDocument {
  /** Extracted text, or null when the device has no extractor for this format. */
  text: string | null;
}

export interface DeviceLocation {
  latitude: number;
  longitude: number;
  accuracy?: number | null;
  capturedAt: Date;
}

export interface PhotoQuery {
  text?: string;
  since?: Date;
  before?: Date;
  limit: number;
}

export interface DocumentQuery {
  text?: string;
  type?: DocumentKind;
  limit: number;
}

export interface DeviceGateway {
  /** False until a secure device handoff exists; tools then answer *_UNAVAILABLE. */
  readonly available: boolean;
  getCurrentLocation(userId: string): Promise<DeviceLocation | null>;
  searchPhotos(userId: string, query: PhotoQuery): Promise<DevicePhoto[]>;
  searchDocuments(userId: string, query: DocumentQuery): Promise<DeviceDocument[]>;
  /** Only documents the user added in the app and the OS still grants access to. */
  readDocument(userId: string, documentId: string): Promise<DeviceDocumentContent | null>;
}

const unavailableDevice: DeviceGateway = {
  available: false,
  getCurrentLocation: async () => null,
  searchPhotos: async () => [],
  searchDocuments: async () => [],
  readDocument: async () => null,
};

// ---------------------------------------------------------------------------------------------
// Live web search (e.g. "get me the menu of X restaurant").

export interface WebResult {
  title: string;
  url: string;
  snippet: string;
}

export interface WebSearchProvider {
  searchWeb(query: string): Promise<WebResult[]>;
}

// Phone contacts are deliberately not a provider: the address book never leaves the phone. The
// app searches it locally (find_contact) and only sends back the one address the user picks for
// an action. Email goes out through the backend's SMTP (actions/email.service.ts) and WhatsApp
// messages are opened on the phone for the user to send, both only after confirmation.

// ---------------------------------------------------------------------------------------------

export interface ChatProviders {
  device: DeviceGateway;
  webSearch: WebSearchProvider | null;
}

const defaults: ChatProviders = {
  device: unavailableDevice,
  webSearch: null,
};

let current: ChatProviders = { ...defaults };

export function chatProviders(): ChatProviders {
  return current;
}

/** Plugs in real integrations (or test doubles). Unspecified ones keep their current value. */
export function configureChatProviders(providers: Partial<ChatProviders>): void {
  current = { ...current, ...providers };
}

export function resetChatProviders(): void {
  current = { ...defaults };
}
