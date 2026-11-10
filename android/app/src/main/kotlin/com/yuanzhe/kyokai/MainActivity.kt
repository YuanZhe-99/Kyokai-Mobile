package com.yuanzhe.kyokai

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The app's native side: what the Kyokai core leaves to the system on
 * Android (doc/en-us/architecture.md). Video and sound decode through
 * MediaCodec ([Video], [Sound]); the secrets store's key lives under the
 * Android Keystore ([MasterKey]).
 */
class MainActivity : FlutterActivity() {
    private val videos = HashMap<Long, Video>()
    private var sound: Sound? = null
    private lateinit var events: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        events = MethodChannel(messenger, "kyokai/events")
        flutterEngine.platformViewsController.registry
            .registerViewFactory("kyokai/video-view", VideoViewFactory(videos))
        MethodChannel(messenger, "kyokai/native").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "masterKey" -> result.success(MasterKey.get(this))
                    "decoders" -> result.success(Video.decodable())
                    "videoOpen" -> {
                        val video = Video.open(
                            flutterEngine.renderer,
                            call.argument<String>("codec")!!,
                            call.argument<Int>("width")!!,
                            call.argument<Int>("height")!!,
                            call.argument<Boolean>("view") == true,
                            { id -> runOnUiThread { events.invokeMethod("keyFrame", id) } },
                            { text -> runOnUiThread { events.invokeMethod("log", text) } },
                        )
                        if (video == null) {
                            result.success(null)
                        } else {
                            videos[video.id] = video
                            result.success(
                                mapOf("texture" to video.id, "decoder" to video.name, "hardware" to video.hardware, "view" to (call.argument<Boolean>("view") == true))
                            )
                        }
                    }
                    "videoInfo" -> result.success(videos[call.argument<Number>("texture")!!.toLong()]?.info())
                    "videoClose" -> {
                        videos.remove(call.argument<Number>("texture")!!.toLong())?.close()
                        result.success(null)
                    }
                    "sound" -> {
                        val on = call.argument<Boolean>("on")!!
                        sound?.close()
                        sound = if (on) Sound.open() else null
                        result.success(sound != null)
                    }
                    "keepOn" -> {
                        if (call.argument<Boolean>("on")!!) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    "sessions" -> {
                        val text = call.argument<String>("text")
                        if (text != null && android.os.Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                            android.content.pm.PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
                        }
                        SessionService.update(this, text)
                        result.success(null)
                    }
                    "device" -> result.success(
                        mapOf(
                            "android" to android.os.Build.VERSION.RELEASE,
                            "sdk" to android.os.Build.VERSION.SDK_INT,
                            "model" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                            "abis" to android.os.Build.SUPPORTED_ABIS.joinToString(","),
                            "files" to filesDir.absolutePath,
                            "nativeLibs" to applicationInfo.nativeLibraryDir,
                        )
                    )
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native", e.message, null)
            }
        }
        // A frame: the texture (i64), flags (u8, bit 0 key frame), the
        // presentation time in µs (u64), then the frame, big-endian as the
        // core's packets. The reply is one byte: 1 when the decoder failed
        // and wants a key frame.
        BasicMessageChannel(messenger, "kyokai/video", BinaryCodec.INSTANCE_DIRECT).setMessageHandler { msg, reply ->
            val ok = msg?.let { buf ->
                buf.order(ByteOrder.BIG_ENDIAN)
                val id = buf.getLong(0)
                val key = buf.get(8).toInt() and 1 == 1
                val pts = buf.getLong(9)
                buf.position(17)
                videos[id]?.feed(buf.slice(), key, pts)
            } ?: false
            reply.reply(ByteBuffer.allocateDirect(1).put(0, if (ok) 0 else 1))
        }
        // One Opus packet of the host's sound.
        BasicMessageChannel(messenger, "kyokai/sound", BinaryCodec.INSTANCE_DIRECT).setMessageHandler { msg, reply ->
            msg?.let { sound?.feed(it) }
            reply.reply(null)
        }
    }

    override fun onDestroy() {
        videos.values.forEach { it.close() }
        videos.clear()
        sound?.close()
        super.onDestroy()
    }
}
