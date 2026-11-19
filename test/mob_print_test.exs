defmodule MobPrintTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
    end

    test "passes the full pre-publish validator (paths, NIF modules, permissions)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [android, ios] = m.nifs
      assert android.module == :mob_print_nif and android.platform == :android
      assert android.lang == :zig
      assert ios.module == :mob_print_nif and ios.platform == :ios and ios.lang == :objc
    end

    test "declares the io.mob.print bridge class", %{manifest: m} do
      assert m.android.bridge_class == "io.mob.print.MobPrintBridge"
    end

    test "declares no Android permissions", %{manifest: m} do
      assert Map.get(m.android, :permissions, []) == []
    end

    test "names UIKit as the iOS framework", %{manifest: m} do
      assert "UIKit" in m.ios.frameworks
    end

    test "every native source dir + Kotlin bridge the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_print_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_print_nif.module_info(:exports)

      assert {:print_pdf, 2} in exports
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to {:error, :unsupported}, not a load crash" do
      assert :mob_print_nif.print_pdf("/tmp/example.pdf", "Example") == {:error, :unsupported}
    end
  end

  describe "MobPrint.pdf/2" do
    @tag :tmp_dir
    test "returns {:error, :not_found} when the file does not exist", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing.pdf")
      assert MobPrint.pdf(missing) == {:error, :not_found}
    end

    @tag :tmp_dir
    test "returns {:error, :unsupported} on host for a real PDF file", %{tmp_dir: dir} do
      pdf = Path.join(dir, "score.pdf")
      File.write!(pdf, "%PDF-1.4\n%%EOF\n")
      assert MobPrint.pdf(pdf) == {:error, :unsupported}
      assert MobPrint.pdf(pdf, title: "My Score") == {:error, :unsupported}
    end

    @tag :tmp_dir
    test "returns {:error, :not_found} when given a directory", %{tmp_dir: dir} do
      assert MobPrint.pdf(dir) == {:error, :not_found}
    end

    @tag :tmp_dir
    test "raises ArgumentError on unknown options", %{tmp_dir: dir} do
      pdf = Path.join(dir, "score.pdf")
      File.write!(pdf, "%PDF-1.4\n%%EOF\n")

      assert_raise ArgumentError, fn ->
        MobPrint.pdf(pdf, copies: 2)
      end
    end

    @tag :tmp_dir
    test "raises when :title is not a binary", %{tmp_dir: dir} do
      pdf = Path.join(dir, "score.pdf")
      File.write!(pdf, "%PDF-1.4\n%%EOF\n")

      assert_raise ArgumentError, fn ->
        MobPrint.pdf(pdf, title: :not_a_binary)
      end

      assert_raise ArgumentError, fn ->
        MobPrint.pdf(pdf, title: nil)
      end
    end

    test "raises when path is not a binary" do
      assert_raise ArgumentError, fn ->
        MobPrint.pdf(:not_a_path)
      end
    end
  end
end
