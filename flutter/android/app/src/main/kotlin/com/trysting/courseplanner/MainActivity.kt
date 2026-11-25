package com.trysting.courseplanner

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the lightweight speech bridge used by the Flutter voice button.
 *
 * Channel `course_planner/speech`:
 *  * `listen`     -> String?  recognised text (null when nothing was heard)
 *  * `recordOnce` -> String?  absolute path of a temporary m4a (max 30 s)
 *  * `cancel`     -> null     stops / detaches any pending listen or recording
 *  * `isAvailable`-> Boolean  a speech recognizer and the intent resolve
 *
 * Only the platform APIs are used: no third-party Gradle dependency, so the
 * Windows/Android build is unaffected.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL_NAME = "course_planner/speech"
        const val SPEECH_REQUEST_CODE = 4301
        const val AUDIO_PERMISSION_REQUEST_CODE = 4302
        const val MAX_RECORD_MS = 30_000L
    }

    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingRecordResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private var recorder: MediaRecorder? = null
    private var recordFile: File? = null

    private val handler = Handler(Looper.getMainLooper())
    private val stopRecordingRunnable = Runnable { completeRecording() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listen" -> startListening(result)
                    "recordOnce" -> startRecording(result)
                    "cancel" -> {
                        cancelAll()
                        result.success(null)
                    }
                    "isAvailable" -> result.success(isSpeechAvailable())
                    else -> result.notImplemented()
                }
            }
    }

    // ---- System speech recognition ----------------------------------------

    private fun isSpeechAvailable(): Boolean {
        // MediaRecorder itself exists on every Android version (API 1+), so
        // only the recognizer service and its intent need checking.
        if (!SpeechRecognizer.isRecognitionAvailable(this)) return false
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        return intent.resolveActivity(packageManager) != null
    }

    private fun startListening(result: MethodChannel.Result) {
        if (!isSpeechAvailable()) {
            result.error("unavailable", "当前设备没有可用的系统语音识别服务", null)
            return
        }
        if (pendingSpeechResult != null) {
            result.error("busy", "语音识别正在进行中，请稍候", null)
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
            putExtra(RecognizerIntent.EXTRA_PROMPT, "请说话…")
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        pendingSpeechResult = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, SPEECH_REQUEST_CODE)
        } catch (e: Exception) {
            pendingSpeechResult = null
            result.error("listen_failed", e.message ?: "无法启动系统语音识别", null)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SPEECH_REQUEST_CODE) return
        val result = pendingSpeechResult ?: return
        pendingSpeechResult = null
        if (resultCode == Activity.RESULT_OK) {
            val text = data
                ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                ?.firstOrNull()
            result.success(text)
        } else {
            // Back / no match: a null transcription, not an error dialog.
            result.success(null)
        }
    }

    // ---- Recording for the cloud ASR endpoint -----------------------------

    private fun startRecording(result: MethodChannel.Result) {
        if (pendingRecordResult != null) {
            result.error("record_failed", "录音已在进行中", null)
            return
        }
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingPermissionResult != null) {
                result.error("record_failed", "正在申请麦克风权限", null)
                return
            }
            pendingPermissionResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                AUDIO_PERMISSION_REQUEST_CODE,
            )
            return
        }
        beginRecording(result)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != AUDIO_PERMISSION_REQUEST_CODE) return
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            beginRecording(result)
        } else {
            result.error("permission_denied", "未授予麦克风权限，无法录音", null)
        }
    }

    private fun beginRecording(result: MethodChannel.Result) {
        // A cancel may have arrived while the permission dialog was open.
        if (pendingRecordResult != null) {
            result.error("record_failed", "录音已在进行中", null)
            return
        }
        var mediaRecorder: MediaRecorder? = null
        var file: File? = null
        try {
            file = File(cacheDir, "voice_${System.currentTimeMillis()}.m4a")
            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            mediaRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            mediaRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            mediaRecorder.setAudioEncodingBitRate(64_000)
            mediaRecorder.setAudioSamplingRate(44_100)
            mediaRecorder.setOutputFile(file.absolutePath)
            mediaRecorder.prepare()
            mediaRecorder.start()

            recorder = mediaRecorder
            recordFile = file
            pendingRecordResult = result
            handler.postDelayed(stopRecordingRunnable, MAX_RECORD_MS)
        } catch (e: Exception) {
            // `recorder` is only assigned after start(), so release the local
            // instance here instead of going through stopRecorderQuietly().
            try {
                mediaRecorder?.release()
            } catch (_: Exception) {
                // Already released.
            }
            file?.delete()
            recorder = null
            recordFile = null
            result.error("record_failed", e.message ?: "无法开始录音", null)
        }
    }

    /** Stops at the 30 s cap and hands the file back to Flutter. */
    private fun completeRecording() {
        handler.removeCallbacks(stopRecordingRunnable)
        val result = pendingRecordResult
        val file = recordFile
        pendingRecordResult = null
        recordFile = null
        val stopped = stopRecorderQuietly()
        if (result == null) {
            file?.delete()
            return
        }
        if (stopped && file != null && file.exists() && file.length() > 0) {
            result.success(file.absolutePath)
        } else {
            file?.delete()
            result.error("record_failed", "录音失败，请重试", null)
        }
    }

    /** @return true when [MediaRecorder.stop] produced a usable container. */
    private fun stopRecorderQuietly(): Boolean {
        val mediaRecorder = recorder ?: return false
        recorder = null
        var ok = true
        try {
            mediaRecorder.stop()
        } catch (e: Exception) {
            // stop() throws when no frame was captured (tapped stop instantly).
            ok = false
        }
        try {
            mediaRecorder.release()
        } catch (e: Exception) {
            // Already released.
        }
        return ok
    }

    private fun cancelAll() {
        handler.removeCallbacks(stopRecordingRunnable)

        // The system dialog cannot be dismissed programmatically; detach from
        // it so its eventual result is ignored.
        val speechResult = pendingSpeechResult
        pendingSpeechResult = null
        speechResult?.success(null)

        val permissionResult = pendingPermissionResult
        pendingPermissionResult = null
        permissionResult?.success(null)

        val recordResult = pendingRecordResult
        pendingRecordResult = null
        val file = recordFile
        recordFile = null
        stopRecorderQuietly()
        file?.delete()
        recordResult?.success(null)
    }

    override fun onDestroy() {
        handler.removeCallbacks(stopRecordingRunnable)
        stopRecorderQuietly()
        recordFile?.delete()
        recordFile = null
        pendingSpeechResult = null
        pendingRecordResult = null
        pendingPermissionResult = null
        super.onDestroy()
    }
}
