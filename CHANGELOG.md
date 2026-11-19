# Changelog

All notable changes to **mob_print** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [0.1.0] - 2026-11-19

### Added

- Initial `mob_print` plugin with `MobPrint.pdf/2` to hand a PDF file to the
  system print dialog on both mobile platforms:
  - **Android:** `PrintManager` with a passthrough `PrintDocumentAdapter`
    (`MobPrintBridge` + `mob_print_nif.zig`) that copies the PDF unchanged,
    reports `PAGE_COUNT_UNKNOWN`, and requires no permissions or
    `FileProvider`.
  - **iOS:** `UIPrintInteractionController` (`mob_print_nif.m`) presenting the
    PDF file URL via `printingItem` (centred popover on iPad, modal sheet on
    iPhone).

### Verified

- Android, moto e 2020 (Android 10, armeabi-v7a), in Humdinger: Print opens
  the system print preview with the phrase's sheet music.
- iOS, iPhone 17 simulator (iOS 27.0) and a physical iPhone SE 3rd gen
  (iOS 27.0.1, signed development build), in a throwaway mob.new 0.6.19 host:
  `MobPrint.pdf/2` returns `:ok` and opens the print sheet with Humdinger's
  sheet-music PDF ("Page 1 of 1"); cancelling it leaves the app responsive.
