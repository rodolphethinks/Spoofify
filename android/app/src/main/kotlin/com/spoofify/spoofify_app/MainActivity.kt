package com.spoofify.spoofify_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList.YouTube
import org.json.JSONObject
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
                "getAudioFileByUrl" -> {
                    val url = call.argument<String>("url") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val cacheDir = call.argument<String>("cacheDir") ?: cacheDir.absolutePath

                    scope.launch {
                        try {
                            val filePath = fetchByVideoUrl(url, title, cacheDir)
                            withContext(Dispatchers.Main) {
                                if (filePath != null) {
                                    result.success(filePath)
                                } else {
                                    result.error("NOT_FOUND", "No audio from: $url", null)
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

    /**
     * Fetch audio directly from a YouTube URL (no search needed).
     * Uses Piped API only — no YouTube network calls.
     */
    private fun fetchByVideoUrl(url: String, title: String, cacheDir: String): String? {
        val videoId = extractVideoId(url)
            ?: throw Exception("Invalid YouTube URL: $url")

        Log.d("NewPipe", "fetchByVideoUrl: videoId=$videoId title=$title")

        // Try Piped API first
        val streamUrl = getAudioStreamFromPiped(videoId)
        if (streamUrl != null) {
            val result = downloadStream(streamUrl, title, "m4a", cacheDir)
            if (result != null) return result
        }

        // Fallback: Invidious API
        val invStreamUrl = getAudioStreamFromInvidious(videoId)
        if (invStreamUrl != null) {
            val result = downloadStream(invStreamUrl, title, "m4a", cacheDir)
            if (result != null) return result
        }

        throw Exception("No audio stream found for: $videoId (all Piped+Invidious instances failed)")
    }

    private val PIPED_INSTANCES = listOf(
        "https://pipedapi.kavin.rocks",
        "https://pipedapi.adminforge.de",
        "https://pipedapi.in.projectsegfau.lt",
        "https://api.piped.privacydev.net",
        "https://pipedapi.darkness.services"
    )

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

                // Extract video ID from URL
                val videoId = extractVideoId(mediaLink)
                if (videoId == null) {
                    errors.add("#$index: can't extract video ID from $mediaLink")
                    continue
                }

                // Try Piped API instances for stream extraction
                val streamUrl = getAudioStreamFromPiped(videoId)
                if (streamUrl != null) {
                    Log.d("NewPipe", "Got Piped stream URL for $videoId")
                    val result = downloadStream(streamUrl, title, "m4a", cacheDir)
                    if (result != null) return result
                    errors.add("#$index: Piped download failed")
                }

                // Try Invidious API
                val invStreamUrl = getAudioStreamFromInvidious(videoId)
                if (invStreamUrl != null) {
                    Log.d("NewPipe", "Got Invidious stream URL for $videoId")
                    val result = downloadStream(invStreamUrl, title, "m4a", cacheDir)
                    if (result != null) return result
                    errors.add("#$index: Invidious download failed")
                }

                // Fallback: try NewPipe direct extraction
                val streamExtractor = YouTube.getStreamExtractor(mediaLink)
                streamExtractor.fetchPage()
                val audioStreams = streamExtractor.audioStreams
                Log.d("NewPipe", "NewPipe fallback: ${audioStreams.size} audio streams")

                if (audioStreams.isNotEmpty()) {
                    val stream = audioStreams
                        .filter { it.format?.suffix == "m4a" }
                        .maxByOrNull { it.bitrate }
                        ?: audioStreams.maxByOrNull { it.bitrate }

                    if (stream != null) {
                        val ext = stream.format?.suffix ?: "m4a"
                        val result = downloadStream(stream.content, title, ext, cacheDir)
                        if (result != null) return result
                    }
                }
                errors.add("#$index: no audio streams from any source")
            } catch (e: Exception) {
                Log.e("NewPipe", "Failed result $index: ${e.message}")
                errors.add("#$index: ${e.message?.take(100)}")
                continue
            }
        }

        throw Exception("All attempts failed: ${errors.joinToString("; ")}")
    }

    private fun extractVideoId(url: String): String? {
        // Handle: youtube.com/watch?v=ID, youtu.be/ID, youtube.com/shorts/ID
        val patterns = listOf(
            Regex("""[?&]v=([a-zA-Z0-9_-]{11})"""),
            Regex("""youtu\.be/([a-zA-Z0-9_-]{11})"""),
            Regex("""youtube\.com/shorts/([a-zA-Z0-9_-]{11})"""),
            Regex("""youtube\.com/embed/([a-zA-Z0-9_-]{11})""")
        )
        for (pattern in patterns) {
            val match = pattern.find(url)
            if (match != null) return match.groupValues[1]
        }
        return null
    }

    private fun getAudioStreamFromPiped(videoId: String): String? {
        for (instance in PIPED_INSTANCES) {
            try {
                val apiUrl = "$instance/streams/$videoId"
                Log.d("NewPipe", "Trying Piped: $apiUrl")

                val request = okhttp3.Request.Builder()
                    .url(apiUrl)
                    .addHeader("User-Agent", NewPipeDownloader.USER_AGENT)
                    .addHeader("Accept", "application/json")
                    .build()

                val response = NewPipeDownloader.client.newCall(request).execute()
                val result = try {
                    if (!response.isSuccessful) {
                        Log.w("NewPipe", "Piped $instance returned ${response.code}")
                        null
                    } else {
                        parsePipedAudioStream(response.body.string(), instance)
                    }
                } finally {
                    response.close()
                }

                if (result != null) return result
            } catch (e: Exception) {
                Log.w("NewPipe", "Piped $instance failed: ${e.message}")
                continue
            }
        }
        return null
    }

    private fun parsePipedAudioStream(body: String, instance: String): String? {
        val json = JSONObject(body)
        val audioStreams = json.optJSONArray("audioStreams")
        if (audioStreams == null || audioStreams.length() == 0) {
            Log.w("NewPipe", "Piped $instance: no audioStreams in response")
            return null
        }

        // Find best audio stream (prefer m4a/mp4, highest bitrate)
        var bestUrl: String? = null
        var bestBitrate = 0
        var fallbackUrl: String? = null
        var fallbackBitrate = 0

        for (i in 0 until audioStreams.length()) {
            val stream = audioStreams.getJSONObject(i)
            val url = stream.optString("url", "")
            val bitrate = stream.optInt("bitrate", 0)
            val mimeType = stream.optString("mimeType", "")

            if (url.isEmpty()) continue

            val isM4a = mimeType.contains("mp4") || mimeType.contains("m4a")

            if (isM4a && bitrate > bestBitrate) {
                bestUrl = url
                bestBitrate = bitrate
            } else if (bitrate > fallbackBitrate) {
                fallbackUrl = url
                fallbackBitrate = bitrate
            }
        }

        val selectedUrl = bestUrl ?: fallbackUrl
        if (selectedUrl != null) {
            Log.d("NewPipe", "Piped $instance: got stream at ${bestBitrate.coerceAtLeast(fallbackBitrate)}bps")
        }
        return selectedUrl
    }

    private val INVIDIOUS_INSTANCES = listOf(
        "https://inv.nadeko.net",
        "https://invidious.nerdvpn.de",
        "https://invidious.privacyredirect.com"
    )

    private fun getAudioStreamFromInvidious(videoId: String): String? {
        for (instance in INVIDIOUS_INSTANCES) {
            try {
                val apiUrl = "$instance/api/v1/videos/$videoId"
                Log.d("NewPipe", "Trying Invidious: $apiUrl")

                val request = okhttp3.Request.Builder()
                    .url(apiUrl)
                    .addHeader("User-Agent", NewPipeDownloader.USER_AGENT)
                    .addHeader("Accept", "application/json")
                    .build()

                val response = NewPipeDownloader.client.newCall(request).execute()
                val result = try {
                    if (!response.isSuccessful) {
                        Log.w("NewPipe", "Invidious $instance returned ${response.code}")
                        null
                    } else {
                        parseInvidiousAudioStream(response.body.string(), instance)
                    }
                } finally {
                    response.close()
                }

                if (result != null) return result
            } catch (e: Exception) {
                Log.w("NewPipe", "Invidious $instance failed: ${e.message}")
                continue
            }
        }
        return null
    }

    private fun parseInvidiousAudioStream(body: String, instance: String): String? {
        val json = JSONObject(body)
        val adaptiveFormats = json.optJSONArray("adaptiveFormats")
        if (adaptiveFormats == null || adaptiveFormats.length() == 0) {
            Log.w("NewPipe", "Invidious $instance: no adaptiveFormats")
            return null
        }

        var bestUrl: String? = null
        var bestBitrate = 0

        for (i in 0 until adaptiveFormats.length()) {
            val format = adaptiveFormats.getJSONObject(i)
            val type = format.optString("type", "")
            // Only audio formats
            if (!type.startsWith("audio/")) continue
            val url = format.optString("url", "")
            val bitrate = format.optInt("bitrate", 0)
            if (url.isEmpty()) continue

            if (bitrate > bestBitrate) {
                bestUrl = url
                bestBitrate = bitrate
            }
        }

        if (bestUrl != null) {
            Log.d("NewPipe", "Invidious $instance: got audio at ${bestBitrate}bps")
        }
        return bestUrl
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
