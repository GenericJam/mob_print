defmodule MobPrint do
  @moduledoc """
  System PDF printing — a Mob plugin.

  Hands an existing PDF file on disk to the platform's native print dialog.
  The PDF is passed through byte-for-byte on both platforms; no re-rendering or
  conversion happens inside the plugin.

  ## Installation

      # mix.exs
      {:mob_print, "~> 0.1"}

      # mob.exs
      config :mob, :plugins, [:mob_print]
      config :mob, :trusted_plugins, %{mob_print: "ed25519:<fingerprint>"}

  `mix mob.plugin.trust mob_print` records the fingerprint, then
  `mix mob.deploy --native`.

  No runtime or manifest permissions are required on either platform.

  ## Usage

      # Job name defaults to the filename without extension ("invoice"):
      MobPrint.pdf("/path/to/invoice.pdf")

      # Or specify an explicit job name for the system print UI / spooler:
      MobPrint.pdf("/path/to/invoice.pdf", title: "Invoice #1042")

  `:ok` means the system print dialog was requested — **not** that the user
  confirmed printing or that the job finished. No completion message is sent
  back to the caller.

  ## Return values and errors

    * `:ok` — the platform print dialog was requested.
    * `{:error, :not_found}` — `path` does not exist, is not a regular file
      (for example, a directory), or cannot be read. Checked in Elixir before
      crossing into the NIF and re-checked on the native side.
    * `{:error, :no_activity}` — the app is not currently foregrounded, or no
      active Android `Activity` / iOS foreground window controller is available
      to present the print sheet from.
    * `{:error, :no_app}` — Android could not find a print spooler / handler
      activity (`ActivityNotFoundException`).
    * `{:error, :failed}` — the platform refused or failed to start the print
      interaction (for example, iOS `canPrintURL:` returned `NO` or the
      controller refused to present, or an unexpected native error occurred).
    * `{:error, :unsupported}` — printing is not supported in the current
      environment (host/desktop build without the native NIF linked, an
      unregistered Android bridge, missing `PRINT_SERVICE`, or iOS
      `isPrintingAvailable` returning `NO`).

  ## Scheduling and foreground requirement

  `pdf/2` runs on a **dirty IO scheduler** and blocks for up to **~2 seconds**
  while handing off to the platform UI thread to open the system print dialog.
  Always call it while the app is **foregrounded**; calling from the background
  fails with `{:error, :no_activity}`.

  ## Platform notes

  ### Android

  Uses `android.print.PrintManager.print/3` with a passthrough
  `PrintDocumentAdapter` that streams the PDF file unchanged in 16 KiB chunks
  and reports `PrintDocumentInfo.PAGE_COUNT_UNKNOWN` so the system print
  preview and spooler determine page count directly from the PDF. No
  `FileProvider` or extra manifest declaration is needed.

  ### iOS

  Uses `UIPrintInteractionController` with `printingItem` set to the PDF's
  `file://` `NSURL` and `UIPrintInfoOutputGeneral`. On iPad, the print UI is
  presented as a popover anchored at the centre of the top presented view
  controller's view; on iPhone, it is presented modally via
  `presentAnimated:completionHandler:`.
  """

  @typedoc "Error reasons returned by `pdf/2`."
  @type reason :: :not_found | :no_activity | :no_app | :failed | :unsupported

  # The Android bridge copies each string into a 4096-unit buffer.
  @max_bytes 4096

  @doc """
  Hands the PDF file at `path` to the system print dialog.

  Returns `:ok` once the platform print UI has been requested (not once the job
  has been printed; no completion message is delivered).

  ## Options

    * `:title` — job name shown in the system print dialog and spooler.
      Defaults to `Path.rootname(Path.basename(path))`. Must be a binary.

  Raises `ArgumentError` if `path` or `:title` is not a valid UTF-8 binary of
  at most #{@max_bytes} bytes (the Android bridge's limit), or if an unknown
  option is provided.
  """
  @spec pdf(String.t(), keyword()) :: :ok | {:error, reason()}
  def pdf(path, opts \\ []) do
    validate_path!(path)
    opts = Keyword.validate!(opts, [:title])
    title = resolve_title!(path, opts)
    expanded = Path.expand(path)

    if File.regular?(expanded) do
      :mob_print_nif.print_pdf(expanded, title)
    else
      {:error, :not_found}
    end
  end

  defp validate_path!(path), do: validate_text!(path, "path")

  defp validate_text!(text, what) when is_binary(text) and byte_size(text) <= @max_bytes do
    if String.valid?(text),
      do: :ok,
      else: raise(ArgumentError, "expected #{what} to be valid UTF-8, got: #{inspect(text)}")
  end

  defp validate_text!(other, what) do
    raise ArgumentError,
          "expected #{what} to be a UTF-8 binary of at most #{@max_bytes} bytes, " <>
            "got: #{inspect(other, limit: 5, printable_limit: 64)}"
  end

  defp resolve_title!(path, opts) do
    case Keyword.fetch(opts, :title) do
      :error ->
        Path.rootname(Path.basename(path))

      {:ok, title} ->
        validate_text!(title, ":title")
        title
    end
  end
end
