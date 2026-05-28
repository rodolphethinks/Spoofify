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
                "searchYouTube" -> {
                    val query = call.argument<String>("query") ?: ""
                    scope.launch {
                        try {
                            val results = searchYouTube(query)
                            withContext(Dispatchers.Main) {
                                result.success(results)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("SEARCH_ERROR", e.message ?: "Search failed", null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun searchYouTube(query: String): List<Map<String, Any?>> {
        Log.d("NewPipe", "YouTube search: $query")
        val extractor = YouTube.getSearchExtractor(query)
        extractor.fetchPage()

        val items = extractor.initialPage.items
        Log.d("NewPipe", "Search got ${items.size} results")

        return items.take(15).mapNotNull { item ->
            try {
                val name = item.name ?: return@mapNotNull null
                val url = item.url ?: return@mapNotNull null
                // Extract uploader (artist) from the item
                val uploader = try {
                    val field = item.javaClass.getMethod("getUploaderName")
                    field.invoke(item) as? String ?: ""
                } catch (_: Exception) { "" }
                val thumbnail = try {
                    val thumbs = item.thumbnails
                    if (thumbs.isNotEmpty()) thumbs[0].url else null
                } catch (_: Exception) { null }
                val duration = try {
                    val field = item.javaClass.getMethod("getDuration")
                    (field.invoke(item) as? Long) ?: -1L
                } catch (_: Exception) { -1L }
                mapOf(
                    "title" to name,
                    "artist" to uploader,
                    "url" to url,
                    "thumbnail" to thumbnail,
                    "duration" to duration
                )
            } catch (e: Exception) {
                Log.w("NewPipe", "Skip search item: ${e.message}")
                null
            }
        }
    }

    private fun fetchAndDownload(title: String, artist: String, cacheDir: String): String? {
        val query = if (artist.isNotEmpty()) "$artist - $title lyrics" else "$title lyrics"
        Log.d("NewPipe", "Searching for: $query")

        val extractor = YouTube.getSearchExtractor(query)
        extractor.fetchPage()

        val items = extractor.initialPage.items
        Log.d("NewPipe", "Found ${items.size} results")
        if (items.isEmpty()) throw Exception("YouTube search returned no results for: $query")

        val errors = mutableListOf<String>()

        for ((index, item) in items.take(5).withIndex()) {
            try {
                val mediaLink = item.url
                Log.d("NewPipe", "Trying result $index: ${item.name} ($mediaLink)")

                val streamExtractor = YouTube.getStreamExtractor(mediaLink)
                streamExtractor.fetchPage()

                val audioStreams = streamExtractor.audioStreams
                Log.d("NewPipe", "Got ${audioStreams.size} audio streams")
                if (audioStreams.isEmpty()) {
                    errors.add("#$index: no audio streams")
                    continue
                }

                for (s in audioStreams) {
                    Log.d("NewPipe", "  stream: ${s.format?.suffix} ${s.bitrate}bps")
                }

                // Prefer m4a, then any format
                val stream = audioStreams
                    .filter { it.format?.suffix == "m4a" }
                    .maxByOrNull { it.bitrate }
                    ?: audioStreams.maxByOrNull { it.bitrate }

                if (stream == null) {
                    errors.add("#$index: could not select stream")
                    continue
                }

                val ext = stream.format?.suffix ?: "m4a"
                Log.d("NewPipe", "Using $ext at ${stream.bitrate}bps")
                val result = downloadStream(stream.content, title, ext, cacheDir)
                if (result != null) return result
                errors.add("#$index: download failed")
            } catch (e: Exception) {
                Log.e("NewPipe", "Failed result $index: ${e.message}")
                errors.add("#$index: ${e.message?.take(80)}")
                continue
            }
        }

        throw Exception("All attempts failed: ${errors.joinToString("; ")}")
    }

    private fun downloadStream(url: String, title: String, ext: String, cacheDir: String): String? {
        val safeTitle = title.replace(Regex("[^a-zA-Z0-9._-]"), "_").take(80)
        val filePath = "$cacheDir/yt_${safeTitle}.$ext"
        val file = File(filePath)

        if (file.exists() && file.length() > 0) {
            Log.d("NewPipe", "Cache hit: $filePath")
            return filePath
        }

        Log.d("NewPipe", "Downloading to: $filePath (url length=${url.length})")
        val request = okhttp3.Request.Builder()
            .url(url)
            .addHeader("User-Agent", NewPipeDownloader.USER_AGENT)
            .addHeader("Accept", "*/*")
            .addHeader("Accept-Language", "en-US,en;q=0.9")
            .addHeader("Referer", "https://www.youtube.com/")
            .addHeader("Origin", "https://www.youtube.com")
            .build()

        NewPipeDownloader.client.newCall(request).execute().use { response ->
            Log.d("NewPipe", "Download response: ${response.code} (${response.body.contentLength()} bytes)")
            if (!response.isSuccessful) {
                Log.e("NewPipe", "Download failed: HTTP ${response.code}")
                return null
            }

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
