//! mob_print_nif — Android system PDF print plugin NIF (Zig).
//!
//! Bridges `print_pdf/2` to the plugin-owned Kotlin bridge object
//! `io.mob.print.MobPrintBridge` (`priv/native/android/MobPrintBridge.kt`),
//! which invokes `PrintManager.print/3` with a passthrough `PrintDocumentAdapter`.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
//!
//! Registration: the JVM calls
//! `Java_io_mob_print_MobPrintBridge_nativeRegister(jenv, cls)` at startup
//! (`MobPluginBootstrap.registerAll -> register()`); that thunk caches the
//! bridge jclass and `printPdf` static method ID. Until registered, calls return
//! `{:error, :unsupported}`.
//!
//! NIF (dirty IO, as the bridge waits up to ~2 s for the UI thread):
//!   print_pdf(path, title) :: :ok | {:error, reason}
//!   reason :: :not_found | :no_activity | :no_app | :failed | :unsupported
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

var g_cls: jni.JClass = null;
var g_print_pdf: jni.JMethodID = null;

// ── nativeRegister thunk — cache the bridge jclass + printPdf method ID ──
export fn Java_io_mob_print_MobPrintBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    const global = jni.newGlobalRef(jenv, cls);
    if (global == null) {
        _ = clearPendingException(jenv);
        return;
    }
    g_cls = global;
    // A missing method leaves a NoSuchMethodError pending on the JNIEnv; clear
    // it so no exception leaks onto a later BEAM-thread JNI call.
    g_print_pdf = jni.getStaticMethodID(jenv, cls, "printPdf", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (g_print_pdf == null) _ = clearPendingException(jenv);
}

inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn failed(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.errorTuple(env, erts.atom(env, "failed"));
}

// A pending Java exception must never outlive the JNI call on a BEAM thread.
// `ExceptionOccurred` is opaque in mob_zig, so give it its JNI signature here.
fn clearPendingException(jenv: *jni.JNIEnv) bool {
    const exception_occurred: *align(1) const fn (*jni.JNIEnv) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.ExceptionOccurred.?);
    const thrown = exception_occurred(jenv);
    if (thrown == null) return false;
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, thrown);
    return true;
}

// The bridge answers "" for success or a fixed error reason string. Only the
// documented error atoms are ever created — any unrecognized value collapses
// to `:failed` so Java strings can never intern arbitrary atoms.
fn reasonTerm(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, str: jni.JString) erts.ERL_NIF_TERM {
    if (str == null) return failed(env);
    defer jni.deleteLocalRef(jenv, str);
    const cstr = jni.getStringUTFChars(jenv, str) orelse return failed(env);
    defer jni.releaseStringUTFChars(jenv, str, cstr);
    const slice = std.mem.span(cstr);
    if (slice.len == 0) return erts.ok(env);
    if (std.mem.eql(u8, slice, "not_found")) return erts.errorTuple(env, erts.atom(env, "not_found"));
    if (std.mem.eql(u8, slice, "no_activity")) return erts.errorTuple(env, erts.atom(env, "no_activity"));
    if (std.mem.eql(u8, slice, "no_app")) return erts.errorTuple(env, erts.atom(env, "no_app"));
    if (std.mem.eql(u8, slice, "failed")) return failed(env);
    if (std.mem.eql(u8, slice, "unsupported")) return erts.errorTuple(env, erts.atom(env, "unsupported"));
    return failed(env);
}

// Convert a binary argument (path or title) to a new Java String; null if it
// isn't a binary, isn't valid UTF-8, exceeds the buffer, or allocation failed.
// Elixir strings are standard UTF-8, which JNI's modified-UTF-8 `NewStringUTF`
// misreads beyond the BMP (e.g. emoji in titles/paths), so text crosses as
// UTF-16 through `NewString`. `NewString` is opaque in mob_zig, so give it its
// JNI signature here.
fn argString(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, term: erts.ERL_NIF_TERM) jni.JString {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0) return null;
    // UTF-16 never needs more code units than UTF-8 has bytes.
    var units: [4096]u16 = undefined;
    if (bin.size > units.len) return null;
    const len = std.unicode.utf8ToUtf16Le(&units, bin.data[0..bin.size]) catch return null;
    const new_string: *align(1) const fn (*jni.JNIEnv, [*]const u16, jni.JSize) callconv(.c) jni.JString =
        @ptrCast(jenv.*.NewString.?);
    const str = new_string(jenv, &units, @intCast(len));
    if (str == null) _ = clearPendingException(jenv);
    return str;
}

// ── NIF ──────────────────────────────────────────────────────────────────
fn nif_print_pdf(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    if (g_cls == null or g_print_pdf == null) {
        return erts.errorTuple(env, erts.atom(env, "unsupported"));
    }

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return failed(env);
    defer detachIfAttached(attached);

    const path_str = argString(env, jenv, argv[0]);
    defer if (path_str != null) jni.deleteLocalRef(jenv, path_str);
    if (path_str == null) return erts.badarg(env);

    const title_str = argString(env, jenv, argv[1]);
    defer if (title_str != null) jni.deleteLocalRef(jenv, title_str);
    if (title_str == null) return erts.badarg(env);

    const reason = jenv.*.CallStaticObjectMethod.?(jenv, g_cls, g_print_pdf, path_str, title_str);
    if (clearPendingException(jenv)) {
        if (reason != null) jni.deleteLocalRef(jenv, reason);
        return failed(env);
    }
    return reasonTerm(env, jenv, reason);
}

// ── NIF table + init entry point ─────────────────────────────────────────
const nif_funcs = [_]erts.ErlNifFunc{
    .{
        .name = "print_pdf",
        .arity = 2,
        .fptr = nif_print_pdf,
        .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND,
    },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_print_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = null,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_print_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
