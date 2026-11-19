// mob_print plugin — Android bridge (system PDF print dialog via PrintManager).
//
// Invoked from priv/native/jni/mob_print_nif.zig on a dirty IO scheduler thread.
// Hands an existing PDF file on disk to Android's PrintManager using a
// passthrough PrintDocumentAdapter that copies the PDF unchanged in 16 KiB
// chunks. No permissions or FileProvider are required.
//
// Return contract: "" once the system print UI has been requested, or one of
// the closed error strings that the Zig NIF maps to {:error, reason}:
//   "not_found", "no_activity", "no_app", "failed", "unsupported".
//
// MobPluginBootstrap.registerAll(this) calls register() at startup and hands
// off the foreground Activity via MobActivityAware.setActivity().
package io.mob.print

import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

object MobPrintBridge : io.mob.plugin.MobActivityAware {
    @JvmStatic external fun nativeRegister()

    private const val TAG = "MobPrint"

    // How long the dirty-IO caller waits for the main-thread print hand-off
    // before treating a successfully posted request as accepted.
    private const val UI_WAIT_MS = 2000L

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var activityRef: WeakReference<Activity>? = null

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    // MobActivityAware: called from MainActivity.onCreate on the main thread.
    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun printPdf(path: String, title: String): String {
        val file = File(path)
        if (!file.isFile || !file.canRead()) return "not_found"

        val jobName = title.ifBlank { file.name }
        val documentName = pdfDocumentName(jobName, file.name)

        return onUi { activity ->
            val printManager = activity.getSystemService(Context.PRINT_SERVICE) as? PrintManager
                ?: return@onUi "unsupported"
            printManager.print(jobName, PdfAdapter(file, documentName), PrintAttributes.Builder().build())
            ""
        }
    }

    // Ensure the PrintDocumentInfo name ends with ".pdf" so Android's "Save as
    // PDF" destination suggests a proper PDF filename.
    private fun pdfDocumentName(jobName: String, fallbackFileName: String): String {
        val raw = jobName.ifBlank { fallbackFileName }.replace('/', '_').trim()
        val base = raw.ifEmpty { "document" }
        return if (base.endsWith(".pdf", ignoreCase = true)) base else "$base.pdf"
    }

    // True only while the app process is in the foreground. Activity.isFinishing
    // / isDestroyed stay false for a backgrounded Activity, so check process
    // importance as well.
    private fun isForegroundProcess(): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        return state.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    // Runs block on the UI thread with the current Activity and waits up to
    // UI_WAIT_MS for its outcome. If the runnable was posted to the main looper
    // and the latch times out, returns "" because the print UI request is
    // already queued for execution on the main thread.
    private fun onUi(block: (Activity) -> String): String {
        val activity = activityRef?.get()
        if (activity == null || activity.isFinishing || activity.isDestroyed || !isForegroundProcess()) {
            return "no_activity"
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            return runSafely(activity, block)
        }

        val result = AtomicReference("")
        val done = CountDownLatch(1)
        val posted = main.post {
            try {
                if (activity.isFinishing || activity.isDestroyed || !isForegroundProcess()) {
                    result.set("no_activity")
                } else {
                    result.set(runSafely(activity, block))
                }
            } finally {
                done.countDown()
            }
        }
        if (!posted) return "failed"

        return try {
            if (done.await(UI_WAIT_MS, TimeUnit.MILLISECONDS)) {
                result.get()
            } else {
                // Request was successfully posted to the main looper; treat
                // "asked for" as success rather than returning a spurious error
                // if the UI thread is momentarily busy.
                ""
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            "failed"
        }
    }

    private fun runSafely(activity: Activity, block: (Activity) -> String): String {
        return try {
            block(activity)
        } catch (_: ActivityNotFoundException) {
            "no_app"
        } catch (e: Exception) {
            Log.w(TAG, "print failed", e)
            "failed"
        }
    }

    // Streams an existing PDF file byte-for-byte to Android's print framework.
    private class PdfAdapter(
        private val file: File,
        private val documentName: String,
    ) : PrintDocumentAdapter() {
        override fun onLayout(
            oldAttributes: PrintAttributes?,
            newAttributes: PrintAttributes,
            cancellationSignal: CancellationSignal,
            callback: LayoutResultCallback,
            extras: Bundle?,
        ) {
            if (cancellationSignal.isCanceled) {
                callback.onLayoutCancelled()
                return
            }
            val info = PrintDocumentInfo.Builder(documentName)
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN)
                .build()
            // The PDF bytes are fixed, so only the initial layout changes content.
            callback.onLayoutFinished(info, oldAttributes == null)
        }

        override fun onWrite(
            pages: Array<out PageRange>,
            destination: ParcelFileDescriptor,
            cancellationSignal: CancellationSignal,
            callback: WriteResultCallback,
        ) {
            if (cancellationSignal.isCanceled) {
                callback.onWriteCancelled()
                return
            }

            // Complete all stream I/O (including close) before invoking the
            // callback so exactly one callback method runs per onWrite call.
            val canceled = try {
                var wasCanceled = false
                FileInputStream(file).use { input ->
                    FileOutputStream(destination.fileDescriptor).use { output ->
                        val buf = ByteArray(16 * 1024)
                        while (true) {
                            if (cancellationSignal.isCanceled) {
                                wasCanceled = true
                                break
                            }
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                        }
                        if (!wasCanceled) {
                            output.flush()
                        }
                    }
                }
                wasCanceled
            } catch (e: IOException) {
                Log.w(TAG, "print write failed", e)
                callback.onWriteFailed(e.message)
                return
            } catch (e: Exception) {
                Log.w(TAG, "print write failed", e)
                callback.onWriteFailed(e.message)
                return
            }

            if (canceled) {
                callback.onWriteCancelled()
            } else {
                callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            }
        }
    }
}
