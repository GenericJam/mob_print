%{
  name: :mob_print,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description:
    "System PDF printing — UIPrintInteractionController on iOS, PrintManager on Android",
  nifs: [
    # Android: zig NIF bridging to io.mob.print.MobPrintBridge (PrintManager +
    # passthrough PrintDocumentAdapter). platform: :android so the iOS build
    # skips it.
    %{module: :mob_print_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android},
    # iOS: Objective-C NIF presenting UIPrintInteractionController with the PDF
    # file URL. lang: :objc (-fobjc-arc); platform: :ios so the Android build
    # skips it. Both share src/mob_print_nif.erl.
    %{module: :mob_print_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}
  ],
  android: %{
    # Implements MobActivityAware — needs the foreground Activity to reach
    # PrintManager and anchor the system print UI. No permissions or
    # FileProvider required.
    bridge_kt: "priv/native/android/MobPrintBridge.kt",
    bridge_class: "io.mob.print.MobPrintBridge"
  },
  ios: %{
    # UIPrintInteractionController lives in UIKit. UIKit is already in the
    # host's base framework set (mob_dev Validator @ios_base_frameworks) and is
    # declared here only to document the dependency.
    frameworks: ["UIKit"]
  }
}
