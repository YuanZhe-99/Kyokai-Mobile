package com.yuanzhe.kyokai

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * The page's picture as an Android SurfaceView (`kyokai/video-view`): the
 * decoder of [Video] whose id the page passes draws straight into it, with
 * no copy through Flutter's renderer. Touches stay with Flutter, which lays
 * its own layers (cursor, buttons, overlays) over it.
 */
class VideoViewFactory(private val videos: Map<Long, Video>) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val id = ((args as? Map<*, *>)?.get("video") as? Number)?.toLong()
        return VideoView(context) { id?.let { videos[it] } }
    }
}

private class VideoView(context: Context, private val video: () -> Video?) : PlatformView {
    private val view = SurfaceView(context).apply {
        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                video()?.attach(holder.surface)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                video()?.detach(holder.surface)
            }
        })
    }

    override fun getView(): View = view

    override fun dispose() {}
}
