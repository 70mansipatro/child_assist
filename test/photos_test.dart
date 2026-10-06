import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/photos/screens/photo_viewer_screen.dart';
import 'package:child_assist/features/photos/screens/photos_screen.dart';
import 'package:child_assist/features/photos/services/photo_gallery_service.dart';
import 'package:child_assist/features/photos/widgets/photo_grid.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  late FakeBackend backend;
  late FakePermissionService os;
  late FakePhotoLibrary gallery;

  /// Logs in as Mansi (onboarding already done) with Photos in [photos] state, and the
  /// gallery holding [count] photos.
  Future<void> startApp(
    WidgetTester tester, {
    PermissionState photos = PermissionState.granted,
    int count = 10,
    FakePhotoLibrary? library,
  }) async {
    backend = FakeBackend();
    os = FakePermissionService()..os[AppPermission.photos] = photos;
    gallery = library ?? FakePhotoLibrary.withPhotos(count);
    final services = backend.services(os, photoLibrary: gallery);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    await logIn(tester, 'mansi@example.com');
  }

  Future<void> openPhotos(WidgetTester tester) => openFromHome(tester, 'Photos');

  Future<void> resumeApp(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  Finder thumb(String id) => find.byKey(ValueKey(id));

  /// The gallery's own scroll view (not the search field's, nor Home's underneath).
  Finder galleryScroll() => find
      .descendant(of: find.byType(PhotosScreen), matching: find.byType(Scrollable))
      .first;

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 500, scrollable: galleryScroll());
    await tester.pumpAndSettle();
  }

  int thumbnailsShown(WidgetTester tester) => tester.widgetList(find.byType(PhotoThumbnail)).length;

  /// Only the Photos permission is ever touched by the Photos feature.
  void expectOnlyPhotosPermissionUsed() {
    for (final call in os.calls) {
      expect(call, endsWith(' photos'), reason: 'unexpected permission call: $call');
    }
  }

  testWidgets('1. shows a loading state, then the grid', (tester) async {
    await startApp(tester);
    final pending = gallery.pending = Completer<void>();
    await tester.tap(find.text('Photos'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(PhotosScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(PhotoThumbnail), findsNothing);

    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(thumb('p1'), findsOneWidget);
  });

  testWidgets('2, 8. granted: photos load as thumbnails without any dialog', (tester) async {
    await startApp(tester);
    await openPhotos(tester);

    expect(os.dialogsShown, isEmpty);
    expect(thumb('p1'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Photo from')), findsWidgets);
    expect(gallery.queries, ['page 0']);
    // Grid cells read thumbnails, never full-size images.
    expect(gallery.imageReads, isNotEmpty);
    for (final read in gallery.imageReads) {
      expect(read, endsWith('300x300'));
    }
    expect(find.text('Load more'), findsNothing, reason: 'fewer than a page: nothing more to load');
    expect(backend.permissions['u1']!['PHOTOS'], 'GRANTED');
    expectOnlyPhotosPermissionUsed();
  });

  testWidgets('3. denied: explains, asks only after "Allow Photos", then loads', (tester) async {
    await startApp(tester, photos: PermissionState.denied);
    await openPhotos(tester);

    expect(find.text('Photo access is needed to show your gallery.'), findsOneWidget);
    expect(os.dialogsShown, isEmpty);
    expect(gallery.queries, isEmpty, reason: 'nothing is read without permission');

    await tester.tap(find.text('Allow Photos'));
    await tester.pumpAndSettle();
    expect(os.dialogsShown, [AppPermission.photos]);
    expect(thumb('p1'), findsOneWidget);
    expect(backend.permissions['u1']!['PHOTOS'], 'GRANTED');
    expectOnlyPhotosPermissionUsed();
  });

  testWidgets('3. denying in the system dialog keeps the message and records it', (tester) async {
    await startApp(tester, photos: PermissionState.denied);
    os.onRequest[AppPermission.photos] = PermissionState.denied;
    await openPhotos(tester);
    await tester.tap(find.text('Allow Photos'));
    await tester.pumpAndSettle();

    expect(find.text('Photo access is needed to show your gallery.'), findsOneWidget);
    expect(find.text('Allow Photos'), findsOneWidget);
    expect(find.byType(PhotoThumbnail), findsNothing);
    expect(backend.permissions['u1']!['PHOTOS'], 'DENIED');
  });

  testWidgets('4. limited: shows the selected photos, explains, and offers to change the selection',
      (tester) async {
    await startApp(tester, photos: PermissionState.limited, count: 3);
    await openPhotos(tester);

    expect(find.textContaining('selected photos only'), findsOneWidget);
    expect(thumb('p1'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(backend.permissions['u1']!['PHOTOS'], 'LIMITED');

    // Android 14: the system dialog is shown again; here the user picks "Allow all".
    await tester.tap(find.text('Select more photos'));
    await tester.pumpAndSettle();
    expect(os.calls, contains('requestAgain photos'));
    expect(find.textContaining('selected photos only'), findsNothing);
    expect(backend.permissions['u1']!['PHOTOS'], 'GRANTED');
    expect(gallery.queries, ['page 0', 'page 0'], reason: 'reloaded after the selection changed');
  });

  testWidgets('4. limited on iOS uses the photo selection picker', (tester) async {
    await startApp(
      tester,
      photos: PermissionState.limited,
      library: FakePhotoLibrary.withPhotos(3)..hasSelectionPicker = true,
    );
    await openPhotos(tester);
    await tester.tap(find.text('Select more photos'));
    await tester.pumpAndSettle();
    expect(gallery.selectionPickerShown, 1);
    expect(os.calls, isNot(contains('requestAgain photos')));
    expect(find.textContaining('selected photos only'), findsOneWidget);
    expect(gallery.queries, ['page 0', 'page 0']);
  });

  testWidgets('5. blocked: no dialog, explains and offers Settings', (tester) async {
    await startApp(tester, photos: PermissionState.permanentlyDenied);
    await openPhotos(tester);

    expect(find.text('Photo access is currently blocked.'), findsOneWidget);
    expect(find.text('You can enable it later from Settings.'), findsOneWidget);
    expect(find.text('Allow Photos'), findsNothing);
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(os.settingsOpened, 1);
    // Coming back without changing anything still does not show a dialog.
    await resumeApp(tester);
    expect(os.calls.where((c) => c.startsWith('request')), isEmpty);
    expect(os.dialogsShown, isEmpty);
  });

  testWidgets('restricted and unavailable are explained without crashing', (tester) async {
    await startApp(tester, photos: PermissionState.restricted);
    await openPhotos(tester);
    expect(find.text('Photo access is restricted on this device.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    os.os[AppPermission.photos] = PermissionState.unavailable;
    await openPhotos(tester);
    expect(find.text('Photos are not available on this device.'), findsOneWidget);
    expect(gallery.queries, isEmpty);
  });

  testWidgets('6. a failed load shows Retry, which loads again', (tester) async {
    await startApp(tester);
    gallery.pageFailures = 1;
    await openPhotos(tester);

    expect(find.text('Unable to load photos.'), findsOneWidget);
    expect(find.text('Please try again.'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing, reason: 'no technical details shown');
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(thumb('p1'), findsOneWidget);
  });

  testWidgets('7. an empty gallery is not an error', (tester) async {
    await startApp(tester, count: 0);
    await openPhotos(tester);
    expect(find.text('No photos found'), findsOneWidget);
    expect(find.text("Your device gallery doesn't contain any photos yet."), findsOneWidget);
    expect(find.text('Unable to load photos.'), findsNothing);
  });

  testWidgets('9. pagination: pages load as the user scrolls, and stop at the end', (tester) async {
    await startApp(tester, count: 150); // 60 + 60 + 30
    await openPhotos(tester);
    expect(gallery.queries, ['page 0']);
    expect(thumbnailsShown(tester), lessThan(60), reason: 'cells are built lazily');

    await scrollTo(tester, thumb('p65'));
    expect(gallery.queries, ['page 0', 'page 1']);
    await scrollTo(tester, thumb('p150'));
    expect(gallery.queries, ['page 0', 'page 1', 'page 2']);

    await tester.drag(galleryScroll(), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text('Load more'), findsNothing);
    expect(gallery.queries, hasLength(3), reason: 'no query past the last page');
    expect(thumbnailsShown(tester), lessThan(150), reason: 'scrolled-away cells are released');
  });

  testWidgets('9. a failed next page can be retried', (tester) async {
    await startApp(tester, count: 70);
    await openPhotos(tester);
    gallery.pageFailures = 1;
    await scrollTo(tester, find.text("Couldn't load more photos."));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(gallery.queries, ['page 0', 'page 1', 'page 1']);
    await scrollTo(tester, thumb('p70'));
    expect(thumb('p70'), findsOneWidget);
  });

  testWidgets('9. "Load more" fetches the next page when the screen is not scrollable',
      (tester) async {
    // A large screen: the whole first page fits, so scrolling cannot trigger the next page.
    tester.view.physicalSize = const Size(2400, 8000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await startApp(tester, count: 70);
    await openPhotos(tester);
    expect(gallery.queries, ['page 0']);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(gallery.queries, ['page 0', 'page 1']);
    expect(thumb('p70'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('10-12. viewer shows the photo and its metadata; back returns to Photos, then Home',
      (tester) async {
    await startApp(tester);
    await openPhotos(tester);
    await tester.tap(thumb('p1'));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoViewerScreen), findsOneWidget);
    expect(find.bySemanticsLabel('Selected photo'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('IMG_0001.jpg'), findsWidgets); // title and Name row
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Time'), findsOneWidget);
    expect(find.text('4032 × 3024'), findsOneWidget);
    expect(find.text('JPEG'), findsOneWidget);
    expect(find.text('2.3 MB'), findsOneWidget);
    // A screen-sized preview is read, not the 4032 x 3024 original.
    expect(gallery.imageReads.last, 'p1 2048x1536');
    // Nothing in the viewer edits or deletes.
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byIcon(Icons.edit), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(PhotosScreen), findsOneWidget);
    expect(thumb('p1'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Quick Actions'), findsOneWidget);
  });

  testWidgets('viewer shows only metadata the device reported', (tester) async {
    await startApp(
      tester,
      library: FakePhotoLibrary([
        PhotoItem(
          id: 'bare',
          width: 0,
          height: 0,
          createdAt: DateTime.utc(2026, 1, 2),
          modifiedAt: DateTime.utc(2026, 1, 2),
        ),
      ]),
    );
    await openPhotos(tester);
    await tester.tap(thumb('bare'));
    await tester.pumpAndSettle();
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Name'), findsNothing);
    expect(find.text('Dimensions'), findsNothing);
    expect(find.text('File type'), findsNothing);
  });

  testWidgets('13. Refresh re-reads the permission and the gallery', (tester) async {
    await startApp(tester, count: 2);
    await openPhotos(tester);
    expect(thumb('new'), findsNothing);

    gallery.photos.insert(
      0,
      PhotoItem(
        id: 'new',
        name: 'IMG_9999.jpg',
        width: 100,
        height: 100,
        createdAt: DateTime.utc(2026, 10, 7),
        modifiedAt: DateTime.utc(2026, 10, 7),
      ),
    );
    final resets = gallery.resets;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(thumb('new'), findsOneWidget);
    expect(gallery.resets, greaterThan(resets));
    expect(os.calls.where((c) => c == 'status photos'), hasLength(2));
  });

  testWidgets('14. a change made in Settings is picked up when the app resumes', (tester) async {
    await startApp(tester, photos: PermissionState.permanentlyDenied);
    await openPhotos(tester);
    expect(find.text('Photo access is currently blocked.'), findsOneWidget);

    os.os[AppPermission.photos] = PermissionState.granted; // enabled in Settings
    await resumeApp(tester);
    expect(thumb('p1'), findsOneWidget);
    expect(backend.permissions['u1']!['PHOTOS'], 'GRANTED');

    os.os[AppPermission.photos] = PermissionState.denied; // revoked in Settings
    await resumeApp(tester);
    expect(find.byType(PhotoThumbnail), findsNothing);
    expect(find.text('Allow Photos'), findsOneWidget);
    expect(backend.permissions['u1']!['PHOTOS'], 'DENIED');
    expect(os.dialogsShown, isEmpty);
  });

  testWidgets('resuming with unchanged full access keeps the loaded photos', (tester) async {
    await startApp(tester, count: 70);
    await openPhotos(tester);
    await scrollTo(tester, thumb('p70'));
    expect(gallery.queries, ['page 0', 'page 1']);
    await resumeApp(tester);
    expect(gallery.queries, ['page 0', 'page 1']);
  });

  testWidgets('search matches loaded photos by file name', (tester) async {
    await startApp(tester, count: 12);
    await openPhotos(tester);
    await tester.enterText(find.byType(TextField), 'img_0012');
    await tester.pumpAndSettle();
    expect(find.text('1 of 12 loaded photos match.'), findsOneWidget);
    expect(thumb('p12'), findsOneWidget);
    expect(thumb('p1'), findsNothing);

    await tester.enterText(find.byType(TextField), 'holiday');
    await tester.pumpAndSettle();
    expect(find.textContaining('No loaded photos have a name containing "holiday"'), findsOneWidget);
    expect(gallery.queries, ['page 0'], reason: 'searching is local');
  });

  testWidgets('date filter queries the gallery by creation date', (tester) async {
    await startApp(tester, count: 10);
    await openPhotos(tester);
    await tester.tap(find.text('Any date'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Start Date'), '10/02/2026');
    await tester.enterText(find.widgetWithText(TextField, 'End Date'), '10/04/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(gallery.queries.last, 'page 0 2026-10-02..2026-10-04');
    expect(thumb('p3'), findsOneWidget); // 4 Oct
    expect(thumb('p5'), findsOneWidget); // 2 Oct
    expect(thumb('p1'), findsNothing); // 6 Oct
    expect(thumb('p6'), findsNothing); // 1 Oct

    await tester.tap(find.text('Clear dates'));
    await tester.pumpAndSettle();
    expect(gallery.queries.last, 'page 0');
    expect(thumb('p1'), findsOneWidget);
  });

  testWidgets('15. onboarding is unchanged and its Photos answer is what the gallery sees',
      (tester) async {
    backend = FakeBackend();
    os = FakePermissionService();
    gallery = FakePhotoLibrary.withPhotos(3);
    os.onRequest[AppPermission.photos] = PermissionState.limited;
    final services = backend.services(os, photoLibrary: gallery);
    await services.authService.restoreSession();
    await tester.pumpWidget(MyApp(services: services));
    final id = backend.addUser('New Kid', 'new@example.com');
    await logIn(tester, 'new@example.com');

    for (final title in [
      'Location Access',
      'Camera Access',
      'Microphone Access',
      'Photos Access',
      'Notifications',
    ]) {
      expect(find.text(title), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
    }
    expect(gallery.queries, isEmpty, reason: 'onboarding never reads the gallery');
    expect(backend.permissions[id]!['PHOTOS'], 'LIMITED');

    final dialogs = os.dialogsShown.length;
    await openPhotos(tester);
    expect(find.textContaining('selected photos only'), findsOneWidget);
    expect(thumb('p1'), findsOneWidget);
    expect(os.dialogsShown, hasLength(dialogs), reason: 'no second dialog');
  });

  test('photo metadata for later features holds no image data or paths', () {
    final photo = FakePhotoLibrary.withPhotos(1).photos.single.withDetails(fileSize: 1234);
    expect(photo.toJson(), {
      'id': 'p1',
      'name': 'IMG_0001.jpg',
      'createdAt': '2026-10-06T10:30:00.000Z',
      'modifiedAt': '2026-10-06T10:30:00.000Z',
      'width': 4032,
      'height': 3024,
      'mimeType': 'image/jpeg',
      'fileSize': 1234,
    });
    expect(fileSizeLabel(512), '512 B');
    expect(fileSizeLabel(2048), '2 KB');
    expect(fileTypeLabel('image/heic'), 'HEIC');
  });

  test('preview size keeps the aspect ratio and never upscales', () async {
    final library = FakePhotoLibrary();
    final service = PhotoGalleryService(permissionService: FakePermissionService(), library: library);
    PhotoItem sized(int w, int h) => PhotoItem(
          id: '${w}x$h',
          width: w,
          height: h,
          createdAt: DateTime(2026),
          modifiedAt: DateTime(2026),
        );
    await service.preview(sized(3024, 4032));
    await service.preview(sized(800, 600));
    await service.preview(sized(0, 0));
    expect(library.imageReads, ['3024x4032 1536x2048', '800x600 800x600', '0x0 2048x2048']);
  });

  test('thumbnails are cached, so scrolling back does not read them again', () async {
    final library = FakePhotoLibrary.withPhotos(2);
    final service = PhotoGalleryService(permissionService: FakePermissionService(), library: library);
    await service.thumbnail(library.photos[0]);
    await service.thumbnail(library.photos[0]);
    await service.thumbnail(library.photos[1]);
    expect(library.imageReads, ['p1 300x300', 'p2 300x300']);
    service.reset();
    await service.thumbnail(library.photos[0]);
    expect(library.imageReads, hasLength(3));
  });
}
