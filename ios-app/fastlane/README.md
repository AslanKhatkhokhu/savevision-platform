fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build, upload to TestFlight, distribute to the TestFlight group, and invite tester@example.com by default

### ios invite

```sh
[bundle exec] fastlane ios invite
```

Add/invite tester@example.com (or email:...) to an external TestFlight group

### ios distribute_latest

```sh
[bundle exec] fastlane ios distribute_latest
```

Distribute the latest already-uploaded TestFlight build, then invite the tester

### ios create_app

```sh
[bundle exec] fastlane ios create_app
```

Create the SaveVision App Store Connect / Developer Portal app record if it does not exist

### ios build_only

```sh
[bundle exec] fastlane ios build_only
```

Archive/export an App Store IPA without uploading

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
