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
  core/        config · theme · network (dio) · storage · router
  features/
    onboarding/  splash + intro tutorial + language
    auth/        phone → OTP → session (rider or driver)
    home/        role-aware shell + rider/driver mode switch
    ride/        where-to → estimate → confirm → live tracking (map + WS)
    driver/      go online → incoming job offer
  shared/      reusable widgets
  l10n/        app_en.arb · app_ne.arb
```
