package com.Fahmani

import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import java.io.File
import java.nio.ByteBuffer
import android.view.WindowManager
import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Build
import android.app.Application
import com.google.firebase.FirebaseApp
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "masar_app/screen_protection"
    private val firebaseChannelName = "masar_app/firebase"
    private val audioProtectionChannelName = "masar_app/audio_protection"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // تم إلغاء حماية الشاشة: لقطات الشاشة وتسجيل الشاشة مسموحان (لا FLAG_SECURE ولا منع لالتقاط الصوت).
        disableScreenProtection()
        blockAudioCapture() // الاسم قديم: صار يسمح بالتقاط الصوت
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensurePlugins(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            firebaseChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureInitialized" -> {
                    try {
                        result.success(ensureNativeFirebase())
                    } catch (e: Exception) {
                        result.error("FIREBASE_NATIVE_INIT", e.message, null)
                    }
                }
                "diagnostics" -> result.success(pluginReport)
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioProtectionChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "disableMicrophoneCapture", "blockAudioCapture" -> result.success(blockAudioCapture())
                else -> result.notImplemented()
            }
        }

        // تسجيل شاشة الجلسة على الجهاز ثم دمج الصوت ورفع الملف (من Dart)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fahmt/screen_record").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> startScreenRecord(call.argument<String>("path") ?: "", result)
                "stop" -> {
                    val svc = ScreenRecordService.instance
                    result.success(svc?.stopRecording() ?: false)
                }
                "isRecording" -> result.success(ScreenRecordService.instance?.recording == true)
                "mux" -> {
                    val v = call.argument<String>("video") ?: ""
                    val a = call.argument<String>("audio")
                    val o = call.argument<String>("out") ?: ""
                    Thread {
                        val ok = try { muxAudioVideo(v, a, o) } catch (e: Exception) { false }
                        Handler(Looper.getMainLooper()).post { result.success(ok) }
                    }.start()
                }
                "lastError" -> result.success(ScreenRecordService.lastError)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    // الحماية ملغاة: لا نضع FLAG_SECURE
                    disableScreenProtection()
                    result.success(true)
                }

                "disable" -> {
                    disableScreenProtection()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }


    @Volatile
    private var pluginReport: String = "not-run"

    /**
     * Guarantees that the FlutterFire plugins are attached to this engine.
     * The automatic registration can silently fail (it only logs), which makes
     * every plugin channel fail with "channel-error". Registration is
     * idempotent (already-registered plugins are skipped), so it is safe to
     * repeat here. Reflection is used so this can never break compilation, and
     * the outcome is reported to Dart to make any remaining failure visible.
     */
    @Suppress("UNCHECKED_CAST")
    private fun ensurePlugins(engine: FlutterEngine) {
        val notes = StringBuilder()

        try {
            Class.forName("io.flutter.plugins.GeneratedPluginRegistrant")
                .getMethod("registerWith", FlutterEngine::class.java)
                .invoke(null, engine)
            notes.append("registrant=ok; ")
        } catch (t: Throwable) {
            val cause = t.cause ?: t
            notes.append("registrant=${cause.javaClass.simpleName}:${cause.message}; ")
        }

        try {
            val cls = Class.forName("io.flutter.plugins.firebase.core.FlutterFirebaseCorePlugin")
                as Class<out io.flutter.embedding.engine.plugins.FlutterPlugin>
            notes.append(
                if (engine.plugins.has(cls)) "firebase_core=registered; "
                else "firebase_core=missing; "
            )
            repairFirebaseCore(engine, cls, notes)
        } catch (t: Throwable) {
            notes.append("firebase_core=${describe(t)}; ")
        }

        pluginReport = notes.toString()
    }

    private fun describe(t: Throwable): String {
        val c = t.cause ?: t
        return "${c.javaClass.simpleName}:${c.message}@${c.stackTrace.firstOrNull()}"
    }

    /**
     * A plugin is stored in the engine's registry BEFORE its onAttachedToEngine
     * runs, so "registered" does not prove that its Pigeon channel handlers were
     * installed (an exception during attach is only logged). Re-attach the
     * plugin, capture any exception, and install the Pigeon handlers directly.
     */
    @Suppress("UNCHECKED_CAST")
    private fun repairFirebaseCore(
        engine: FlutterEngine,
        cls: Class<out io.flutter.embedding.engine.plugins.FlutterPlugin>,
        notes: StringBuilder,
    ) {
        try {
            engine.plugins.remove(cls)
            notes.append("core-detached; ")
        } catch (t: Throwable) {
            notes.append("core-detach=${describe(t)}; ")
        }
        try {
            engine.plugins.add(cls.getDeclaredConstructor().newInstance())
            notes.append("core-attached; ")
        } catch (t: Throwable) {
            notes.append("core-attach=${describe(t)}; ")
        }

        val plugin = engine.plugins.get(cls)
        for (api in listOf("FirebaseCoreHostApi", "FirebaseAppHostApi")) {
            try {
                val apiCls = Class.forName(
                    "io.flutter.plugins.firebase.core.GeneratedAndroidFirebaseCore\$$api"
                )
                val setUp = apiCls.declaredMethods.first {
                    it.name == "setUp" && it.parameterTypes.size == 2
                }
                setUp.invoke(null, engine.dartExecutor.binaryMessenger, plugin)
                notes.append("$api.setUp=ok; ")
            } catch (t: Throwable) {
                notes.append("$api.setUp=${describe(t)}; ")
            }
        }
    }

    /**
     * Ensure the Android Firebase default app exists.
     * google-services.json + FirebaseInitProvider normally initialize it before
     * the Flutter engine; the explicit check also makes startup deterministic.
     */
    private fun ensureNativeFirebase(): Boolean {
        return FirebaseApp.getApps(this).any {
            it.name == FirebaseApp.DEFAULT_APP_NAME
        }
    }

    /**
     * Blocks recording of the app's own audio by other apps / system screen
     * recorders (Android 10+). Combined with allowAudioPlaybackCapture="false"
     * in the manifest. It cannot stop a physical microphone recording speakers.
     */
    private fun blockAudioCapture(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                am.setAllowedCapturePolicy(AudioAttributes.ALLOW_CAPTURE_BY_ALL)
            }
            true
        } catch (_: Throwable) { false }
    }

    private fun enableScreenProtection() {
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    private fun disableScreenProtection() {
        window.clearFlags(
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }

    // ===== تسجيل الشاشة =====
    private var pendingRecordResult: MethodChannel.Result? = null
    private var pendingRecordPath: String = ""
    private val recordRequestCode = 7711

    private fun startScreenRecord(path: String, result: MethodChannel.Result) {
        if (path.isEmpty()) { result.success(false); return }
        if (ScreenRecordService.instance?.recording == true) { result.success(true); return }
        pendingRecordResult = result
        pendingRecordPath = path
        try {
            File(path).parentFile?.mkdirs()
            val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            @Suppress("DEPRECATION")
            startActivityForResult(mgr.createScreenCaptureIntent(), recordRequestCode)
        } catch (e: Exception) {
            pendingRecordResult = null
            result.success(false)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != recordRequestCode) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val res = pendingRecordResult
        pendingRecordResult = null
        if (res == null) return
        if (resultCode != RESULT_OK || data == null) { res.success(false); return }
        try {
            val i = Intent(this, ScreenRecordService::class.java)
                .putExtra(ScreenRecordService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(ScreenRecordService.EXTRA_DATA, data)
                .putExtra(ScreenRecordService.EXTRA_PATH, pendingRecordPath)
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
        } catch (e: Exception) { res.success(false); return }
        // ننتظر حتى 4 ثوانٍ ليبدأ التسجيل فعليًا
        val h = Handler(Looper.getMainLooper())
        var tries = 0
        val check = object : Runnable {
            override fun run() {
                tries++
                if (ScreenRecordService.instance?.recording == true) res.success(true)
                else if (ScreenRecordService.lastError != null || tries > 20) res.success(false)
                else h.postDelayed(this, 200)
            }
        }
        h.postDelayed(check, 200)
    }

    /** يدمج مسار الصوت (aac) مع فيديو الشاشة في mp4 واحد. لو فشل الصوت يُنتج الفيديو وحده. */
    private fun muxAudioVideo(videoPath: String, audioPath: String?, outPath: String): Boolean {
        val outFile = File(outPath)
        if (outFile.exists()) outFile.delete()
        val withAudio = audioPath != null && File(audioPath).let { it.exists() && it.length() > 2048 }
        if (withAudio) {
            try { if (doMux(videoPath, audioPath, outPath)) return true } catch (_: Exception) {}
            if (outFile.exists()) outFile.delete()
        }
        return try { doMux(videoPath, null, outPath) } catch (_: Exception) { false }
    }

    private fun doMux(videoPath: String, audioPath: String?, outPath: String): Boolean {
        val muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val vEx = MediaExtractor()
        var aEx: MediaExtractor? = null
        try {
            vEx.setDataSource(videoPath)
            var vIdx = -1
            for (i in 0 until vEx.trackCount) { if (vEx.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) { vIdx = i; break } }
            if (vIdx < 0) return false
            vEx.selectTrack(vIdx)
            val vOut = muxer.addTrack(vEx.getTrackFormat(vIdx))

            var aOut = -1
            if (audioPath != null) {
                val ex = MediaExtractor()
                ex.setDataSource(audioPath)
                var aIdx = -1
                for (i in 0 until ex.trackCount) { if (ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) { aIdx = i; break } }
                if (aIdx >= 0) { ex.selectTrack(aIdx); aOut = muxer.addTrack(ex.getTrackFormat(aIdx)); aEx = ex } else ex.release()
            }
            muxer.start()
            val buf = ByteBuffer.allocate(1024 * 1024)
            val info = MediaCodec.BufferInfo()
            fun copy(ex: MediaExtractor, track: Int) {
                while (true) {
                    buf.clear()
                    val size = ex.readSampleData(buf, 0)
                    if (size < 0) break
                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = ex.sampleTime
                    info.flags = if ((ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                    muxer.writeSampleData(track, buf, info)
                    ex.advance()
                }
            }
            copy(vEx, vOut)
            if (aEx != null && aOut >= 0) copy(aEx!!, aOut)
            muxer.stop()
            return File(outPath).length() > 1024
        } finally {
            try { vEx.release() } catch (_: Exception) {}
            try { aEx?.release() } catch (_: Exception) {}
            try { muxer.release() } catch (_: Exception) {}
        }
    }
}
