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
