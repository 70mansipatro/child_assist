import '../models/document_item.dart';

/// One document found by [DocumentSearch], with how well it matched.
class DocumentMatch {
  const DocumentMatch(this.document, {required this.score, required this.complete, this.available = true});

  final DocumentItem document;

  /// Higher is better. Only meaningful for ordering matches of the same search.
  final int score;

  /// Every word of the search is in the document's name, and the type (when one was asked for)
  /// is right. A strong match: on its own, it is the document the user meant.
  final bool complete;

  /// False when the file was deleted, moved or its access revoked since it was added.
  final bool available;

  DocumentMatch withAvailability(bool available) =>
      DocumentMatch(document, score: score, complete: complete, available: available);
}

/// What one search found.
enum DocumentSearchOutcome {
  /// Nothing matched.
  none,

  /// Exactly one strong match: that is the document.
  single,

  /// Several plausible documents (or only weak ones): the user must choose.
  multiple,
}

/// The documents matching a search, best first. Metadata only: no contents are read.
class DocumentSearchResult {
  const DocumentSearchResult({required this.words, required this.type, required this.matches});

  static const empty = DocumentSearchResult(words: [], type: null, matches: []);

  /// The words that were looked for, after leaving out filler like "send", "my" or "document".
  final List<String> words;

  /// The type asked for, from the request ("Python PDF") or a filter.
  final DocumentType? type;
  final List<DocumentMatch> matches;

  DocumentSearchOutcome get outcome => switch (matches) {
        [] => DocumentSearchOutcome.none,
        [final only] when only.complete => DocumentSearchOutcome.single,
        _ => DocumentSearchOutcome.multiple,
      };

  /// The one document to take without asking, if there is exactly one strong match.
  DocumentMatch? get single => outcome == DocumentSearchOutcome.single ? matches.single : null;

  /// How the request reads back to the user, e.g. "python PDF".
  String get description => [...words, if (type != null) type!.label].join(' ');

  List<DocumentItem> get documents => [for (final m in matches) m.document];

  String get _quoted => description.isEmpty ? '' : ' "$description"';

  /// The question to ask when the user must choose among the matches.
  String get choosePrompt {
    if (description.isEmpty) return 'Which document do you want?';
    if (matches.length == 1) return 'I found a document that may match$_quoted. Is this the one you want?';
    return 'I found ${matches.length} documents matching$_quoted. Which one do you want?';
  }

  /// What to say when nothing matched.
  String get notFoundMessage => description.isEmpty
      ? "You haven't added any documents to Child Assist yet."
      : "I couldn't find a matching $description in the documents Child Assist can access.";
}

/// Natural-language search over document names, e.g. "the Python document", "TCS PDF" or "my
/// project docx". Case-insensitive; matches whole words, word starts ("proj" finds
/// "Project_Plan.pdf") and runs of letters in names written without spaces ("PythonNotes.pdf",
/// "python_notes_v2.pdf"). A type word in the request ("pdf", "docx", "txt") prefers that type.
///
/// Everything here is generic: there are no built-in document names.
class DocumentSearch {
  const DocumentSearch._();

  /// Words that describe the request rather than the document. "doc" is here too: in speech it
  /// almost always means "document"; the DOC type can still be picked with an explicit filter.
  static const _filler = {
    'a', 'an', 'the', 'my', 'me', 'mine', 'our', 'your', 'this', 'that', 'these', 'those', 'all', 'any',
    'some', 'of', 'for', 'to', 'on', 'in', 'by', 'via', 'with', 'from', 'and', 'or', 'please', 'pls',
    'send', 'share', 'show', 'find', 'open', 'get', 'give', 'search', 'look', 'want', 'need', 'can', 'you',
    'i', 'it', 'is', 'file', 'files', 'document', 'documents', 'doc', 'docs', 'whatsapp', 'email', 'mail',
    'what', 'whats', 'about', 'inside', 'say', 'says', 'read', 'summarize', 'summarise',
    // Common Hindi / Hinglish filler ("python wala document bhejo", "mujhe woh TXT file do",
    // "Python notes me kya hai?").
    'ka', 'ki', 'ke', 'ko', 'wala', 'wali', 'wale', 'bhejo', 'bhej', 'bhejna', 'bhejdo', 'do', 'dedo', 'de',
    'dena', 'dikhao', 'dikha', 'dikhado', 'kholo', 'mera', 'meri', 'mere', 'mujhe', 'muje', 'mujhko', 'hume',
    'humein', 'hamein', 'woh', 'wo', 'vo', 'voh', 'yeh', 'ye', 'chahiye', 'chaiye', 'par', 'pe', 'mein', 'kya',
    'hai', 'h', 'isme', 'usme', 'batao', 'bata', 'padho', 'padhke', 'dikhana', 'dikhaiye', 'iska', 'iski', 'iske',
    'uska', 'uski', 'waala', 'waali', 'waale', 'karo', 'kariye', 'karna', 'bare', 'baare', 'dijiye', 'bhejiye',
    'chahie', 'plz', 'kindly',
  };

  /// The share of the request's meaningful words a document's name must contain to be offered
  /// at all. Above one half: "Java notes" never offers "Python Notes.pdf" for "notes" alone,
  /// while a three-word request still finds a name with two of them. The one place to tune it.
  static const minWordCoverage = 0.5;

  static const _typeWords = {
    'pdf': DocumentType.pdf,
    'pdfs': DocumentType.pdf,
    'docx': DocumentType.docx,
    'txt': DocumentType.txt,
  };

  static final _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// Searches [documents] for [text]. [type] (e.g. from a filter or the assistant) is used when
  /// the text names no type. With no words and no type, every document matches.
  ///
  /// [conversational] text is a request ("send me the python document"), so its filler words are
  /// left out; a search box is not, so every word typed counts.
  static DocumentSearchResult search(
    List<DocumentItem> documents,
    String? text, {
    DocumentType? type,
    int? limit,
    bool conversational = true,
  }) {
    final (words, typeInText) = parse(text, conversational: conversational);
    final wantedType = typeInText ?? type;

    final found = <DocumentMatch>[];
    for (final document in documents) {
      final typeOk = wantedType == null || document.type == wantedType;
      if (words.isEmpty) {
        if (typeOk) found.add(DocumentMatch(document, score: 0, complete: true));
        continue;
      }
      final nameWords = DocumentSearch.nameWords(document.name);
      final compact = nameWords.join();
      var score = 0, matched = 0, typos = 0;
      for (final word in words) {
        var s = _wordScore(word, nameWords, compact);
        if (s == 0 && _nearlyIn(word, nameWords)) {
          // A one-letter slip ("pyton"): it counts toward coverage but never makes a strong
          // match on its own, so the user is asked rather than given a guess.
          s = 1;
          typos++;
        }
        if (s > 0) matched++;
        score += s;
      }
      // A partial match is offered only when it has most of the words: "Java notes" must not
      // offer "Python Notes.pdf" just because both say "notes".
      if (matched / words.length <= minWordCoverage) continue;
      // The name is exactly what was asked for ("Python notes" -> "Python Notes.pdf"): ranked first.
      final exact = nameWords.length == words.length && matched == words.length && typos == 0;
      found.add(DocumentMatch(
        document,
        score: score + (typeOk ? 1 : 0) + (exact ? 2 : 0),
        complete: matched == words.length && typos == 0 && typeOk,
      ));
    }

    // Strong matches win outright. Otherwise, if a type was asked for, its documents come first
    // and the others are left out when there are any of the right type.
    var matches = found.where((m) => m.complete).toList();
    if (matches.isEmpty) {
      matches = found;
      if (wantedType != null && matches.any((m) => m.document.type == wantedType)) {
        matches = matches.where((m) => m.document.type == wantedType).toList();
      }
    }
    matches.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : b.document.date.compareTo(a.document.date);
    });
    if (limit != null && matches.length > limit) matches = matches.sublist(0, limit);
    return DocumentSearchResult(words: words, type: wantedType, matches: matches);
  }

  /// The words of a request, without filler, and the type it names (if any).
  static (List<String>, DocumentType?) parse(String? text, {bool conversational = true}) {
    DocumentType? type;
    final words = <String>[];
    for (final token in (text ?? '').toLowerCase().split(_separators)) {
      if (token.isEmpty) continue;
      // "Mansi's" -> "mansi" (the apostrophe already split it off as "s").
      if (token == 's' && conversational) continue;
      final asType = _typeWords[token];
      if (asType != null) {
        type ??= asType;
        continue;
      }
      if (conversational && _filler.contains(token)) continue;
      if (!words.contains(token)) words.add(token);
    }
    return (words, type);
  }

  /// The words of a file name, lower case: "PythonProject_v2.pdf" -> [python, project, v, 2].
  /// The extension of a supported type is left out.
  static List<String> nameWords(String name) {
    var base = name;
    final dot = base.lastIndexOf('.');
    if (dot > 0 && DocumentType.detect(base) != null) base = base.substring(0, dot);
    final spaced = base
        // camelCase and PascalCase: "pythonProject" -> "python Project", "TCSReport" -> "TCS Report".
        .replaceAllMapped(RegExp(r'(\p{Ll})(\p{Lu})', unicode: true), (m) => '${m[1]} ${m[2]}')
        .replaceAllMapped(RegExp(r'(\p{Lu})(\p{Lu}\p{Ll})', unicode: true), (m) => '${m[1]} ${m[2]}')
        // Letters and digits: "notes2024" -> "notes 2024".
        .replaceAllMapped(RegExp(r'(\p{L})(\p{N})', unicode: true), (m) => '${m[1]} ${m[2]}')
        .replaceAllMapped(RegExp(r'(\p{N})(\p{L})', unicode: true), (m) => '${m[1]} ${m[2]}');
    return [
      for (final w in spaced.toLowerCase().split(_separators))
        if (w.isNotEmpty) w,
    ];
  }

  static int _wordScore(String word, List<String> nameWords, String compact) {
    var best = 0;
    for (final n in nameWords) {
      if (n == word || _singular(n) == _singular(word)) return 3;
      if (n.startsWith(word)) best = 2;
    }
    if (best == 0 && word.length >= 3 && compact.contains(word)) best = 1;
    return best;
  }

  /// Whether [word] is one edit (a letter added, missing or changed) away from a name word.
  /// Only for longer words, where a slip is unlikely to turn one real word into another.
  static bool _nearlyIn(String word, List<String> nameWords) {
    if (word.length < 5) return false;
    return nameWords.any((n) => (n.length - word.length).abs() <= 1 && n.length >= 4 && _withinOneEdit(word, n));
  }

  static bool _withinOneEdit(String a, String b) {
    if (a == b) return true;
    if (a.length > b.length) return _withinOneEdit(b, a);
    var i = 0, j = 0, edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length == b.length) i++;
      j++;
    }
    return edits + (b.length - j) + (a.length - i) <= 1;
  }

  static String _singular(String w) => w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w;
}
