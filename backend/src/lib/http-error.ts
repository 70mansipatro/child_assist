// An error carrying an HTTP status and a message that is safe to show to clients.
// `code` is an optional stable identifier (e.g. "AI_UNAVAILABLE") clients can branch on.
export class HttpError extends Error {
  constructor(
    public readonly status: number,
    message: string,
    public readonly code?: string,
  ) {
    super(message);
    this.name = "HttpError";
  }
}
