package com.spatial.lab.spatial_lab.ar

import android.content.Context
import android.graphics.Bitmap
import android.media.Image
import android.os.SystemClock
import com.google.ar.core.Frame
import com.google.ar.core.exceptions.NotYetAvailableException
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import java.io.Closeable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.atan2
import kotlin.math.hypot

internal data class HandSample(
    val timestampMs: Long,
    val x: Float,
    val y: Float,
    val pinchDistance: Float,
    val pinching: Boolean,
    val rollDegrees: Float,
    val confidence: Float,
    val latencyMs: Float,
)

/** Reads only ARCore-owned images; it never opens Camera2 or a second camera session. */
internal class ArFrameHandTracker(
    context: Context,
    private val onSample: (HandSample?) -> Unit,
) : Closeable {
    private val appContext = context.applicationContext
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "spatial-lab-hand-landmarker").apply { isDaemon = true }
    }
    private val processing = AtomicBoolean(false)
    private val lastCaptureNs = AtomicLong(0L)
    @Volatile var enabled: Boolean = false
    @Volatile var latestSample: HandSample? = null
    @Volatile var lastInferenceElapsedMs: Long = 0L
    @Volatile var lastHandSeenElapsedMs: Long = 0L
    @Volatile var inferenceFps: Float = 0f
        private set
    @Volatile var droppedFrames: Long = 0L
        private set
    @Volatile var failures: Long = 0L
        private set
    @Volatile private var closed = false
    private var landmarker: HandLandmarker? = null
    private var inputBitmap: Bitmap? = null
    private var inputPixels = IntArray(0)
    private var inputWidth = 0
    private var inputHeight = 0
    private var lastTimestampMs = 0L
    private var smoothedX: Float? = null
    private var smoothedY: Float? = null
    private var smoothedRoll: Float? = null
    private var pinchEnterFrames = 0
    private var pinchExitFrames = 0
    private var isPinching = false
    private var missingFrames = 0

    /** Called from ARCore's frame callback. Acquisition is brief; inference runs on [worker]. */
    fun onFrame(frame: Frame) {
        if (!enabled || closed) return
        if (!processing.compareAndSet(false, true)) {
            droppedFrames += 1
            return
        }
        val now = SystemClock.elapsedRealtimeNanos()
        val previous = lastCaptureNs.get()
        if (now - previous < FRAME_INTERVAL_NS || !lastCaptureNs.compareAndSet(previous, now)) {
            processing.set(false)
            return
        }

        val image: Image = try {
            frame.acquireCameraImage()
        } catch (_: NotYetAvailableException) {
            processing.set(false)
            return
        } catch (_: Exception) {
            failures += 1
            processing.set(false)
            return
        }
        val timestampMs = frame.timestamp / 1_000_000L
        try {
            worker.execute {
                var mpImage: MPImage? = null
                val started = SystemClock.elapsedRealtimeNanos()
                try {
                    if (closed) return@execute
                    val task = landmarker ?: createLandmarker().also { landmarker = it }
                    mpImage = BitmapImageBuilder(yuvToBitmap(image)).build()
                    val timestamp = maxOf(timestampMs, lastTimestampMs + 1L)
                    lastTimestampMs = timestamp
                    val result = task.detectForVideo(mpImage, timestamp)
                    val sample = sampleFrom(result, (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000f)
                    val completedAtMs = SystemClock.elapsedRealtime()
                    val priorInferenceMs = lastInferenceElapsedMs
                    lastInferenceElapsedMs = completedAtMs
                    latestSample = sample
                    if (sample != null) lastHandSeenElapsedMs = completedAtMs
                    if (priorInferenceMs > 0L) {
                        inferenceFps = 1000f / (completedAtMs - priorInferenceMs).coerceAtLeast(1L)
                    }
                    onSample(sample)
                } catch (_: Exception) {
                    failures += 1
                    lastInferenceElapsedMs = SystemClock.elapsedRealtime()
                    latestSample = null
                    onSample(null)
                } finally {
                    mpImage?.close()
                    image.close()
                    processing.set(false)
                }
            }
        } catch (_: Exception) {
            image.close()
            processing.set(false)
        }
    }

    private fun createLandmarker(): HandLandmarker {
        val options = HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("hand_landmarker.task").build())
            .setRunningMode(RunningMode.VIDEO)
            .setNumHands(1)
            .setMinHandDetectionConfidence(0.55f)
            .setMinHandPresenceConfidence(0.55f)
            .setMinTrackingConfidence(0.55f)
            .build()
        return HandLandmarker.createFromOptions(appContext, options)
    }

    /** MediaPipe Tasks Hand Landmarker accepts ARGB_8888; convert the ARCore YUV frame once here. */
    private fun yuvToBitmap(image: Image): Bitmap {
        val crop = image.cropRect
        val scale = maxOf(1, kotlin.math.ceil(crop.width() / 480f).toInt())
        val width = (crop.width() + scale - 1) / scale
        val height = (crop.height() + scale - 1) / scale
        if (inputBitmap == null || width != inputWidth || height != inputHeight) {
            inputBitmap?.recycle()
            inputBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            inputWidth = width
            inputHeight = height
            inputPixels = IntArray(width * height)
        }
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val yBuffer = yPlane.buffer.duplicate()
        val uBuffer = uPlane.buffer.duplicate()
        val vBuffer = vPlane.buffer.duplicate()
        val yBase = yBuffer.position()
        val uBase = uBuffer.position()
        val vBase = vBuffer.position()
        for (outY in 0 until height) {
            val sourceY = crop.top + outY * scale
            for (outX in 0 until width) {
                val sourceX = crop.left + outX * scale
                val yIndex = yBase + sourceY * yPlane.rowStride + sourceX * yPlane.pixelStride
                val uvX = sourceX / 2
                val uvY = sourceY / 2
                val uIndex = uBase + uvY * uPlane.rowStride + uvX * uPlane.pixelStride
                val vIndex = vBase + uvY * vPlane.rowStride + uvX * vPlane.pixelStride
                val y = maxOf(0, (yBuffer.get(yIndex).toInt() and 0xFF) - 16)
                val u = (uBuffer.get(uIndex).toInt() and 0xFF) - 128
                val v = (vBuffer.get(vIndex).toInt() and 0xFF) - 128
                val luminance = 1192 * y
                val red = (luminance + 1634 * v).coerceIn(0, 262143)
                val green = (luminance - 833 * v - 400 * u).coerceIn(0, 262143)
                val blue = (luminance + 2066 * u).coerceIn(0, 262143)
                inputPixels[outY * width + outX] =
                    (0xFF shl 24) or ((red shl 6) and 0x00FF0000) or ((green shr 2) and 0x0000FF00) or ((blue shr 10) and 0x000000FF)
            }
        }
        val bitmap = inputBitmap!!
        bitmap.setPixels(inputPixels, 0, width, 0, 0, width, height)
        return bitmap
    }

    private fun sampleFrom(result: com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult, latencyMs: Float): HandSample? {
        val landmarks = result.landmarks().firstOrNull()
        if (landmarks == null || landmarks.size < 21) {
            missingFrames += 1
            pinchEnterFrames = 0
            if (missingFrames >= 2) {
                pinchExitFrames += 1
                if (pinchExitFrames >= 2) isPinching = false
            }
            return null
        }
        val confidence = result.handedness().firstOrNull()?.firstOrNull()?.score() ?: 0f
        if (confidence < MIN_CONFIDENCE) return null
        missingFrames = 0

        val thumb = landmarks[4]
        val index = landmarks[8]
        val indexBase = landmarks[5]
        val pinkyBase = landmarks[17]
        val x = (thumb.x() + index.x()) * 0.5f
        val y = (thumb.y() + index.y()) * 0.5f
        val distance = hypot(thumb.x() - index.x(), thumb.y() - index.y())
        val roll = Math.toDegrees(atan2((pinkyBase.y() - indexBase.y()).toDouble(), (pinkyBase.x() - indexBase.x()).toDouble())).toFloat()
        val previousX = smoothedX
        val previousY = smoothedY
        val previousRoll = smoothedRoll
        smoothedX = if (previousX == null) x else previousX + SMOOTHING * (x - previousX)
        smoothedY = if (previousY == null) y else previousY + SMOOTHING * (y - previousY)
        smoothedRoll = if (previousRoll == null) roll else previousRoll + SMOOTHING * shortestAngle(previousRoll, roll)

        if (!isPinching) {
            pinchExitFrames = 0
            pinchEnterFrames = if (distance < PINCH_START_DISTANCE) pinchEnterFrames + 1 else 0
            if (pinchEnterFrames >= PINCH_CONFIRM_FRAMES) {
                isPinching = true
                pinchEnterFrames = 0
            }
        } else {
            pinchEnterFrames = 0
            pinchExitFrames = if (distance > PINCH_END_DISTANCE) pinchExitFrames + 1 else 0
            if (pinchExitFrames >= PINCH_CONFIRM_FRAMES) {
                isPinching = false
                pinchExitFrames = 0
            }
        }
        return HandSample(result.timestampMs(), smoothedX!!, smoothedY!!, distance, isPinching, smoothedRoll!!, confidence, latencyMs)
    }

    private fun shortestAngle(from: Float, to: Float): Float = ((to - from + 540f) % 360f) - 180f

    override fun close() {
        closed = true
        enabled = false
        worker.execute {
            landmarker?.close()
            landmarker = null
            inputBitmap?.recycle()
            inputBitmap = null
            inputPixels = IntArray(0)
        }
        worker.shutdown()
    }

    private companion object {
        const val FRAME_INTERVAL_NS = 100_000_000L
        const val MIN_CONFIDENCE = 0.55f
        const val PINCH_START_DISTANCE = 0.055f
        const val PINCH_END_DISTANCE = 0.078f
        const val PINCH_CONFIRM_FRAMES = 2
        const val SMOOTHING = 0.35f
    }
}
