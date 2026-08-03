# Saarathi app

One Flutter app, two modes (**Rider** / **Driver**) for the Saarathi rides + delivery
super app. Nepal-first: offline-tolerant, cash-first, OSM/Valhalla maps (no Google),
English + नेपाली. Talks to the backend API gateway (Traefik, `:8080`).

## Stack

- Flutter (stable) + Material 3 (dynamic color, dark mode)
- Riverpod (state) · go_router (nav + deep links `saarathi://`)
- flutter_map on our self-hosted OSM tiles · geolocator
- dio (gateway API) · flutter_secure_storage (JWT) · web_socket_channel (trip WS)
- gen-l10n localization (`en`, `ne`)

## First-time setup

This repo ships `lib/`, `pubspec.yaml`, and config. The native runner folders
(`android/`, `ios/`, `web/`) are generated locally so they are not committed:

```bash
cd app
# Generate platform folders without touching lib/ or pubspec.yaml
flutter create --org com.saarathi --project-name saarathi \
  --platforms=android,ios,web .
flutter pub get
```

## Run

```bash
# Point the app at your backend gateway (defaults to http://10.0.2.2:8080 on
# Android emulator, http://localhost:8080 elsewhere). Override per-run:
flutter run --dart-define=SAARATHI_API_BASE=http://localhost:8080

# or via the repo Makefile
make app            # flutter run
make app-get        # flutter pub get
make app-build      # release APK
```

Dev login: the backend seeds OTP dev-mode, so the OTP is returned in the API
response and shown on the verify screen (no SMS gateway needed).

## Structure

```
lib/src/
  core/        config · theme · network (dio) · storage · router · location
  features/
    onboarding/  splash + intro tutorial + language
    auth/        phone → OTP → session · profile edit
    home/        role-aware shell · rider/driver mode · trip history
    ride/        where-to → estimate → confirm → live tracking · rating · SOS
    driver/      KYC register + document upload · go online → offers → progress
    delivery/    send a parcel (trackable delivery trip)
  shared/      reusable widgets
  l10n/        app_en.arb · app_ne.arb
```

## Native config (add after `flutter create`)

The generated runners need these to actually run:

- **Android** (`android/app/src/main/AndroidManifest.xml` + `build.gradle`):
  permissions `INTERNET`, `ACCESS_FINE_LOCATION`, `CAMERA`, `RECORD_AUDIO`,
  `POST_NOTIFICATIONS`; `minSdkVersion 21+` (flutter_webrtc); for dev against a
  plaintext gateway add `android:usesCleartextTraffic="true"`; a deep-link
  `<intent-filter>` for scheme `saarathi`.
- **iOS** (`ios/Runner/Info.plist`): `NSLocationWhenInUseUsageDescription`,
  `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
  `NSPhotoLibraryUsageDescription`; a `CFBundleURLTypes` entry for scheme
  `saarathi`; for localhost dev, an `NSAppTransportSecurity` exception.
- **WebRTC**: point at Coturn via
  `--dart-define=SAARATHI_TURN_URL=…` (or the app fetches ephemeral creds from
  the backend `/v1/rtc/ice`, which are minted from the Coturn `TURN_SECRET`).
- **Push (FCM)**: run `flutterfire configure` to generate
  `firebase_options.dart` + `google-services.json` / `GoogleService-Info.plist`,
  then push works end-to-end (`PushService` is already wired and registers the
  device token via `POST /v1/me/push-token`). Until then push is auto-disabled.

## Not yet built (next passes)

Merchant catalogue backend (food/grocery ordering) · trip-share deep link ·
notify-service FCM sender · saved-place management screen.
