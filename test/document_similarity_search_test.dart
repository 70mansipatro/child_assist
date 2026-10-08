// Similarity search over the signed-in user's own documents, on the phone: the request wording
// (English, Hindi or Hinglish) is reduced to its meaningful words and ranked against real file
// names. Weak matches are rejected, several strong matches are offered for the user to choose,
// and nothing is ever invented.
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/features/documents/services/document_service.dart';

var _ids = 0;
DocumentItem _doc(String name) => DocumentItem(
      id: 'doc_t${_ids++}x',
      name: name,
      type: DocumentType.detect(name)!,
      reference: 'content://test/${_ids++}',
      addedAt: DateTime(2026, 10, 1),
    );

List<String> _names(DocumentSearchResult r) => [for (final d in r.documents) d.name];

void main() {
  final pythonNotes = _doc('Python Notes.pdf');
  final pythonProgramming = _doc('Python Programming.docx');
  final pythonLoops = _doc('Python Loops.txt');
  final javaNotes = _doc('Java Notes.pdf');
  final tcs = _doc('TCS Project.docx');
  final phone = [pythonNotes, pythonProgramming, pythonLoops, javaNotes, tcs];

  test('exact: "Mujhe Python notes PDF do" -> Python Notes.pdf, without asking', () {
    final r = DocumentSearch.search(phone, 'Mujhe Python notes PDF do');
    expect(r.outcome, DocumentSearchOutcome.single);
    expect(r.single!.document, pythonNotes);
  });

  test('"Python wala document do" -> the Python documents, for the user to choose', () {
    final r = DocumentSearch.search(phone, 'Python wala document do');
    expect(r.words, ['python']);
    expect(r.outcome, DocumentSearchOutcome.multiple);
    expect(_names(r).toSet(), {'Python Notes.pdf', 'Python Programming.docx', 'Python Loops.txt'});
  });

  test('"Programming wala Python document do" -> Python Programming.docx', () {
    final r = DocumentSearch.search(phone, 'Programming wala Python document do');
    expect(r.single?.document, pythonProgramming);
  });

  test('"TCS ka document do" -> TCS Project.docx', () {
    expect(DocumentSearch.search(phone, 'TCS ka document do').single?.document, tcs);
  });

  test('"Java notes PDF do" -> Java Notes.pdf, and Python Notes.pdf is not offered', () {
    final r = DocumentSearch.search(phone, 'Java notes PDF do');
    expect(r.single?.document, javaNotes);
  });

  test('weak match rejected: "Java Notes PDF do" when only Python Notes.pdf exists -> not found', () {
    final r = DocumentSearch.search([pythonNotes, _doc('TCS.docx')], 'Java Notes PDF do');
    expect(r.outcome, DocumentSearchOutcome.none);
    expect(r.notFoundMessage, "I couldn't find a matching java notes PDF in the documents Child Assist can access.");
  });

  test('not found: "Mujhe JavaScript document do" finds nothing, not Java Notes.pdf', () {
    expect(DocumentSearch.search(phone, 'Mujhe JavaScript document do').outcome, DocumentSearchOutcome.none);
  });

  test('a type alone never matches: Holiday Photos.pdf is not a "Python PDF"', () {
    final r = DocumentSearch.search([_doc('Holiday Photos.pdf'), pythonNotes], 'Python PDF do');
    expect(_names(r), ['Python Notes.pdf']);
  });

  test('multiple strong matches: "Python PDF do" asks, it never guesses', () {
    final r = DocumentSearch.search(
      [pythonNotes, _doc('Python Assignment.pdf'), _doc('Python Questions.pdf')],
      'Python PDF do',
    );
    expect(r.outcome, DocumentSearchOutcome.multiple);
    expect(r.single, isNull);
    expect(r.matches, hasLength(3));
  });

  test('the exact name ranks first among strong matches', () {
    final r = DocumentSearch.search([_doc('Python Notes Advanced.pdf'), pythonNotes], 'Python notes');
    expect(r.outcome, DocumentSearchOutcome.multiple);
    expect(r.documents.first, pythonNotes);
  });

  test('partial and prefix words: "prog" finds Python Programming.docx', () {
    expect(DocumentSearch.search(phone, 'python prog').single?.document, pythonProgramming);
  });

  test('a one-letter slip is offered for confirmation, never taken as a strong match', () {
    final r = DocumentSearch.search(phone, 'Pyton notes pdf');
    expect(r.outcome, DocumentSearchOutcome.multiple);
    expect(r.documents.first, pythonNotes);
  });

  test('Hinglish filler words are removed, meaningful words kept', () {
    for (final request in [
      'Mujhe woh python notes chahiye please',
      'Meri python notes wali file dikhao',
      'python notes waali document dikhana',
      'python notes ka document bhejo',
      'python notes iska dedo',
    ]) {
      expect(DocumentSearch.parse(request).$1, ['python', 'notes'], reason: request);
    }
  });

  test('filler words never remove a meaningful document word', () {
    expect(DocumentSearch.parse('TCS project loops assignment').$1, ['tcs', 'project', 'loops', 'assignment']);
  });

  test('the coverage threshold lives in one place and requires more than half the words', () {
    expect(DocumentSearch.minWordCoverage, 0.5);
    // Two of three words: offered (for the user to confirm). One of two: rejected.
    expect(DocumentSearch.search([pythonNotes], 'python notes loops').documents, [pythonNotes]);
    expect(DocumentSearch.search([pythonNotes], 'java notes').documents, isEmpty);
  });

  test('no built-in documents: an empty phone finds nothing for any request', () {
    for (final request in ['Python notes', 'TCS', 'Java notes PDF', 'notes.txt']) {
      expect(DocumentSearch.search(const [], request).outcome, DocumentSearchOutcome.none);
    }
  });
}
