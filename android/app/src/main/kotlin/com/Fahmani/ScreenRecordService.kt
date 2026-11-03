package com.Fahmani

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * تسجيل شاشة التطبيق (فيديو فقط) إلى ملف mp4 على الجهاز عبر MediaProjection.
 * الصوت يُسجَّل منفصلًا عبر Agora (startAudioRecording) ثم يُدمج في MainActivity.mux.
 */
class ScreenRecordService : Service() {
    companion object {
        @Volatile var instance: ScreenRecordService? = null
        @Volatile var lastError: String? = null
        /** يُستدعى عند توقف التسجيل لأي سبب (لإعادة حجب الشاشة). */
        @Volatile var onStopped: (() -> Unit)? = null
        const val CHANNEL_ID = "fahmt_screen_record"
        const val NOTIF_ID = 4711
        const val EXTRA_RESULT_CODE = "rc"
        const val EXTRA_DATA = "data"
        const val EXTRA_PATH = "path"
    }

    private var projection: MediaProjection? = null
    private var recorder: MediaRecorder? = null
    private var display: VirtualDisplay? = null
    @Volatile var recording = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastError = null
        try {
            startAsForeground()
            val rc = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
            @Suppress("DEPRECATION")
            val data: Intent? = intent?.getParcelableExtra(EXTRA_DATA)
            val path = intent?.getStringExtra(EXTRA_PATH)
            if (data == null || path == null) throw IllegalStateException("بيانات التسجيل ناقصة")

            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val proj = mgr.getMediaProjection(rc, data) ?: throw IllegalStateException("تعذر بدء MediaProjection")
            projection = proj
            // Android 14: يجب تسجيل callback قبل إنشاء VirtualDisplay
            proj.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() { stopRecording() }
            }, Handler(Looper.getMainLooper()))

            val dm = resources.displayMetrics
            var w = dm.widthPixels
            var h = dm.heightPixels
            val scale = minOf(1.0, 720.0 / minOf(w, h).toDouble())
            w = ((w * scale).toInt()) and 1.inv()
            h = ((h * scale).toInt()) and 1.inv()

            val rec = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
            rec.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            rec.setVideoSize(w, h)
            rec.setVideoFrameRate(15)
            rec.setVideoEncodingBitRate(1_500_000)
            rec.setOutputFile(path)
            rec.prepare()
            recorder = rec

            display = proj.createVirtualDisplay("fahmt_rec", w, h, dm.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, rec.surface, null, null)
            rec.start()
            recording = true
            instance = this
        } catch (e: Exception) {
            lastError = e.message ?: e.toString()
            cleanup()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "تسجيل الجلسة", NotificationManager.IMPORTANCE_LOW))
        }
        val n: Notification = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else @Suppress("DEPRECATION") Notification.Builder(this))
            .setContentTitle("جاري تسجيل الجلسة")
            .setContentText("يتم تسجيل الجلسة لحفظها ومراجعتها عند الحاجة")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(NOTIF_ID, n)
    }

    /** يوقف التسجيل ويحفظ الملف. يرجع true لو انتهى بملف صالح. */
    @Synchronized
    fun stopRecording(): Boolean {
        if (!recording) { cleanup(); return false }
        recording = false
        var ok = true
        try { recorder?.stop() } catch (e: Exception) { ok = false; lastError = "stop: ${e.message}" }
        cleanup()
        try { stopForeground(true) } catch (_: Exception) {}
        stopSelf()
        return ok
    }

    private fun cleanup() {
        try { recorder?.release() } catch (_: Exception) {}
        try { display?.release() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        recorder = null; display = null; projection = null
        if (instance === this) instance = null
        try { onStopped?.invoke() } catch (_: Exception) {}
    }

    override fun onDestroy() {
        if (recording) { recording = false; try { recorder?.stop() } catch (_: Exception) {} }
        cleanup()
        super.onDestroy()
    }
}
