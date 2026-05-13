package com.spoofify.spoofify_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList.YouTube
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.spoofify/newpipe"
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        NewPipe.init(NewPipeDownloader.getInstance())

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAudioFile" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val cacheDir = call.argument<String>("cacheDir") ?: cacheDir.absolutePath

                    scope.launch {
                        try {
                            val filePath = fetchAndDownload(title, artist, cacheDir)
                            withContext(Dispatchers.Main) {
                                if (filePath != null) {
                                    result.success(filePath)
                                } else {
                                    result.error("NOT_FOUND", "No audio found for: $title", null)
                                }
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("ERROR", e.message ?: "Unknown error", null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun fetchAndDownload(title: String, artist: String, cacheDir: String): String? {
        val query = if (artist.isNotEmpty()) "$artist - $title lyrics" else "$title lyrics"
        Log.d("NewPipe", "Searching for: $query")

        // Try regular YouTube search first (more reliable than YouTube Music)
        val extractor = YouTube.getSearchExtractor(query)
        extractor.fetchPage()

        val items = extractor.initialPage.items
        Log.d("NewPipe", "Found ${items.size} results")
        if (items.isEmpty()) return null

        for ((index, item) in items.take(5).withIndex()) {
            try {
                val mediaLink = item.url
                Log.d("NewPipe", "Trying result $index: ${item.name} ($mediaLink)")

                // Get stream info
                val streamExtractor = YouTube.getStreamExtractor(mediaLink)
                streamExtractor.fetchPage()

                val audioStreams = streamExtractor.audioStreams
                Log.d("NewPipe", "Got ${audioStreams.size} audio streams")
                for (s in audioStreams) {
                    Log.d("NewPipe", "  stream: ${s.format?.suffix} ${s.bitrate}bps")
                }

                val bestStream = audioStreams
                    .filter { it.format?.suffix == "m4a" }
                    .maxByOrNull { it.bitrate }

                if (bestStream == null) {
                    // Try any audio format if no m4a
                    val anyStream = audioStreams.maxByOrNull { it.bitrate }
                    if (anyStream == null) {
                        Log.d("NewPipe", "No audio streams at all, trying next result")
                        continue
                    }
                    Log.d("NewPipe", "No m4a, using ${anyStream.format?.suffix} at ${anyStream.bitrate}bps")
                    return downloadStream(anyStream.content, title, anyStream.format?.suffix ?: "m4a", cacheDir)
                }

                Log.d("NewPipe", "Best m4a: ${bestStream.bitrate}bps")
                return downloadStream(bestStream.content, title, "m4a", cacheDir)
            } catch (e: Exception) {
                Log.e("NewPipe", "Failed result $index: ${e.message}")
                continue
            }
        }

        return null
    }

    private fun downloadStream(url: String, title: String, ext: String, cacheDir: String): String? {
        val safeTitle = title.replace(Regex("[^a-zA-Z0-9._-]"), "_").take(80)
        val filePath = "$cacheDir/yt_${safeTitle}.$ext"
        val file = File(filePath)

        if (file.exists() && file.length() > 0) {
            Log.d("NewPipe", "Cache hit: $filePath")
            return filePath
        }

        Log.d("NewPipe", "Downloading to: $filePath")
        val request = okhttp3.Request.Builder()
            .url(url)
            .addHeader("Range", "bytes=0-")
            .build()

        NewPipeDownloader.client.newCall(request).execute().use { response ->
            Log.d("NewPipe", "Download response: ${response.code}")
            if (!response.isSuccessful && response.code != 206) return null

            file.parentFile?.mkdirs()
            response.body.byteStream().use { input ->
                FileOutputStream(file).use { output ->
                    val buffer = ByteArray(8192)
                    var bytesRead: Int
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                    }
                }
            }
        }

        Log.d("NewPipe", "Downloaded ${file.length()} bytes")
        return if (file.exists() && file.length() > 0) filePath else null
    }
}
