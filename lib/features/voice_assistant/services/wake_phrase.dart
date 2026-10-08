/// The phrases that wake Child Assist, as shown to the user.
const wakePhrases = ['Hey Child', 'Hi Child'];

// "Hey Child", "Hi Child" and how speech recognisers tend to write them ("hay child", "hi,
// child!"), at the very start of what was heard. A lone "Child," is matched only when followed by
// a comma or nothing, so a question like "Child safety tips" is left alone.
final _greeted = RegExp(r'^(?:hey|hi|hay|hai|hei)\b[\s,.!-]*(?:child|chiled|chile)\b[\s,.!?:;-]*', caseSensitive: false);
final _bare = RegExp(r'^child\s*(?:[,.!?:;-][\s,.!?:;-]*|$)', caseSensitive: false);

/// What the user asked, without the wake phrase: "Hey Child, where did I go today?" becomes
/// "where did I go today?". Child Assist never receives the wake phrase as the question, so it
/// cannot affect what the assistant thinks was asked. Returns an empty string when only the wake
/// phrase was said.
String stripWakePhrase(String heard) {
  var text = heard.trim();
  // Said twice ("Hey Child... hey Child, what time is it?") is still one wake phrase.
  for (var i = 0; i < 3; i++) {
    final match = _greeted.firstMatch(text) ?? _bare.firstMatch(text);
    if (match == null) break;
    text = text.substring(match.end).trim();
  }
  return text;
}
