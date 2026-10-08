// Did the user ask about what is IN a photo, not only to find or show it? The model decides
// first (get_photo_candidates `question`, analyze_photo); this is the backstop for a turn where
// it searched for the photo but left the question out ("Get and explain the recently clicked
// picture"). Deliberately narrow: "show me today's photo" or "is there a photo from yesterday"
// must stay a plain search, so only explicit asks about the content count.

const ANALYSIS_PATTERNS: RegExp[] = [
  /\b(?:explain|describe|analy[sz]e|recogni[sz]e|identify)\b/i,
  /\bwhat(?:'s|\s+is|\s+are)?\s+(?:in|on|inside|written|happening)\b/i,
  /\bwhat\s+(?:do|can)\s+you\s+see\b/i,
  /\bwhat\s+(?:does|do)\s+(?:it|this|that|the\s+\w+)\s+say\b/i,
  /\bread\s+(?:the\s+|out\s+)?(?:text|words|writing|it)\b/i,
  /\btell\s+me\s+(?:about|what)\b/i,
  /\bwhat\s+colou?r\b/i,
  /\b(?:is|are)\s+there\s+(?:a|an|any|some)\s+\w+(?:\s+\w+)?\s+in\s+(?:it|this|that|the)\b/i,
  // Hinglish: "isme kya hai", "photo samjhao", "batao kya dikh raha hai"
  /\b(?:kya\s+hai|kya\s+dikh|samjhao|samjha\s+do)\b/i,
];

/** Longest question stored for a photo (matches PhotoRequest.question). */
const MAX_QUESTION = 500;

/**
 * The user's own words as the question to ask about the photo, when [message] explicitly asks
 * about a photo's content; null for a plain "find / show / send" request.
 */
export function photoAnalysisQuestion(message: string): string | null {
  const text = message.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  if (!text || !ANALYSIS_PATTERNS.some((p) => p.test(text))) return null;
  return text.slice(0, MAX_QUESTION);
}

// "Show my latest photo", "explain the recently clicked picture", "the most recent pic from Durgi":
// the newest photo on the phone NOW, so always a fresh gallery search. A photo shown earlier in the
// chat may no longer be the newest, so it is never reused for these. Only ONE photo ("photos" is a
// plain search), and never "this / that / the same photo", which points back at the one shown.

const RECENT =
  /\b(?:latest|newest|most\s+recent(?:ly)?|recent(?:ly)?|last(?!\s+(?:week|month|year|night|weekend|time|\w+day)\b)|just\s+(?:took|taken|clicked|captured))\b/i;
const ONE_PHOTO = /\b(?:photo|picture|pic|image|snap|selfie)\b/i;
const REFERS_BACK = /\b(?:this|that|same|previous|above)\s+(?:\w+\s+)?(?:photo|picture|pic|image|snap|selfie)\b|\byou\s+(?:showed|sent|found|shared)\b/i;

/** Whether [message] asks for the user's newest photo, which must be searched for afresh. */
export function asksForRecentPhoto(message: string): boolean {
  const text = message.replace(/\s+/g, " ").trim();
  return RECENT.test(text) && ONE_PHOTO.test(text) && !REFERS_BACK.test(text);
}
