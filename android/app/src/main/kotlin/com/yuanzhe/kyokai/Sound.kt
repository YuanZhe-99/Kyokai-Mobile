package com.yuanzhe.kyokai

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit

/**
 * The host's sound: Opus packets (48 kHz, stereo, 10 ms each, core
 * opus.rs) decoded by MediaCodec and played by an AudioTrack. One thread
 * owns both; a codec error starts the codec again. Packets that wait more
 * than 200 ms are dropped, so sound never lags the picture far.
 */
class Sound private constructor() {
    private val queue = LinkedBlockingDeque<ByteArray>()
    @Volatile private var running = true
    private val thread = Thread({ loop() }, "kyokai-sound")

    init {
        thread.start()
    }

    fun feed(buf: ByteBuffer) {
        val data = ByteArray(buf.remaining())
        buf.get(data)
        queue.offer(data)
        while (queue.size > 20) queue.poll()
    }

    private fun openCodec(): MediaCodec {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, RATE, CHANNELS)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(opusHead()))
        // Pre-skip and seek pre-roll, in nanoseconds, native order (Android's Opus decoder wants both).
        format.setByteBuffer("csd-1", ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(0, 0L))
        format.setByteBuffer("csd-2", ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(0, 80_000_000L))
        return MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS).apply {
            configure(format, null, null, 0)
            start()
        }
    }

    private fun openTrack(): AudioTrack {
        val min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(min, RATE * 4 / 10))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
            .apply { play() }
    }

    private fun loop() {
        var codec: MediaCodec? = null
        var track: AudioTrack? = null
        var pts = 0L
        val info = MediaCodec.BufferInfo()
        while (running) {
            try {
                if (codec == null) codec = openCodec()
                if (track == null) track = openTrack()
                val c = codec
                val packet = queue.poll(20, TimeUnit.MILLISECONDS)
                if (packet != null) {
                    val index = c.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val input = c.getInputBuffer(index)!!
                        input.clear()
                        input.put(packet)
                        c.queueInputBuffer(index, 0, packet.size, pts, 0)
                        pts += 10_000
                    }
                }
                while (true) {
                    val out = c.dequeueOutputBuffer(info, 0)
                    if (out < 0) break
                    val pcm = c.getOutputBuffer(out)
                    if (pcm != null && info.size > 0) {
                        pcm.position(info.offset)
                        pcm.limit(info.offset + info.size)
                        // Blocking: the track paces the thread; the queue drops what lags.
                        track.write(pcm, info.size, AudioTrack.WRITE_BLOCKING)
                    }
                    c.releaseOutputBuffer(out, false)
                }
            } catch (_: InterruptedException) {
                break
            } catch (_: Exception) {
                try { codec?.release() } catch (_: Exception) {}
                codec = null
                try { Thread.sleep(200) } catch (_: InterruptedException) { break }
            }
        }
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        try { track?.stop() } catch (_: Exception) {}
        try { track?.release() } catch (_: Exception) {}
    }

    fun close() {
        running = false
        thread.interrupt()
    }

    companion object {
        private const val RATE = 48_000
        private const val CHANNELS = 2

        /** RFC 7845 identification header: version 1, stereo, no pre-skip, 48 kHz, gain 0, family 0. */
        private fun opusHead(): ByteArray {
            val b = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            b.put("OpusHead".toByteArray(Charsets.US_ASCII))
            b.put(1)
            b.put(CHANNELS.toByte())
            b.putShort(0)
            b.putInt(RATE)
            b.putShort(0)
            b.put(0)
            return b.array()
        }

        fun open(): Sound? = try { Sound() } catch (_: Exception) { null }
    }
}
