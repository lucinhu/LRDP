package dev.lrdp.lrdp

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.CancellationSignal
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Image bytes stay in our private cache; the clipboard grants access to one URI. */
class ClipboardImageBridge(private val context: Context, messenger: BinaryMessenger,
                           private val isForeground: () -> Boolean) {
    private val channel = MethodChannel(messenger, "dev.lrdp/clipboard_image")
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val clipboard get() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private var closed = false
    @Volatile private var readCancellation: CancellationSignal? = null
    private val limit = 16 * 1024 * 1024
    private val prepared = linkedMapOf<String, Pair<android.net.Uri, File>>()

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "read" -> {
                        val clip = clipboard.primaryClip
                        val uri = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).uri else null
                        if (uri == null || uri.scheme != "content" ||
                            context.contentResolver.getType(uri)?.startsWith("image/") != true) {
                            result.success(null)
                        } else {
                            val cancellation = CancellationSignal()
                            readCancellation = cancellation
                            executor.execute {
                                try {
                                    val bytes = context.contentResolver.openTypedAssetFileDescriptor(uri, "image/*", null, cancellation)?.use { descriptor ->
                                      require(descriptor.length <= limit) { "Image exceeds 16 MiB" }
                                      descriptor.createInputStream().use { input ->
                                        val output = ByteArrayOutputStream()
                                        val buffer = ByteArray(16384)
                                        while (true) {
                                            val count = input.read(buffer)
                                            if (count < 0) break
                                            require(output.size().toLong() + count <= limit) { "Image exceeds 16 MiB" }
                                            output.write(buffer, 0, count)
                                        }
                                        output.toByteArray()
                                      }
                                    }
                                    main.post { if (!closed) result.success(bytes?.let { mapOf("kind" to 1, "bytes" to it) }) }
                                } catch (_: Exception) {
                                    main.post { if (!closed) result.error("clipboard-unavailable", "Cannot read image", null) }
                                } finally {
                                    if (readCancellation === cancellation) readCancellation = null
                                }
                            }
                        }
                    }
                    "write" -> {
                        val png = call.argument<ByteArray>("png")
                        require(png != null && png.isNotEmpty() && png.size <= limit) { "Invalid image size" }
                        executor.execute {
                            try {
                                val folder = File(context.cacheDir, "clipboard-images").apply { mkdirs() }
                                // Preserve the current URI while bounding retained private cache files.
                                folder.listFiles()?.sortedByDescending { it.lastModified() }?.drop(7)?.forEach { it.delete() }
                                val token = UUID.randomUUID().toString()
                                val file = File(folder, "$token.png")
                                file.outputStream().use { it.write(png) }
                                val uri = FileProvider.getUriForFile(context, "${context.packageName}.clipboard_provider", file)
                                main.post {
                                    if (!closed) {
                                        while (prepared.size >= 8) prepared.remove(prepared.keys.first())
                                        prepared[token] = Pair(uri, file)
                                        result.success(mapOf("token" to token))
                                    }
                                }
                            } catch (_: Exception) {
                                main.post { if (!closed) result.error("clipboard-unavailable", "Cannot store image", null) }
                            }
                        }
                    }
                    "publish", "discard" -> {
                        val token = call.argument<String>("token")
                        val image = if (token == null) null else prepared.remove(token)
                        if (call.method == "discard") {
                            if (image != null) executor.execute { image.second.delete() }
                            result.success(null)
                        } else if (image == null || !isForeground()) {
                            result.error("clipboard-unavailable", "Image publication cancelled", null)
                        } else {
                            clipboard.setPrimaryClip(ClipData.newUri(context.contentResolver, "LRDP image", image.first))
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: RuntimeException) {
                result.error("clipboard-unavailable", "Cannot access image clipboard", null)
            }
        }
    }

    fun close() {
        closed = true
        readCancellation?.cancel()
        prepared.clear()
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }
}

class ClipboardImageProvider : FileProvider()
