# Releasing to the App Store / Play Store

Two GitHub Actions workflows push store builds:

- `.github/workflows/release-android.yml` — builds an App Bundle and uploads
  it to Google Play via Fastlane (`android/fastlane/`).
- `.github/workflows/release-ios.yml` — builds an IPA (manual signing) and
  uploads it to TestFlight via Fastlane (`ios/fastlane/`).

Both trigger on pushing a tag matching `v*` (e.g. `v1.0.0`), or manually via
**Actions → Release (…) → Run workflow**. The Android one also takes a
`track` input (`internal` / `alpha` / `beta` / `production`; defaults to
`internal`). Neither runs on every push to `main` — store submissions are
deliberate, not automatic.

Nothing here can be set up without your Apple Developer / Google Play
Console accounts — I can build the pipeline, but the credentials below only
you can generate. One-time setup:

## Google Play

1. **App record**: create the app in [Play Console](https://play.google.com/console)
   under package name `com.saarathi.app`, if not already done. Upload one
   build manually first (Play requires a human-uploaded first release before
   the API can publish to it) — `flutter build appbundle --release` locally,
   then upload the `.aab` by hand once via the Console.
2. **Service account**: Play Console → Setup → API access → create a service
   account (this takes you to Google Cloud Console) → grant it access with
   role "Release manager" (or a custom role with "Release to testing tracks"
   at minimum) back in Play Console → generate a JSON key for it.
3. **Signing keystore**: if you don't have an upload keystore yet —
   ```bash
   keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 \
     -validity 10000 -alias upload
   ```
   Keep this file and its passwords safe — losing it means you can never
   update the app under this listing again.

### Repo secrets to add (Settings → Secrets and variables → Actions)

| Secret | What it is |
| --- | --- |
| `GOOGLE_SERVICES_JSON_BASE64` | `base64 -i android/app/google-services.json \| pbcopy` (from Firebase console, already set up) |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i upload-keystore.jks \| pbcopy` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias (`upload` if you used the command above) |
| `ANDROID_KEY_PASSWORD` | key password |
| `PLAY_STORE_JSON_KEY` | the full contents of the service-account JSON key (paste as-is, it's already JSON) |
| `SAARATHI_API_BASE_PROD` | your production API gateway URL, e.g. `https://api.saarathi.app` |

## Apple / TestFlight

1. **App record**: create the app in [App Store Connect](https://appstoreconnect.apple.com)
   under bundle ID `com.saarathi.app` (register the bundle ID in the
   [Developer portal](https://developer.apple.com/account/resources/identifiers/list)
   first if it doesn't exist yet).
2. **Distribution certificate**: Developer portal → Certificates → create an
   "Apple Distribution" certificate, download it, then export it *with* its
   private key as a `.p12` from Keychain Access (set a password on export —
   that's `IOS_DIST_CERT_PASSWORD`).
3. **Provisioning profile**: Developer portal → Profiles → create an
   "App Store" distribution profile for `com.saarathi.app` using that
   certificate. Download the `.mobileprovision` file. Note the exact profile
   **name** you gave it — that's `IOS_PROVISIONING_PROFILE_SPECIFIER`.
4. **App Store Connect API key**: App Store Connect → Users and Access →
   Integrations → Keys → generate one with "App Manager" access. Download the
   `.p8` file (only downloadable once) and note its Key ID and Issuer ID.

### Repo secrets to add

| Secret | What it is |
| --- | --- |
| `GOOGLESERVICE_INFO_PLIST_BASE64` | `base64 -i ios/Runner/GoogleService-Info.plist \| pbcopy` |
| `IOS_DIST_CERT_BASE64` | `base64 -i DistributionCert.p12 \| pbcopy` |
| `IOS_DIST_CERT_PASSWORD` | the password you set exporting the `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | `base64 -i Profile.mobileprovision \| pbcopy` |
| `IOS_PROVISIONING_PROFILE_SPECIFIER` | the exact profile name from step 3 |
| `APPLE_TEAM_ID` | 10-character Team ID (Developer portal → Membership) |
| `APP_STORE_CONNECT_TEAM_ID` | numeric team ID shown in App Store Connect → Users and Access |
| `APPLE_ID` | your Apple ID email (only used by Fastlane's Appfile; the API key does the actual auth) |
| `ASC_KEY_ID` | Key ID from the App Store Connect API key |
| `ASC_ISSUER_ID` | Issuer ID from the same page |
| `ASC_KEY_CONTENT` | `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy` |
| `CI_KEYCHAIN_PASSWORD` | any random string — password for the throwaway CI keychain, not tied to anything else |
| `SAARATHI_API_BASE_PROD` | same value as the Android secret above |

## Local release builds (no CI)

Android:
```bash
cp android/key.properties.example android/key.properties   # then fill it in
flutter build appbundle --release --dart-define=SAARATHI_API_BASE=https://api.saarathi.app
```

iOS needs a full Xcode install (this repo was scaffolded without one available
on the dev machine) — open `ios/Runner.xcworkspace` in Xcode, set your team
under Signing & Capabilities, and Archive from the Product menu.
