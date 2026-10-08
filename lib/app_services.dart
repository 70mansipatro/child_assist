import 'package:flutter/material.dart';

import 'core/api/api_client.dart';
import 'core/navigation/app_menu.dart';
import 'core/notifications/notification_service.dart';
import 'core/permissions/permission_service.dart';
import 'features/auth/data/auth_api.dart';
import 'features/auth/data/token_storage.dart';
import 'features/auth/services/auth_service.dart';
import 'features/auth/services/google_auth_service.dart';
import 'features/chat/data/chat_api.dart';
import 'features/chat/services/chat_service.dart';
import 'features/chat/services/text_to_speech_service.dart';
import 'features/chat/services/voice_input.dart';
import 'features/contacts/services/contact_permission_service.dart';
import 'features/contacts/services/contact_service.dart';
import 'features/contacts/services/message_handoff.dart';
import 'features/documents/services/document_service.dart';
import 'features/location/data/location_api.dart';
import 'features/location/data/tracking_store.dart';
import 'features/location/services/automatic_location_tracking_service.dart';
import 'features/location/services/background_location_source.dart';
import 'features/location/services/location_history_service.dart';
import 'features/location/services/location_service.dart';
import 'features/notifications/data/notifications_api.dart';
import 'features/permissions/data/permissions_api.dart';
import 'features/permissions/services/permission_onboarding_service.dart';
import 'features/permissions/services/permission_sync_service.dart';
import 'features/photos/services/photo_gallery_service.dart';
import 'features/profile/data/profile_api.dart';
import 'features/profile/services/profile_photo_service.dart';
import 'features/profile/services/profile_service.dart';
import 'features/voice_assistant/data/wake_word_platform.dart';
import 'features/voice_assistant/data/wake_word_store.dart';
import 'features/voice_assistant/services/wake_word_service.dart';

/// The app's long-lived services, created once at startup and passed down to screens.
class AppServices {
  AppServices({
    required this.authService,
    required this.profileService,
    required this.profilePhotoService,
    required this.permissionService,
    required this.permissionSyncService,
    required this.permissionOnboardingService,
    required this.locationService,
    required this.locationHistoryService,
    required this.automaticTrackingService,
    required this.photoGalleryService,
    required this.documentService,
    required this.chatService,
    required this.contactService,
    required this.messageHandoff,
    required this.voiceInput,
    required this.textToSpeech,
    required this.notificationService,
    required this.wakeWordService,
  });

  /// Wires the real implementations. Tests can swap the HTTP client, storage, Google sign-in, the
  /// OS permission layer, the location hardware (foreground and background), the geocoder, the
  /// photo library, the device documents, the phone's contacts, WhatsApp/sharing, speech
  /// recognition, text-to-speech, push delivery or the wake word.
  factory AppServices.create({
    ApiClient? apiClient,
    TokenStorage? tokenStorage,
    GoogleAuthService? googleAuthService,
    PermissionService? permissionService,
    LocationProvider? locationProvider,
    PlaceLookup? placeLookup,
    BackgroundLocationSource? backgroundLocationSource,
    TrackingStore? trackingStore,
    PhotoLibrary? photoLibrary,
    DocumentPlatform? documentPlatform,
    ContactsSource? contactsSource,
    MessageHandoff? messageHandoff,
    VoiceInput? voiceInput,
    TextToSpeechService? textToSpeech,
    ProfilePhotoPlatform? profilePhotoPlatform,
    PushPlatform? pushPlatform,
    WakeWordPlatform? wakeWordPlatform,
    WakeWordStore? wakeWordStore,
  }) {
    final client = apiClient ?? ApiClient();
    final authService = AuthService(
      api: AuthApi(client),
      storage: tokenStorage ?? TokenStorage(),
      google: googleAuthService,
    );
    final permissions = permissionService ?? PermissionService();
    final profileService = ProfileService(api: ProfileApi(client), authService: authService);
    final permissionSyncService = PermissionSyncService(api: PermissionsApi(client), authService: authService);
    // One device geocoder for both manual and automatic locations.
    final places = placeLookup ?? NativePlaceLookup();
    final locationApi = LocationApi(client);
    final speech = textToSpeech ?? FlutterTextToSpeechService();
    return AppServices(
      authService: authService,
      profileService: profileService,
      profilePhotoService: ProfilePhotoService(authService: authService, platform: profilePhotoPlatform),
      permissionService: permissions,
      permissionSyncService: permissionSyncService,
      permissionOnboardingService:
          PermissionOnboardingService(profileService: profileService, authService: authService),
      locationService: LocationService(
        permissionService: permissions,
        provider: locationProvider,
        placeLookup: places,
      ),
      locationHistoryService: LocationHistoryService(api: locationApi, authService: authService),
      automaticTrackingService: AutomaticLocationTrackingService(
        authService: authService,
        api: locationApi,
        permissionService: permissions,
        permissionSyncService: permissionSyncService,
        source: backgroundLocationSource,
        placeLookup: places,
        store: trackingStore,
      ),
      photoGalleryService:
          PhotoGalleryService(permissionService: permissions, library: photoLibrary),
      documentService: DocumentService(authService: authService, platform: documentPlatform),
      chatService: ChatService(
        api: ChatApi(client),
        authService: authService,
        permissionService: permissions,
        permissionSyncService: permissionSyncService,
      ),
      contactService: ContactService(
        permission: ContactPermissionService(permissionService: permissions, syncService: permissionSyncService),
        source: contactsSource,
      ),
      messageHandoff: messageHandoff ?? const NativeMessageHandoff(),
      voiceInput: voiceInput ?? SpeechToTextVoiceInput(),
      textToSpeech: speech,
      notificationService: NotificationService(
        authService: authService,
        api: NotificationsApi(client),
        permissionService: permissions,
        permissionSyncService: permissionSyncService,
        platform: pushPlatform,
      ),
      wakeWordService: WakeWordService(
        authService: authService,
        permissionService: permissions,
        permissionSyncService: permissionSyncService,
        textToSpeech: speech,
        platform: wakeWordPlatform,
        store: wakeWordStore,
      ),
    );
  }

  final AuthService authService;
  final ProfileService profileService;

  /// The signed-in user's profile photo, kept only on this device.
  final ProfilePhotoService profilePhotoService;
  final PermissionService permissionService;
  final PermissionSyncService permissionSyncService;
  final PermissionOnboardingService permissionOnboardingService;
  final LocationService locationService;
  final LocationHistoryService locationHistoryService;

  /// Automatic Location History. Follows the signed-in account: stops on logout.
  final AutomaticLocationTrackingService automaticTrackingService;
  final PhotoGalleryService photoGalleryService;
  final DocumentService documentService;
  final ChatService chatService;

  /// Searches the phone's contacts on the device; the address book is never uploaded.
  final ContactService contactService;

  /// Opens confirmed WhatsApp messages or the share sheet; the user sends them there.
  final MessageHandoff messageHandoff;

  /// Tap-to-talk speech input for chat.
  final VoiceInput voiceInput;

  /// Reads chat replies aloud when "Voice replies" is on.
  final TextToSpeechService textToSpeech;

  /// Push notifications (FCM delivery only), the unread badge, history and preferences. Follows
  /// the signed-in account: logout unregisters this phone.
  final NotificationService notificationService;

  /// "Hey Child" hands-free voice activation (opt-in, detected on the phone). Follows the signed-in
  /// account: stops on logout.
  final WakeWordService wakeWordService;

  /// Light, dark or follow the device. Chosen in App Settings; kept for this app session only.
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

  /// Lets the ☰ menu on any page ask the signed-in app shell to open another page.
  final AppMenuController appMenu = AppMenuController();
}
