# child_assist

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Automatic Location History

An opt-in companion to "Get Current Location". While the user has it switched on (Location tab) and
the OS allows background location, the app saves the **significant places** the user stays at, so
Child Assist can answer "Where did I go today?". Manual "Get Current Location" is unchanged.

**No API key is needed.** GPS comes from the phone, place names from the phone's own geocoder
(`geocoding`), storage is the existing `LocationHistory` table, and chat uses the existing Vertex AI
setup. No Google Maps / Geocoding / Places API is used.

### How it works

- `AutomaticLocationTrackingService` (`lib/features/location/services/`) owns permissions, the
  background stream, stop detection, geocoding, the upload queue and logout/lifecycle handling.
  `LocationService` stays manual-only.
- Background location uses geolocator's own Android foreground service (persistent notification
  "Child Assist is tracking your location history") and iOS background location updates. Balanced
  accuracy, 50 m OS distance filter, no wake lock.
- `TravelPointFilter` decides what is a place: a reading within **100 m** of the last saved place
  is the same place; a new spot is saved only after the phone stays within 100 m of it for
  **5 minutes** (confirmed with one fresh reading), with the arrival time. Passing through saves
  nothing. All thresholds live in `AutomaticTrackingConfig`.
- Uploads go to the existing `POST /api/location` with `"source": "AUTOMATIC"` and the normal JWT.
  The server skips an automatic point within `AUTO_LOCATION_MIN_DISTANCE_METERS` (100) and
  `AUTO_LOCATION_MIN_INTERVAL_SECONDS` (300) of an existing one (`200 {"saved": false,
  "reason": "duplicate"}`), refuses automatic points older than 7 days, and rate-limits saves per
  account (`LOCATION_RATE_LIMIT_MAX` per `LOCATION_RATE_LIMIT_WINDOW_SECONDS`).
- Offline: places wait in a small per-account queue in secure storage (latitude, longitude,
  capturedAt only), are geocoded and uploaded oldest first when the network is back, and are
  retried every 5 minutes. Logout switches tracking off and deletes that account's queue.
- Status shown to the user is derived from the OS (permission, location services, running stream):
  Off, Starting, Tracking active, Paused (location off / permission needs attention), Not tracking.

### Platform notes and known limitations

- **Android:** needs "Allow all the time" location (Android 10+ asks separately; Android 11+
  sends the user to Settings). Tracking runs while the app process is alive, including in the
  background and with the screen locked. If the user swipes the app away from Recents or
  force-stops it, Android ends the foreground service and tracking stops (the notification goes
  away) until the app is opened again; it then resumes automatically if permission is still
  granted. Some manufacturers' battery savers stop background apps more aggressively; the Location
  tab links to the app's settings for that. Without the notification permission (Android 13+) the
  tracking notification is hidden from the shade but Android still lists the app as active.
- **iOS:** `NSLocationAlwaysAndWhenInUseUsageDescription`, `UIBackgroundModes: location` and the
  `PERMISSION_LOCATION` Podfile macro are configured. **iOS implementation requires real-device
  testing on macOS; it has not been verified.**

### Chat memory

`get_location_history` returns manual and automatic places together (with `source`), and can
filter to one kind. The assistant is told that saved places are points in time, not routes, so it
must not claim routes, stay durations or departure times. Conversations send the most recent
`CHAT_HISTORY_MESSAGE_LIMIT` (30) messages to Gemini; older ones are folded into a server-only
`ChatConversation.summary` every `CHAT_SUMMARY_BATCH` (10) messages (secrets redacted, no places or
coordinates). Deleting a chat never deletes location history.

## Notifications

Push notifications use **Firebase Cloud Messaging for delivery only**. Accounts, the notification
history, preferences and device registrations live in PostgreSQL (`NotificationDevice`,
`Notification`, `NotificationPreference`); no Firebase Authentication, Firestore, Realtime Database
or Storage is used.

### How it works

- Business events call `notifyInBackground` (`backend/src/modules/notifications/`): preference
  check, history row, push to every registered phone of the account, invalid FCM tokens removed.
  A failed push never fails the login, password reset or email that caused it.
- All text comes from fixed templates in `notification.types.ts`. Pushes never contain
  coordinates, addresses, contact details, email/chat content, codes or tokens; content that looks
  like any of these is refused. The app loads details itself, authenticated, after a tap.
- Sent today: new login and password reset (Security, always on), a permission Child Assist uses
  being turned off, Automatic Location History started / stopped / paused (only real changes, via
  `POST /api/location/tracking-status`), at most one "Travel history updated" per day, "Email
  sent" / "Email could not be sent" after a confirmed email, and "WhatsApp opened — tap Send in
  WhatsApp" (never "sent"). Chat replies are synchronous, so "Your requested information is ready"
  exists as a template but is not sent yet; documents and photos stay local and send nothing.
- Repeated events are deduplicated server-side (a per-user dedupe key, inserted with
  `ON CONFLICT DO NOTHING`).
- The app (`lib/core/notifications/notification_service.dart`) registers the phone's FCM token
  after sign-in once the OS allows notifications (the permission walkthrough asks; nothing else
  shows a dialog), shows pushes that arrive while it is open (except chat results while Chat is
  open; security alerts also show in-app), and opens a tapped notification's screen through the
  existing navigation — also from the background and from a closed app, after the session is
  restored. Logout unregisters the phone and invalidates its FCM token, so the next account never
  receives the previous one's notifications.
- Android channels: `child_assist_security` (high), `child_assist_location`, `child_assist_chat`,
  `child_assist_actions`, `child_assist_general`. The Automatic Location History foreground-service
  notification is unchanged.

### Setup

Client config: `android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist`
(Firebase client identifiers, not server credentials). Server credentials stay in `backend/.env`,
never in the app: set `FCM_PROJECT_ID` and either `FIREBASE_SERVICE_ACCOUNT_PATH` (key file outside
the repo) or `FCM_IMPERSONATE_SERVICE_ACCOUNT` (short-lived tokens via Application Default
Credentials; your account needs `roles/iam.serviceAccountTokenCreator` on that service account).
Without `FCM_PROJECT_ID`, notifications are still saved to the history; only the push is skipped.

Send a safe test notification to an account's phones:

```
cd backend
npm run notify:send -- --email you@example.com [--template test|app-update|review-settings] [--link location]
```

**iOS:** Push Notifications entitlement (`aps-environment`), `remote-notification` background mode
and the plist are configured. An APNs key must still be uploaded in the Firebase console, and
**iOS has not been tested on a real device.**

## Voice Assistant: "Hey Child" wake word

Opt-in hands-free voice: Settings > Voice Assistant > Wake Word. Say **"Hey Child"** (or **"Hi Child"**),
then ask the question. Tap-to-talk is unchanged and works alongside it.

### How it works

- **Detection is on the phone.** `WakeWordService.kt` (Android foreground service, type `microphone`)
  feeds 16 kHz microphone audio to an offline keyword spotter: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
  1.13.8 (Apache-2.0) with the `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01` model (Apache-2.0,
  ~6 MB in `android/app/src/main/assets/wake_word/`). No API key, account or licence fee. The AAR is
  downloaded by Gradle into `android/app/libs/` and verified against a pinned SHA-256.
- **Privacy.** Before the wake phrase, audio stays in memory on the phone and is discarded; nothing is
  recorded, stored or sent (no backend endpoint exists for it). After the phrase, the question is
  captured by the same speech recogniser as tap-to-talk and sent as text through the normal
  authenticated `POST /api/chat`. The wake phrase is stripped (`stripWakePhrase`) so the assistant only
  receives the question.
- **State machine** (`WakeWordStateMachine`): disabled, starting, listeningForWakeWord,
  wakeWordDetected, listeningForCommand, processing, speaking, paused, error. A question with no answer
  times out (15 s in Flutter, 90 s safety net in the service).
- **No self-triggering.** The microphone closes while a reply is read aloud (plus 0.7 s), during
  tap-to-talk, during calls, and while the question is captured. It reopens when no reason is left.
- **Battery.** A cheap loudness gate runs on every 100 ms; the model runs only while there is sound.
  No wake lock (Android's audio system keeps the CPU awake while recording). Tuning (threshold 0.20,
  boost 1.0) is internal (`WakeWordTuning`), measured offline: 29/30 phrases detected, 0 false
  activations on 78 similar-phrase clips (synthetic voices; real-world accuracy must be checked on a device).
- **Lock screen.** The service opens Child Assist with a full-screen notification. By default the
  user must unlock first; "Answer while locked" (off by default) shows only Chat above the lock screen
  and the lock returns 15 s after the answer.
- **Account.** Stops on logout/account switch and switches off for that account; settings are kept per
  account on the phone (`WakeWordStore`), never in the database.

### Limits (Android)

Works while the app process and its service run: app open, in the background, screen off/locked.
It does **not** work when the phone is off, after Force stop, and on some OEMs after swiping the app
away (aggressive battery savers on Xiaomi, Oppo, Vivo, Samsung, Huawei may stop it; allow background
activity). After a reboot it does not start by itself (Android 14 forbids starting a microphone
service at boot): open Child Assist once. Android 14+ may require allowing "full-screen
notifications" for opening over the lock screen. iOS is not supported.
