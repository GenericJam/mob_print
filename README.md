# mob_print

System PDF printing for [Mob](https://github.com/GenericJam/mob) apps — hand a
PDF file on disk to the platform's native print dialog.

- **Android:** `PrintManager.print/3` with a passthrough `PrintDocumentAdapter`
  that streams the PDF unchanged.
- **iOS:** `UIPrintInteractionController` with the PDF file URL as
  `printingItem`.

## Usage

```elixir
# Job name defaults to the filename without extension ("invoice"):
MobPrint.pdf("/path/to/invoice.pdf")

# Or set an explicit job title for the system print UI / spooler:
MobPrint.pdf("/path/to/invoice.pdf", title: "Invoice #1042")
```

`:ok` means the system print dialog was requested — not that the user tapped
Print or that pages came out of a printer. No completion message is sent.

## Options

- `:title` (`t:String.t/0`) — job name shown in the system print UI and
  spooler. Defaults to `Path.rootname(Path.basename(path))`. Raises
  `ArgumentError` if not a binary; unknown options raise `ArgumentError`.

## Return values

| Return value              | Meaning                                                                             |
|---------------------------|-------------------------------------------------------------------------------------|
| `:ok`                     | System print UI was requested. Does not mean the job finished printing.             |
| `{:error, :not_found}`    | `path` does not exist, is not a regular file, or cannot be read.                    |
| `{:error, :no_activity}`  | App is not foregrounded, or no active Activity / foreground window is available.    |
| `{:error, :no_app}`       | Android: no print spooler / handler activity could be started for the print action. |
| `{:error, :failed}`       | Platform refused to print the file (e.g. unreadable/invalid PDF or UI error).       |
| `{:error, :unsupported}`  | Printing is unavailable on this platform/device (host build, no print service, etc.). |

## Install

```elixir
# mix.exs
{:mob_print, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_print]
config :mob, :trusted_plugins, %{mob_print: "ed25519:<fingerprint>"}
```

`mix mob.plugin.trust mob_print` records the fingerprint, then
`mix mob.deploy --native`.

## Platform notes

- **Android (`PrintManager` + passthrough `PrintDocumentAdapter`):** streams
  the PDF file byte-for-byte in 16 KiB chunks to the print framework and
  declares `PrintDocumentInfo.PAGE_COUNT_UNKNOWN` so the system print preview
  and spooler inspect the PDF directly. No `FileProvider` or extra manifest
  entries are needed.
- **iOS (`UIPrintInteractionController`):** passes the PDF as a `file://`
  `NSURL` via `printingItem` (`UIPrintInfoOutputGeneral`). On iPad
  (`UIUserInterfaceIdiomPad`), presents as a popover via
  `presentFromRect:inView:animated:completionHandler:` centred on the top
  presented view controller's view; on iPhone, presents via
  `presentAnimated:completionHandler:`.
- **No permissions:** neither Android nor iOS requires any runtime or manifest
  permissions to open the system print dialog.

## Limitations

- **No completion callback:** the call returns `:ok` once the dialog has been
  requested; it does not report whether the user printed or cancelled.
- **PDF only:** passes an existing PDF file through byte-for-byte. Generate or
  render the PDF before calling `MobPrint.pdf/2`.
- **Foreground only:** must be called while the app is in the foreground (the
  call blocks a dirty IO scheduler for up to ~2 seconds while hand-off runs on
  the UI thread).

## License

MIT.
