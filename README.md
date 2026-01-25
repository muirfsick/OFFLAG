# OffLag

OffLag is a Flutter client app for the OffLag VPN service. It includes user onboarding,
server selection, and billing flows, and builds Xray/Sing-box configs for the tunnel.

## Features
- Email-based onboarding and profile management
- Server list with latency/ping indicators
- Balance, promo codes, and top-up flows
- Desktop window sizing and theming

## Tech Stack
- Flutter (Dart)
- dio, flutter_secure_storage, shared_preferences
- Xray and Sing-box config builders

## Getting Started
```bash
flutter pub get
flutter run
```

## Notes
- Desktop window size is fixed to 460x800.
- App name and bundle IDs are set to OffLag.