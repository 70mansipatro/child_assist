// AI photo search and recognition in chat: the phone searches its own gallery (by date, by the
// user's saved places and by file name), shows only strong matches, reports only their metadata,
// sends only the ONE photo asked about for analysis, and shares a photo only after confirmation.
// Every place, time and name here is generated: nothing depends on a fixed photo.
//
// These tests use a fake gallery and a fake server. They do not replace testing on a real Android
// phone (photo_manager, MediaStore GPS and WhatsApp are only exercised there).
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/chat/models/chat_message.dart';
import 'package:child_assist/features/chat/screens/chat_screen.dart';
import 'package:child_assist/features/photos/screens/photo_viewer_screen.dart';
import 'package:child_assist/features/photos/services/photo_gallery_service.dart';
import 'package:child_assist/features/photos/services/photo_matcher.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

final _random = Random();
String _word([int length = 7]) => String.fromCharCodes(List.generate(length, (_) => 97 + _random.nextInt(26)));
String _cap(String w) => '${w[0].toUpperCase()}${w.substring(1)}';
double _lat() => 10 + _random.nextDouble() * 20;
double _lng() => 70 + _random.nextDouble() * 20;

/// The start of today and of tomorrow, in UTC, as the server would send them.
(DateTime, DateTime) _today() {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  return (start.toUtc(), start.add(const Duration(days: 1)).toUtc());
}

/// A photo taken [ago] before now, with a generated name.
PhotoItem _photo(String id, Duration ago, {String? name}) {
  final at = DateTime.now().subtract(ago);
  return PhotoItem(
    id: id,
    name: name ?? 'IMG_${_random.nextInt(9000) + 1000}.jpg',
    width: 4000,
    height: 3000,
    createdAt: at,
    modifiedAt: at,
    mimeType: 'image/jpeg',
  );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // -------------------------------------------------------------------------------------------
  group('PhotoMatcher (unit)', () {
    final (start, end) = _today();
    PhotoVisit visit(Duration ago, {double? lat, double? lng, String? name}) => PhotoVisit(
          capturedAt: DateTime.now().subtract(ago),
          latitude: lat ?? _lat(),
          longitude: lng ?? _lng(),
          placeName: name ?? _cap(_word()),
        );

    test('date-based: only photos taken in the period', () {
      final inside = _photo('a', Duration.zero);
      final before = _photo('b', const Duration(days: 3));
      final result = PhotoMatcher.match([inside, before], PhotoSearchQuery(start: start, end: end));
      expect(result.matches.map((m) => m.item.id), ['a']);
      expect(result.matches.single.evidence, PhotoEvidence.date);
    });

    test("location context: the photo's own GPS near a saved place wins; far GPS is excluded", () {
      final place = visit(const Duration(minutes: 30));
      final near = _photo('near', const Duration(minutes: 25));
      final far = _photo('far', const Duration(minutes: 31)); // closest in time, but GPS says elsewhere
      final noGps = _photo('nogps', const Duration(minutes: 40));
      final result = PhotoMatcher.match(
        [near, far, noGps],
        PhotoSearchQuery(start: start, end: end, locationContext: true, visits: [place]),
        positions: {
          'near': PhotoPosition(place.latitude + 0.001, place.longitude),
          'far': PhotoPosition(place.latitude + 0.5, place.longitude),
        },
      );
      expect(result.matches.map((m) => m.item.id), ['near']);
      expect(result.matches.single.evidence, PhotoEvidence.gps);
      expect(result.matches.single.placeLine, 'Taken near ${place.placeName}');
    });

    test('location context without GPS: matched by time, never claimed as taken at the place', () {
      final place = visit(const Duration(hours: 2));
      final close = _photo('close', const Duration(hours: 2, minutes: 20));
      final late = _photo('late', const Duration(minutes: 10)); // 110 minutes after: too far apart
      final result = PhotoMatcher.match(
        [close, late],
        PhotoSearchQuery(start: start, end: end, locationContext: true, visits: [place]),
      );
      expect(result.matches.map((m) => m.item.id), ['close']);
      expect(result.matches.single.evidence, PhotoEvidence.time);
      expect(result.matches.single.placeLine, 'Taken around when you were at ${place.placeName}');
    });

    test('no saved places: nothing is matched to "where I went"', () {
      final result = PhotoMatcher.match(
        [_photo('a', Duration.zero)],
        PhotoSearchQuery(start: start, end: end, locationContext: true),
      );
      expect(result.matches, isEmpty);
      expect(result.reason, PhotoNoMatchReason.noVisits);
    });

    test('file name: every word must be in the name; one unrelated keyword is not enough', () {
      final w = _word();
      final named = _photo('named', Duration.zero, name: '${w}_trip_${_word()}.jpg');
      final other = _photo('other', Duration.zero, name: '${w}_${_word()}.jpg');
      var result = PhotoMatcher.match([named, other], PhotoSearchQuery(fileName: '$w trip'));
      expect(result.matches.map((m) => m.item.id), ['named']);
      result = PhotoMatcher.match([named, other], PhotoSearchQuery(fileName: _word(9)));
      expect(result.matches, isEmpty);
      expect(result.reason, PhotoNoMatchReason.noNameMatch);
    });

    test('content only ("the photo with the dog") never picks a photo by itself', () {
      final result = PhotoMatcher.match([_photo('a', Duration.zero)], const PhotoSearchQuery(visualHint: 'dog'));
      expect(result.matches, isEmpty);
      expect(result.reason, PhotoNoMatchReason.contentOnly);
    });

    test('latest: exactly the newest photo', () {
      final photos = [
        for (var i = 1; i <= 4; i++) _photo('p$i', Duration(hours: _random.nextInt(48) + i * 50)),
        _photo('newest', const Duration(minutes: 1)),
      ];
      final result = PhotoMatcher.match(photos..shuffle(), const PhotoSearchQuery(latest: true));
      expect(result.matches.map((m) => m.item.id), ['newest']);
    });

    test('many strong matches are capped for display but counted', () {
      final photos = [for (var i = 0; i < 20; i++) _photo('p$i', Duration(minutes: i))];
      final result = PhotoMatcher.match(photos, PhotoSearchQuery(start: start.subtract(const Duration(days: 1)), end: end));
      expect(result.matches, hasLength(PhotoMatcher.maxShown));
      expect(result.total, 20);
    });

    test('a 0,0 or missing GPS position is "no GPS", never a made-up place', () {
      expect(PhotoPosition.tryCreate(0, 0), isNull);
      expect(PhotoPosition.tryCreate(null, _lng()), isNull);
      expect(PhotoPosition.tryCreate(95, 10), isNull);
      expect(PhotoPosition.tryCreate(_lat(), _lng()), isNotNull);
    });

    test('what is reported for a shown photo: no path, URI, device id or file name', () {
      final photo = _photo('12345', Duration.zero, name: 'secret_${_word()}.jpg');
      final report = ChatPhoto(item: photo, evidence: PhotoEvidence.gps, visit: visit(Duration.zero, name: 'A <b>"x"</b>'))
          .toReport();
      final json = jsonEncode(report);
      expect(json, isNot(contains('12345')));
      expect(json, isNot(contains('secret_')));
      expect(json, isNot(contains('content://')));
      expect(report.keys, unorderedEquals(['capturedAt', 'width', 'height', 'place']));
      expect((report['place'] as Map)['name'], isNot(contains('<')));
    });
  });

  // -------------------------------------------------------------------------------------------
  group('photos in chat (widget)', () {
    late FakeBackend backend;
    late FakePermissionService os;
    late FakePhotoLibrary gallery;
    late FakeMessageHandoff handoff;
    late AppServices services;

    Future<void> startApp(WidgetTester tester, List<PhotoItem> photos) async {
      backend = FakeBackend();
      os = FakePermissionService()..os[AppPermission.photos] = PermissionState.granted;
      gallery = FakePhotoLibrary(photos);
      handoff = FakeMessageHandoff();
      services = backend.services(os, photoLibrary: gallery, messageHandoff: handoff);
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
      await openTab(tester, 'Chat');
      expect(find.byType(ChatScreen), findsOneWidget);
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
    }

    Future<void> tapIt(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    var next = 1;

    /// The server's reply to a photo request: a search for the phone to run.
    void respondWithSearch({bool locationContext = false, List<PhotoVisit> visits = const [], bool latest = false, String? visualHint}) {
      final (start, end) = _today();
      backend.chatResponder = (_) => FakeChatReply(
            'Let me find that photo.',
            toolEvents: [
              {
                'kind': 'photos',
                'status': 'device_lookup',
                'data': {
                  'requestId': 'search${next++}',
                  'query': {
                    'startDate': latest ? null : start.toIso8601String(),
                    'endDate': latest ? null : end.toIso8601String(),
                    'locationContext': locationContext,
                    'latest': latest,
                    'visualHint': visualHint,
                  },
                  'visits': [
                    for (final v in visits)
                      {
                        'capturedAt': v.capturedAt.toUtc().toIso8601String(),
                        'latitude': v.latitude,
                        'longitude': v.longitude,
                        'placeName': v.placeName,
                      },
                  ],
                },
              },
            ],
          );
    }

    /// The server's reply to a question about [photoId]: an analysis for the phone to send.
    void respondWithAnalysis(String photoId) {
      backend.chatResponder = (_) => FakeChatReply(
            'Let me look at the photo.',
            toolEvents: [
              {
                'kind': 'photo_analysis',
                'status': 'device_lookup',
                'data': {'requestId': 'analysis${next++}', 'photoId': photoId},
              },
            ],
          );
    }

    String onlyPhotoId() => backend.photoStore.keys.single;

    /// Nothing the phone sent anywhere contains a path, a content URI or a device photo id.
    void expectNoLeaks(List<String> deviceIds) {
      final sent = jsonEncode([backend.chatRequests, backend.photoBodies, backend.chatActionBodies]);
      expect(sent, isNot(contains('content://')));
      expect(sent, isNot(contains('/storage/')));
      for (final id in deviceIds) {
        expect(sent, isNot(contains('"$id"')), reason: 'device photo ids never leave the phone');
      }
    }

    testWidgets('"Where did I go today? Send me that picture." shows the one photo taken there', (tester) async {
      final place = PhotoVisit(
        capturedAt: DateTime.now().subtract(const Duration(minutes: 50)),
        latitude: _lat(),
        longitude: _lng(),
        placeName: '${_cap(_word())} ${_cap(_word())}',
      );
      final there = _photo('101', const Duration(minutes: 45));
      final elsewhere = _photo('102', const Duration(minutes: 52));
      await startApp(tester, [there, elsewhere]);
      gallery.positions['101'] = PhotoPosition(place.latitude + 0.0008, place.longitude - 0.0005);
      gallery.positions['102'] = PhotoPosition(place.latitude + 1, place.longitude);

      respondWithSearch(locationContext: true, visits: [place]);
      await send(tester, 'Where did I go today? Send me that picture.');

      expect(find.text('Taken near ${place.placeName}'), findsOneWidget);
      expect(find.text('Open Photo'), findsOneWidget);
      expect(find.text('Analyze'), findsOneWidget);
      expect(backend.photoCalls.where((c) => c.startsWith('results')).single, endsWith('found'));
      final reported = (backend.photoBodies.single['photos'] as List).single as Map;
      expect(reported['place'], {'name': place.placeName, 'evidence': 'gps'});
      expect(gallery.imageReads.every((r) => !r.contains('1536')), isTrue, reason: 'no full image for a search');
      expectNoLeaks(['101', '102']);

      await tapIt(tester, find.text('Open Photo'));
      expect(find.byType(PhotoViewerScreen), findsOneWidget);
    });

    testWidgets('several strong matches: the user is asked which one, then picks it', (tester) async {
      await startApp(tester, [for (var i = 1; i <= 3; i++) _photo('20$i', Duration(minutes: i * 7))]);
      respondWithSearch();
      await send(tester, "Show me today's photos");

      expect(find.text('I found 3 matching photos. Which one would you like?'), findsOneWidget);
      expect(find.text('Open Photo'), findsNothing, reason: 'never silently picks one');

      final firstChoice = find.byKey(ValueKey('choose-photo-${backend.photoStore.keys.first}'));
      await tapIt(tester, find.descendant(of: firstChoice, matching: find.byType(InkWell)).first);
      expect(backend.photoCalls.where((c) => c.startsWith('select')), hasLength(1));
      expect(find.text('Open Photo'), findsOneWidget);
      expect(find.text('Choose another photo'), findsOneWidget);
    });

    testWidgets('no matching photo: a clear message, nothing invented', (tester) async {
      await startApp(tester, [_photo('301', const Duration(days: 4))]);
      respondWithSearch();
      await send(tester, "Give me the photo I took today");
      expect(find.text("I couldn't find a matching photo in your available photos."), findsOneWidget);
      expect(find.text('Open Photo'), findsNothing);
      expect(backend.photoBodies.single['outcome'], 'none');
    });

    testWidgets('"the photo with the dog": not searched by content, said honestly', (tester) async {
      await startApp(tester, [_photo('311', Duration.zero)]);
      respondWithSearch(latest: true, visualHint: 'dog');
      // With a narrowing request (the latest photo) the photo is shown with an honest note.
      await send(tester, 'Show my latest photo with the dog');
      expect(find.textContaining("I can't search inside photos"), findsOneWidget);
    });

    testWidgets('Photos permission denied: the permission card, and the gallery is never read', (tester) async {
      await startApp(tester, [_photo('401', Duration.zero)]);
      os.os[AppPermission.photos] = PermissionState.permanentlyDenied;
      respondWithSearch();
      await send(tester, "Show me today's photo");
      expect(find.text("I can't access your photos because Photos permission is turned off."), findsOneWidget);
      expect(gallery.queries, isEmpty);
      expect(backend.photoBodies.single['outcome'], 'permission_denied');
      expect(os.dialogsShown, isEmpty, reason: 'chat never shows a permission dialog');
    });

    testWidgets('limited Photos access: searches what the user allowed and says so', (tester) async {
      await startApp(tester, [_photo('501', const Duration(days: 5))]);
      os.os[AppPermission.photos] = PermissionState.limited;
      respondWithSearch();
      await send(tester, "Show me today's photo");
      expect(find.textContaining('only see the photos you allowed'), findsWidgets);
      expect(backend.photoBodies.single['limited'], isTrue);
    });

    testWidgets('"What is in this photo?" sends exactly that one photo; follow-ups reuse it', (tester) async {
      await startApp(tester, [_photo('601', const Duration(minutes: 5)), _photo('602', const Duration(days: 9))]);
      respondWithSearch();
      await send(tester, "Show me today's photo");
      final photoId = onlyPhotoId();

      respondWithAnalysis(photoId);
      await send(tester, 'What is in this photo?');
      expect(find.text('Answered from this photo.'), findsOneWidget);
      expect(backend.analysedImages, hasLength(1));
      expect(find.text('This photo shows an image of ${backend.analysedImages.single.length} bytes.'), findsOneWidget);
      expect(gallery.imageReads, contains('601 1536x1152'), reason: 'scaled for analysis, not the original');
      expect(gallery.imageReads.where((r) => r.startsWith('602 1536')), isEmpty, reason: 'no other photo is sent');

      final searches = backend.photoCalls.where((c) => c.startsWith('results')).length;
      respondWithAnalysis(photoId);
      await send(tester, 'Is there a car in it?');
      expect(backend.analysedImages, hasLength(2));
      expect(backend.photoCalls.where((c) => c.startsWith('results')).length, searches, reason: 'no new gallery search');
      final answers = backend.photoBodies.where((b) => b.containsKey('image')).toList();
      expect(answers.map((b) => b['photoId']).toSet(), {photoId});
      expect(answers.first.keys, unorderedEquals(['photoId', 'image', 'conversationId']));
      expectNoLeaks(['601', '602']);
    });

    testWidgets('Analyze on the card asks about that photo', (tester) async {
      await startApp(tester, [_photo('651', const Duration(minutes: 3))]);
      respondWithSearch();
      await send(tester, "Show me today's photo");
      respondWithAnalysis(onlyPhotoId());
      await tapIt(tester, find.text('Analyze'));
      expect(backend.chatRequests.last['message'], 'What is in this photo?');
      expect(backend.photoCalls, contains('select ${onlyPhotoId()}'));
      expect(find.text('Answered from this photo.'), findsOneWidget);
    });

    testWidgets('a deleted photo is reported as unavailable; nothing is sent or guessed', (tester) async {
      await startApp(tester, [_photo('701', const Duration(minutes: 5))]);
      respondWithSearch();
      await send(tester, "Show me today's photo");
      gallery.deleted.add('701');
      respondWithAnalysis(onlyPhotoId());
      await send(tester, 'What is in this photo?');
      expect(find.text('This photo is no longer available on your device.'), findsOneWidget);
      expect(backend.analysedImages, isEmpty);
      expect(backend.photoCalls.last, endsWith('unavailable'));
    });

    testWidgets('an unknown or unauthorized photo id is never resolved to a photo', (tester) async {
      await startApp(tester, [_photo('751', Duration.zero)]);
      respondWithAnalysis('photo_${_word(20)}');
      await send(tester, 'What is in this photo?');
      expect(find.text('This photo is no longer available on your device.'), findsOneWidget);
      expect(gallery.imageReads, isEmpty);
      expect(backend.analysedImages, isEmpty);
    });

    testWidgets('vision failure: an honest error, no made-up description', (tester) async {
      await startApp(tester, [_photo('801', const Duration(minutes: 5))]);
      respondWithSearch();
      await send(tester, "Show me today's photo");
      backend.photoVisionFails = true;
      respondWithAnalysis(onlyPhotoId());
      await send(tester, 'Describe this image');
      expect(find.textContaining("couldn't look at the photo"), findsOneWidget);
      expect(find.textContaining('This photo shows'), findsNothing);
    });

    testWidgets('"Send this photo on WhatsApp": asks first, then only opens WhatsApp', (tester) async {
      await startApp(tester, [_photo('901', const Duration(minutes: 5))]);
      respondWithSearch();
      await send(tester, "Show me today's photo");
      final photoId = onlyPhotoId();
      backend.chatResponder = (_) => FakeChatReply(
            "I found the photo from today's visit. Do you want to share it on WhatsApp?",
            toolEvents: [
              {
                'kind': 'photo_share',
                'status': 'confirmation_required',
                'data': {'photo': {'id': photoId}, 'app': 'whatsapp'},
              },
            ],
          );
      await send(tester, 'Send this photo on WhatsApp');
      expect(find.text('Do you want to share this photo on WhatsApp?'), findsOneWidget);
      expect(handoff.calls, isEmpty, reason: 'nothing happens before Confirm');

      await tapIt(tester, find.widgetWithText(FilledButton, 'Confirm'));
      expect(handoff.calls, ['whatsapp-document null: ${FakePhotoLibrary.referenceFor('901')}']);
      expect(find.text('WhatsApp opened. Tap Send to complete it.'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\bPhoto sent\b', caseSensitive: false)), findsNothing);
      expectNoLeaks(['901']);
    });

    testWidgets('sending the photo to a contact goes through the confirmation card', (tester) async {
      await startApp(tester, [_photo('951', const Duration(minutes: 5))]);
      respondWithSearch();
      await send(tester, "Show me today's photo");
      final photoId = onlyPhotoId();
      final name = _cap(_word());
      final phone = '98${_random.nextInt(90000000) + 10000000}';
      backend.chatResponder = (_) => FakeChatReply(
            "I've prepared it. Please confirm.",
            toolEvents: const [
              {'kind': 'send_action', 'status': 'confirmation_required'},
            ],
            pendingActions: [
              {
                'id': 'act${next++}',
                'toolName': 'prepare_whatsapp',
                'type': 'SHARE_PHOTO',
                'channel': 'WHATSAPP',
                'summary': 'Do you want to share this photo with $name on WhatsApp?',
                'recipientName': name,
                'recipientAddress': phone,
                'message': '',
                'photoId': photoId,
              },
            ],
          );
      await send(tester, 'Send this photo to $name on WhatsApp');
      expect(find.text('Do you want to share this photo with $name on WhatsApp?'), findsOneWidget);
      expect(find.text('Photo'), findsOneWidget);
      expect(handoff.calls, isEmpty);

      await tapIt(tester, find.widgetWithText(FilledButton, 'Confirm'));
      expect(handoff.calls, ['whatsapp-document $phone: ${FakePhotoLibrary.referenceFor('951')}']);
      expect(find.text('WhatsApp opened. Tap Send to complete it.'), findsOneWidget);
      expectNoLeaks(['951']);
    });
  });
}
