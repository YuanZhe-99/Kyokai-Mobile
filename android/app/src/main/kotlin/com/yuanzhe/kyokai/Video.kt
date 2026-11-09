package com.yuanzhe.kyokai

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit

/**
 * One remote screen's decoder: H.264 or HEVC in Annex B, as Kyokai hosts
 * send it (core annexb.rs), with the parameter sets in every key frame,
 * decoded by MediaCodec straight into a Flutter texture.
 *
 * One thread owns the codec: it takes frames from a queue, feeds the codec
 * and renders its output, so no codec call ever runs inside a codec
 * callback. The first key frame after a (re)start goes in two buffers, its
 * parameter sets flagged as codec config, then the picture.
 */
class Video private constructor(
    private val producer: TextureRegistry.SurfaceProducer,
    private val mime: String,
    private val codecName: String,
    private val width: Int,
    private val height: Int,
    private val wantKey: (Long) -> Unit,
) {
    val id: Long = producer.id()
    val name: String = codecName
    val hardware: Boolean = hardwareOf(codecName)

    private class Frame(val data: ByteArray, val key: Boolean, val pts: Long)

    private val queue = LinkedBlockingDeque<Frame>()
    @Volatile private var running = true
    @Volatile private var surfaceReady = true
    @Volatile private var restart = false

    /** A key frame is needed before anything decodes (start, error, overflow). */
    @Volatile private var needKey = true

    private val thread = Thread({ loop() }, "kyokai-video-$id")

    init {
        producer.setSize(width, height)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                surfaceReady = true
                restart = true
                wantKey(id)
            }

            override fun onSurfaceCleanup() {
                surfaceReady = false
                restart = true
            }
        })
        thread.start()
    }

    /**
     * Queues one frame. Returns false when the decoder wants a key frame
     * (it failed, or frames piled up), which Dart asks the host for.
     */
    fun feed(buf: ByteBuffer, key: Boolean, pts: Long): Boolean {
        if (!surfaceReady) return true // Asked for again when the surface returns.
        if (needKey && !key) return false
        val data = ByteArray(buf.remaining())
        buf.get(data)
        if (key) {
            // A key frame starts a group: what waits before it is stale.
            queue.clear()
        } else if (queue.size > 8) {
            queue.clear()
            needKey = true
            return false
        }
        queue.offer(Frame(data, key, pts))
        return true
    }

    private fun loop() {
        var codec: MediaCodec? = null
        var configured = false
        val info = MediaCodec.BufferInfo()
        while (running) {
            try {
                if (restart || (codec == null && surfaceReady)) {
                    restart = false
                    codec?.let { stopQuietly(it) }
                    codec = null
                    configured = false
                    needKey = true
                    if (surfaceReady) {
                        codec = MediaCodec.createByCodecName(codecName).also {
                            val format = MediaFormat.createVideoFormat(mime, width, height)
                            // Room for a key frame with its parameter sets at a high bitrate.
                            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height * 3 / 2, 4 shl 20))
                            if (Build.VERSION.SDK_INT >= 30) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
                            it.configure(format, producer.surface, null, 0)
                            it.start()
                        }
                    }
                }
                val c = codec
                if (c == null) {
                    queue.poll(50, TimeUnit.MILLISECONDS)
                    continue
                }
                val frame = queue.poll(5, TimeUnit.MILLISECONDS)
                if (frame != null && !(needKey && !frame.key)) {
                    if (frame.key && !configured) {
                        val (config, rest) = splitParameterSets(frame.data, mime == MIME_HEVC)
                        if (config.isNotEmpty()) queueInput(c, config, frame.pts, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
                        queueInput(c, rest, frame.pts, 0)
                        configured = true
                    } else {
                        queueInput(c, frame.data, frame.pts, 0)
                    }
                    needKey = false
                }
                // Render everything decoded, newest last.
                while (true) {
                    val out = c.dequeueOutputBuffer(info, 0)
                    if (out >= 0) {
                        c.releaseOutputBuffer(out, true)
                    } else {
                        break
                    }
                }
            } catch (e: Exception) {
                // A codec error: start again from the next key frame.
                codec?.let { stopQuietly(it) }
                codec = null
                configured = false
                needKey = true
                queue.clear()
                if (running && surfaceReady) wantKey(id)
                try { Thread.sleep(200) } catch (_: InterruptedException) {}
            }
        }
        codec?.let { stopQuietly(it) }
    }

    private fun queueInput(c: MediaCodec, data: ByteArray, pts: Long, flags: Int) {
        val index = c.dequeueInputBuffer(100_000)
        if (index < 0) throw IllegalStateException("no input buffer")
        val input = c.getInputBuffer(index) ?: throw IllegalStateException("no input buffer")
        if (data.size > input.capacity()) throw IllegalStateException("frame larger than the input buffer")
        input.clear()
        input.put(data)
        c.queueInputBuffer(index, 0, data.size, pts, flags)
    }

    fun close() {
        running = false
        thread.interrupt()
        try { thread.join(500) } catch (_: InterruptedException) {}
        producer.release()
    }

    companion object {
        private const val MIME_H264 = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val MIME_HEVC = MediaFormat.MIMETYPE_VIDEO_HEVC

        private fun stopQuietly(c: MediaCodec) {
            try { c.stop() } catch (_: Exception) {}
            try { c.release() } catch (_: Exception) {}
        }

        /**
         * Splits an Annex B key frame into its leading parameter sets (H.264
         * SPS/PPS, NAL types 7 and 8; HEVC VPS/SPS/PPS, 32–34) and the rest.
         */
        fun splitParameterSets(data: ByteArray, hevc: Boolean): Pair<ByteArray, ByteArray> {
            var i = 0
            var end = 0
            while (true) {
                val start = startCode(data, i) ?: break
                val nal = start.second
                if (nal >= data.size) break
                val type = if (hevc) (data[nal].toInt() shr 1) and 0x3F else data[nal].toInt() and 0x1F
                val isParam = if (hevc) type in 32..34 else type == 7 || type == 8
                if (!isParam) {
                    end = start.first
                    break
                }
                i = nal
                end = data.size
            }
            if (end == 0 || end == data.size) return Pair(ByteArray(0), data)
            return Pair(data.copyOfRange(0, end), data.copyOfRange(end, data.size))
        }

        /** The next start code at or after [from]: its offset and where its NAL begins. */
        private fun startCode(d: ByteArray, from: Int): Pair<Int, Int>? {
            var i = from
            while (i + 3 <= d.size) {
                if (d[i].toInt() == 0 && d[i + 1].toInt() == 0) {
                    if (d[i + 2].toInt() == 1) return Pair(i, i + 3)
                    if (i + 4 <= d.size && d[i + 2].toInt() == 0 && d[i + 3].toInt() == 1) return Pair(i, i + 4)
                }
                i++
            }
            return null
        }

        private fun hardwareOf(name: String): Boolean {
            val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { it.name == name }
                ?: return false
            return if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated else !name.startsWith("OMX.google.") && !name.startsWith("c2.android.")
        }

        private fun mimeOf(codec: String): String? = when (codec) {
            "h264" -> MIME_H264
            "hevc" -> MIME_HEVC
            else -> null
        }

        /** Decoders for a type, hardware first, skipping secure ones and those too small for the size. */
        private fun decodersFor(mime: String, width: Int, height: Int): List<MediaCodecInfo> =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && !it.name.endsWith(".secure") && it.supportedTypes.any { t -> t.equals(mime, true) } }
                .filter {
                    if (width <= 0 || height <= 0) return@filter true
                    val caps = it.getCapabilitiesForType(mime).videoCapabilities
                    caps == null || caps.isSizeSupported(width, height) || caps.isSizeSupported(height, width)
                }
                .sortedBy { if (hardwareOf(it.name)) 0 else 1 }

        /**
         * What this device decodes, for the core's `android.decoders`: H.264
         * and HEVC (4:2:0), hardware first, with the largest size each takes.
         */
        fun decodable(): List<Map<String, Any>> = listOf("hevc", "h264").mapNotNull { codec ->
            val mime = mimeOf(codec)!!
            val best = decodersFor(mime, 0, 0).firstOrNull() ?: return@mapNotNull null
            val caps = best.getCapabilitiesForType(mime).videoCapabilities
            mapOf(
                "codec" to codec,
                "name" to best.name,
                "hardware" to hardwareOf(best.name),
                "max_width" to (caps?.supportedWidths?.upper ?: 0),
                "max_height" to (caps?.supportedHeights?.upper ?: 0),
            )
        }

        fun open(
            renderer: TextureRegistry,
            codec: String,
            width: Int,
            height: Int,
            wantKey: (Long) -> Unit,
        ): Video? {
            val mime = mimeOf(codec) ?: return null
            val info = decodersFor(mime, width, height).firstOrNull() ?: return null
            // Check the decoder opens before handing out a texture.
            try {
                MediaCodec.createByCodecName(info.name).release()
            } catch (_: Exception) {
                return null
            }
            val producer = renderer.createSurfaceProducer()
            return Video(producer, mime, info.name, width, height, wantKey)
        }
    }
}
