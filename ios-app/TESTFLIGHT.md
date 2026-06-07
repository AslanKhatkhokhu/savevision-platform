# TestFlight deployment

SaveVision has fastlane lanes for App Store Connect/TestFlight.

## Auth

Recommended: create an App Store Connect API key with App Manager access and set either:

```bash
export APP_STORE_CONNECT_API_KEY_PATH=/path/to/fastlane-api-key.json
```

or:

```bash
export APP_STORE_CONNECT_API_KEY_KEY_ID=XXXXXXXXXX
export APP_STORE_CONNECT_API_KEY_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export APP_STORE_CONNECT_API_KEY_KEY_FILEPATH=/path/to/AuthKey_XXXXXXXXXX.p8
```

Apple ID auth can work locally, but may require 2FA and team selection. Uploading an IPA with Apple ID auth also requires an app-specific password:

```bash
export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
# Xcode 26/altool may also require the provider public ID for accounts with multiple providers:
export PILOT_PROVIDER_PUBLIC_ID=<provider-public-id>
```

## App Store Connect team

This Apple ID has multiple App Store Connect teams. Set the correct team before running lanes:

```bash
export FASTLANE_ITC_TEAM_ID=127811797 # example: TAO Social LLC
```

Fastlane listed these local options:

- `434093` — Martin Wieser
- `1214143` — Stephan Mairhofer
- `127811797` — TAO Social LLC
- `352538` — TouristMobile GmbH

## Create app record if needed

If App Store Connect does not yet have an app for `io.example.savevision`:

```bash
cd ios-app
bundle exec fastlane ios create_app
```

## Deploy and invite the requested tester

Default tester: `tester@example.com`.
Default external group: `External Testers`.

```bash
cd ios-app
bundle exec fastlane ios beta
```

Override group/email if needed:

```bash
TESTFLIGHT_GROUP="SaveVision Beta" bundle exec fastlane ios beta email:tester@example.com
```

## Invite without uploading a new build

```bash
cd ios-app
bundle exec fastlane ios invite email:tester@example.com group:"External Testers"
```

## Distribute an already-uploaded build and invite

```bash
cd ios-app
bundle exec fastlane ios distribute_latest email:tester@example.com group:"External Testers"
```

Notes:
- External TestFlight testers require an external testing group in App Store Connect.
- The first externally distributed build may require Apple's Beta App Review before the tester can install it.
- Xcode automatic signing is used; the Apple account/team must be allowed to create App Store provisioning profiles.
