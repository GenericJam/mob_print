# AGENTS.md — orientation for AI agents working on mob_print

You're in **mob_print**, a Mob capability plugin: hand a PDF file on disk to the
system print dialog. Android uses `PrintManager` with a passthrough
`PrintDocumentAdapter`; iOS uses `UIPrintInteractionController` with the PDF's
`file://` URL. Public API is `MobPrint.pdf/2`.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view
and the cross-cutting pre-empt-failure rules. This file is mob_print-specific.

> **Keep this file current.** When you change print behaviour, native marshalling,
> or hit a gotcha that would trip the next agent, fix it here in the same commit
> — not in a follow-up.

## What mob_print is, in one paragraph

Thin cross-platform wrapper around the OS print sheet for an already-written PDF
file. `MobPrint.pdf/2` validates inputs and file presence in Elixir, expands the
path, and calls `:mob_print_nif.print_pdf/2` on a dirty IO scheduler. On Android
the Zig NIF marshals `path` and `title` over JNI as UTF-16 strings to
`io.mob.print.MobPrintBridge.printPdf/2`, which posts `PrintManager.print/3`
with a streaming 16 KiB passthrough `PrintDocumentAdapter` to the UI thread. On
iOS the Objective-C NIF checks `isPrintingAvailable` / `canPrintURL:` and
presents `UIPrintInteractionController` on the main thread (centred popover on
iPad, sheet on iPhone). Neither platform needs permissions or `host_requirements`.

## What mob_print is NOT

* **Not a PDF renderer or HTML-to-PDF converter.** The file at `path` must
  already be a PDF; both platforms pass its bytes through untouched.
* **Not a share sheet.** For `ACTION_SEND` / `UIActivityViewController` file
  sharing, use a dedicated share plugin — printing goes straight to the OS
  print spooler and does not need Android `FileProvider`.
* **Not a print-job status tracker.** `:ok` means the system print UI was
  requested, not that the user confirmed printing or that paper came out. There
  is deliberately no completion message or job-state stream.

## Anatomy of the plugin

* `lib/mob_print.ex` — public `MobPrint.pdf/2`, input/option validation, file
  pre-check, `Path.expand/1`, and full docs/typespecs.
* `src/mob_print_nif.erl` — Erlang NIF stub (tolerant `on_load`; host fallback
  returns `{error, unsupported}`, not `nif_error`).
* `priv/mob_plugin.exs` — tier-1 manifest declaring the cross-platform
  `:mob_print_nif` (`:zig` for Android, `:objc` for iOS), `MobPrintBridge`, and
  iOS `UIKit` framework. No permissions, no `host_requirements`.
* `priv/native/jni/mob_print_nif.zig` — Android Zig NIF (`ERL_NIF_DIRTY_JOB_IO_BOUND`),
  `Java_io_mob_print_MobPrintBridge_nativeRegister`, UTF-16 `NewString`
  marshalling, JNI exception clearing, and a closed allowlist of error atoms.
* `priv/native/android/MobPrintBridge.kt` — `io.mob.print.MobPrintBridge`
  (`MobActivityAware`), UI-thread hand-off with 2 s latch wait, and passthrough
  `PdfAdapter` (`PrintDocumentAdapter`).
* `priv/native/ios/mob_print_nif.m` — ARC Objective-C NIF
  (`ERL_NIF_DIRTY_JOB_IO_BOUND`), foreground-active scene / top VC lookup,
  main-thread dispatch with 2 s semaphore wait (inline if already main), and
  `UIPrintInteractionController` presentation (iPad popover + iPhone sheet).
* `test/mob_print_test.exs` — manifest validation, NIF stub agreement, and host
  `MobPrint.pdf/2` behaviour tests.

## Load-bearing invariants

1. **`:ok` means the print dialog was requested, not printed.** Never promise
   completion or send unsolicited completion messages back to the caller pid.
2. **Closed error-atom set.** `reasonTerm` in `mob_print_nif.zig` MUST only map
   `"not_found"`, `"no_activity"`, `"no_app"`, `"failed"`, and `"unsupported"`;
   anything unexpected collapses to `:failed`. Never intern arbitrary strings
   into the BEAM atom table.
3. **Byte-for-byte PDF passthrough.** Android's `PdfAdapter` copies the file in
   16 KiB chunks, reports `PAGE_COUNT_UNKNOWN`, honours `CancellationSignal`,
   and invokes **exactly one** callback per `onLayout` / `onWrite` call. iOS
   passes the file URL via `printingItem`.
4. **Dirty IO + bounded UI wait (~2 s).** Both native NIFs run with
   `ERL_NIF_DIRTY_JOB_IO_BOUND` so waiting for the UI thread never stalls a
   normal BEAM scheduler. Both must be called while foregrounded; backgrounded
   calls return `{:error, :no_activity}`.
5. **UTF-16 JNI marshalling and exception hygiene.** Non-BMP characters (e.g.
   emoji in titles or paths) break JNI's modified-UTF-8 `NewStringUTF`, so
   `mob_print_nif.zig` converts UTF-8 to UTF-16 and uses `NewString`. Every JNI
   call that can throw clears pending exceptions before returning to the BEAM.
6. **Android boot registration.** `MobPrintBridge` implements `MobActivityAware`
   and relies on the host's `MainActivity` calling
   `MobPluginBootstrap.registerAll(this)`. An unregistered bridge returns
   `{:error, :unsupported}` rather than crashing with a null method ID.

## Cross-repo work

**mob (framework):** `MobActivityAware` and `MobPluginBootstrap.registerAll(this)`
live in mob core. If that boot-registration contract changes, `MobPrintBridge`
must move in lockstep.

**mob_dev:** plugin manifest validation (`MobDev.Plugin.Manifest` / `Validator`)
and the native build rules for `:zig` + `:objc` NIFs live in `mob_dev`. Changes
to how `priv/mob_plugin.exs` declares `nifs`, `android`, or `ios` affect this
plugin.

## Testing

Host Elixir suite:

```bash
mix test
```

Covers manifest validation, NIF stub exports/fallback, and host-side argument
and file checks for `MobPrint.pdf/2`.

Native code isn't exercised by `mix test` — smoke-test on real devices via a
host app:

```bash
mix mob.deploy --native --device <serial>
```

Then write a real PDF to the app's cache/files directory and call
`MobPrint.pdf(path, title: "Smoke Test 📄")`:

* **Android:** system print preview opens with the PDF rendered, "Save as PDF"
  suggests a `.pdf` filename matching the title, cancelling returns cleanly to
  the app, and calling while backgrounded returns `{:error, :no_activity}`.
* **iOS (iPhone + iPad):** AirPrint sheet (or centred popover on iPad) opens
  with the PDF preview and job name, cancelling dismisses cleanly, and calling
  while backgrounded returns `{:error, :no_activity}`.

## Pre-commit + release

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin   # from a host app
```

`mix.exs` version bump on master triggers `.github/workflows/release.yml` (tag +
GitHub Release + Hex publish). Sign the manifest against the shared mob key at
`~/.mob/keys/` first. Do NOT bump versions without explicit permission. See
`~/code/mob/RELEASE.md`.
