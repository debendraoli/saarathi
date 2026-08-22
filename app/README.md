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

`android/` and `ios/` are committed (Android and iOS only — no macOS/web).
Firebase config (`google-services.json` / `GoogleService-Info.plist`) is
gitignored since it's a real project key; see "Push (FCM)" below.

```bash
cd app
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

## Native config

Already set up in the committed `android/`/`ios/` runners — permissions,
the flutter_foreground_task service declaration, the `saarathi://` deep-link
intent-filter/URL type, and (iOS) the `NS*UsageDescription` keys.

- **WebRTC**: point at Coturn via
  `--dart-define=SAARATHI_TURN_URL=…` (or the app fetches ephemeral creds from
  the backend `/v1/rtc/ice`, which are minted from the Coturn `TURN_SECRET`).
- **Push (FCM)**: drop `google-services.json` at `android/app/` and
  `GoogleService-Info.plist` at `ios/Runner/` (both gitignored — get them
  from the Firebase console for project `saarathi-e6596`, app IDs
  `com.saarathi.app` on both platforms). `PushService` is already wired and
  registers the device token via `POST /v1/me/push-token`; push is
  auto-disabled until the config file is present.
- **App store releases**: see [RELEASE.md](RELEASE.md) for the CI pipeline
  and one-time Apple/Google setup.

## Not yet built (next passes)

Nothing tracked here right now — this list had drifted stale (merchant
catalogue backend, trip-share deep link, notify FCM sender, and saved-place
management were all already done or just finished). Check `git log` / the
phase brief for what's actually next.
