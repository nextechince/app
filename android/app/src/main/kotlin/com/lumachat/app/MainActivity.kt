package com.lumachat.app

import android.media.MediaRecorder
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {

    private val CHANNEL = "com.lumachat.app/recorder"
    private var recorder: MediaRecorder? = null
    private var currentPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("NO_PATH", "path is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startRecording(path)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("START_FAILED", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            val path = stopRecording()
                            result.success(path)
                        } catch (e: Exception) {
                            result.error("STOP_FAILED", e.message, null)
                        }
                    }
                    "cancel" -> {
                        try {
                            cancelRecording()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("CANCEL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startRecording(path: String) {
        // Release any existing recorder
        try {
            recorder?.release()
        } catch (_: Exception) {}
        recorder = null

        val file = File(path)
        file.parentFile?.mkdirs()

        recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(this)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioEncodingBitRate(128000)
            setAudioSamplingRate(44100)
            setOutputFile(path)
            prepare()
            start()
        }
        currentPath = path
    }

    private fun stopRecording(): String? {
        val path = currentPath
        try {
            recorder?.stop()
        } catch (_: Exception) {
            // stop() throws when no data was recorded — ignore, still return path
        } finally {
            try {
                recorder?.release()
            } catch (_: Exception) {}
            recorder = null
            currentPath = null
        }
        return path
    }

    private fun cancelRecording() {
        try {
            recorder?.stop()
        } catch (_: Exception) {
        } finally {
            try {
                recorder?.release()
            } catch (_: Exception) {}
            recorder = null
        }
        currentPath?.let {
            val f = File(it)
            if (f.exists()) f.delete()
        }
        currentPath = null
    }

    override fun onDestroy() {
        try {
            recorder?.release()
        } catch (_: Exception) {}
        recorder = null
        super.onDestroy()
    }
}
