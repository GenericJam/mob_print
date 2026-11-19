# Changelog

All notable changes to **mob_print** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

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
