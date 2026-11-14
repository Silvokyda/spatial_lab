package com.spatial.lab.spatial_lab.ar

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.opengl.Matrix
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import com.google.ar.core.Anchor
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.github.sceneview.ar.ARSceneView
import io.github.sceneview.ar.arcore.createAnchorOrNull
import io.github.sceneview.rememberOnGestureListener
import com.google.ar.core.Frame
import com.google.ar.core.HitResult
import com.google.ar.core.Config
import com.google.ar.core.Coordinates2d
import com.google.ar.core.ArCoreApk
import io.github.sceneview.math.Position
import io.github.sceneview.math.Size
import io.github.sceneview.rememberEngine
import io.github.sceneview.rememberMaterialLoader
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Alignment
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.text.font.FontWeight

class SpatialArViewFactory(
    private val messenger: BinaryMessenger,
    codec: StandardMessageCodec,
) : PlatformViewFactory(codec) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return SpatialArPlatformView(context, messenger, viewId)
    }
}

private class SpatialArPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "spatial_lab/ar_view_$viewId")
    private val view = ComposeView(context)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeType = mutableStateOf("Beaker")
    private var handTrackingEnabled = mutableStateOf(false)
    private var arAvailability = mutableStateOf<ArCoreApk.Availability?>(null)
    private val objects = mutableStateListOf<PlacedObject>()
    @Volatile private var lastHandEventMs = 0L
    private val handTracker = ArFrameHandTracker(context) { sample ->
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastHandEventMs >= 90L) {
            lastHandEventMs = now
            mainHandler.post {
                channel.invokeMethod("handMetrics", sample?.let {
                    mapOf(
                        "detected" to true,
                        "gesture" to if (it.pinching) "Pinching" else "Hand detected",
                        "pinchDistance" to it.pinchDistance,
                        "confidence" to it.confidence,
                        "latencyMs" to it.latencyMs,
                        "x" to it.x,
                        "y" to it.y,
                    )
                } ?: mapOf("detected" to false, "gesture" to "Hand lost"))
            }
        }
    }
    private var lastTracking = "Starting AR"
    private var lastSurface = "Move your phone slowly to find a desk"

    init {
        channel.setMethodCallHandler(this)
        ArCoreApk.getInstance().checkAvailabilityAsync(context.applicationContext) { availability ->
            arAvailability.value = availability
            if (availability.isUnsupported) {
                updateStatus(
                    "ARCore unavailable",
                    "This phone is not currently supported by ARCore",
                    0,
                )
            }
        }
        view.setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
        view.setContent {
            when {
                arAvailability.value == null -> ArAvailabilityScene()
                arAvailability.value!!.isUnsupported -> ArUnsupportedScene()
                else -> SpatialArScene(
                activeType = activeType.value,
                objects = objects,
                handTracker = handTracker,
                handTrackingEnabled = handTrackingEnabled.value,
                onStatus = ::updateStatus,
                onMetrics = { arFps ->
                    mainHandler.post {
                        channel.invokeMethod(
                            "performanceMetrics",
                            mapOf(
                                "arFps" to arFps,
                                "handFps" to handTracker.inferenceFps,
                                "droppedFrames" to handTracker.droppedFrames,
                                "trackingFailures" to handTracker.failures,
                            ),
                        )
                    }
                },
                onGestureState = { state ->
                    mainHandler.post { channel.invokeMethod("gestureState", state) }
                },
                onPlaced = { anchor ->
                    objects.add(PlacedObject(anchor = anchor, type = activeType.value))
                    updateStatus(lastTracking, "${objects.size} object${if (objects.size == 1) "" else "s"} anchored", objects.size)
                },
                )
            }
        }
    }

    override fun getView() = view

    override fun dispose() {
        channel.setMethodCallHandler(null)
        objects.forEach { runCatching { it.anchor.detach() } }
        objects.clear()
        handTracker.close()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> {
                result.success(
                    mapOf(
                        "tracking" to lastTracking,
                        "surface" to lastSurface,
                        "placedCount" to objects.size,
                        "deviceModel" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                    ),
                )
            }
            "addObject" -> {
                activeType.value = call.argument<String>("type") ?: "Beaker"
                result.success(null)
            }
            "resetScene" -> {
                objects.forEach { runCatching { it.anchor.detach() } }
                objects.clear()
                updateStatus(lastTracking, "Move your phone slowly to find a desk", 0)
                result.success(null)
            }
            "setHandTracking" -> {
                handTrackingEnabled.value = call.argument<Boolean>("enabled") ?: false
                handTracker.enabled = handTrackingEnabled.value
                handTracker.latestSample = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun updateStatus(tracking: String, surface: String, count: Int = objects.size) {
        if (tracking == lastTracking && surface == lastSurface && count == objects.size) return
        lastTracking = tracking
        lastSurface = surface
        mainHandler.post {
            channel.invokeMethod(
                "status",
                    mapOf(
                        "tracking" to tracking,
                        "surface" to surface,
                        "placedCount" to count,
                        "deviceModel" to "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}",
                    ),
            )
        }
    }
}

@Composable
private fun ArAvailabilityScene() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Text("Checking ARCore availability…", color = Color.White.copy(alpha = 0.82f))
    }
}

@Composable
private fun ArUnsupportedScene() {
    Box(
        modifier = Modifier.fillMaxSize().background(Color(0xFF080B0B)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "SPATIAL LAB",
                color = Color(0xFF69E0C2),
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
            )
            Text(
                "ARCore isn’t available on this phone",
                color = Color.White,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                "Spatial Lab needs a phone certified for Google Play Services for AR. This ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} is not currently supported, so its camera scene cannot start.",
                color = Color.White.copy(alpha = 0.76f),
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                "Use an ARCore-supported Android phone to try the spatial prototype.",
                color = Color(0xFF69E0C2),
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

private class PlacedObject(val anchor: Anchor, val type: String) {
    var localPosition by androidx.compose.runtime.mutableStateOf(Position())
    var rotation by androidx.compose.runtime.mutableStateOf(io.github.sceneview.math.Rotation())
    var grabOffset by androidx.compose.runtime.mutableStateOf<Position?>(null)
}

@Composable
private fun SpatialArScene(
    activeType: String,
    objects: List<PlacedObject>,
    handTracker: ArFrameHandTracker,
    handTrackingEnabled: Boolean,
    onStatus: (String, String, Int) -> Unit,
    onMetrics: (Float) -> Unit,
    onGestureState: (String) -> Unit,
    onPlaced: (Anchor) -> Unit,
) {
    val engine = rememberEngine()
    val materialLoader = rememberMaterialLoader(engine)
    val status = remember { mutableStateOf("Starting AR") }
    val surfaceStatus = remember { mutableStateOf("Move your phone slowly to find a desk") }
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var latestFrame: Frame? by remember { mutableStateOf(null) }
    var reticleHit: HitResult? by remember { mutableStateOf(null) }
    var grabbing by remember { mutableStateOf<PlacedObject?>(null) }
    var lastHandTimestamp by remember { mutableStateOf(0L) }
    var gestureState by remember { mutableStateOf("Idle") }
    var releaseUntilMs by remember { mutableStateOf(0L) }
    val frameMetrics = remember { longArrayOf(0L, android.os.SystemClock.elapsedRealtimeNanos()) }

    fun setGestureState(value: String) {
        if (gestureState != value) {
            gestureState = value
            onGestureState(value)
        }
    }

    ARSceneView(
        modifier = Modifier.fillMaxSize().onSizeChanged { viewSize = it },
        engine = engine,
        materialLoader = materialLoader,
        planeRenderer = true,
        sessionConfiguration = { _, config ->
            config.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL
            config.instantPlacementMode = Config.InstantPlacementMode.DISABLED
        },
        onGestureListener = rememberOnGestureListener(
            onSingleTapConfirmed = { event, _ ->
                latestFrame?.hitTest(event.x, event.y)
                    ?.firstOrNull { hit ->
                        val plane = hit.trackable as? Plane
                        plane?.type == Plane.Type.HORIZONTAL_UPWARD_FACING && plane.trackingState == TrackingState.TRACKING
                    }
                    ?.createAnchorOrNull()
                    ?.let(onPlaced)
            },
        ),
        onSessionUpdated = { session, frame ->
            frameMetrics[0] += 1
            val metricsNow = android.os.SystemClock.elapsedRealtimeNanos()
            if (metricsNow - frameMetrics[1] >= 1_000_000_000L) {
                val arFps = frameMetrics[0] * 1_000_000_000f / (metricsNow - frameMetrics[1]).coerceAtLeast(1L)
                frameMetrics[0] = 0L
                frameMetrics[1] = metricsNow
                onMetrics(arFps)
            }
            latestFrame = frame
            handTracker.enabled = handTrackingEnabled
            if (handTrackingEnabled) handTracker.onFrame(frame)
            val tracking = if (frame.camera.trackingState == TrackingState.TRACKING) "Tracking" else "Limited tracking"
            val planes = session.getAllTrackables(Plane::class.java).count {
                it.trackingState == TrackingState.TRACKING && it.type == Plane.Type.HORIZONTAL_UPWARD_FACING
            }
            val surface = when {
                objects.isNotEmpty() -> "${objects.size} object${if (objects.size == 1) "" else "s"} anchored"
                planes > 0 -> "Surface found · tap to place ${activeType.lowercase()}"
                else -> "Move your phone slowly to find a desk"
            }
            if (status.value != tracking || surfaceStatus.value != surface) {
                status.value = tracking
                surfaceStatus.value = surface
                onStatus(tracking, surface, objects.size)
            }

            if (handTrackingEnabled) {
                val now = android.os.SystemClock.elapsedRealtime()
                val hand = handTracker.latestSample
                if (hand != null && hand.timestampMs > lastHandTimestamp) {
                    lastHandTimestamp = hand.timestampMs
                }
                if (hand != null && now - handTracker.lastHandSeenElapsedMs < 350L) {
                    val viewPoint = imagePointToView(frame, hand.x, hand.y)
                    if (hand.pinching) {
                        if (grabbing == null && viewPoint != null) {
                            val candidate = objects.asSequence()
                                .map { it to screenPosition(frame, it) }
                                .filter { (_, point) -> point != null }
                                .minByOrNull { (_, point) ->
                                    val dx = point!!.first - viewPoint.first
                                    val dy = point.second - viewPoint.second
                                    dx * dx + dy * dy
                                }
                                ?.takeIf { (_, point) ->
                                    val dx = point!!.first - viewPoint.first
                                    val dy = point.second - viewPoint.second
                                    dx * dx + dy * dy <= 92f * 92f
                                }
                                ?.first
                            val hit = viewPoint?.let { point -> tabletopHit(frame, point.first, point.second) }
                            if (candidate != null && hit != null) {
                                val localHand = candidate.anchor.pose.inverse().transformPoint(hit.hitPose.translation)
                                candidate.grabOffset = Position(
                                    candidate.localPosition.x - localHand[0],
                                    candidate.localPosition.y - localHand[1],
                                    candidate.localPosition.z - localHand[2],
                                )
                                grabbing = candidate
                            }
                        }
                        val held = grabbing
                        if (held != null && viewPoint != null) {
                            tabletopHit(frame, viewPoint.first, viewPoint.second)?.let { hit ->
                                val local = held.anchor.pose.inverse().transformPoint(hit.hitPose.translation)
                                val offset = held.grabOffset ?: Position()
                                held.localPosition = Position(local[0] + offset.x, offset.y, local[2] + offset.z)
                                held.rotation = io.github.sceneview.math.Rotation(y = -hand.rollDegrees)
                            }
                        }
                    } else if (grabbing != null) {
                        grabbing?.grabOffset = null
                        grabbing = null
                        releaseUntilMs = now + 150L
                    }
                    setGestureState(
                        when {
                            grabbing != null -> "Grabbing"
                            hand.pinching -> "Pinching"
                            now < releaseUntilMs -> "Releasing"
                            else -> "Hovering"
                        },
                    )
                } else if (grabbing != null && now - handTracker.lastHandSeenElapsedMs > 350L) {
                    // Freeze at the last valid plane hit if inference loses the hand.
                    grabbing?.grabOffset = null
                    grabbing = null
                    setGestureState("Hand lost")
                } else if (handTracker.lastInferenceElapsedMs > 0L && now - handTracker.lastInferenceElapsedMs > 350L) {
                    setGestureState("Hand lost")
                } else {
                    setGestureState("Searching")
                }
            } else if (grabbing != null) {
                grabbing?.grabOffset = null
                grabbing = null
                setGestureState("Idle")
            } else {
                setGestureState("Idle")
            }
        },
    ) {
        ReticleNode(
            xPx = viewSize.width / 2f,
            yPx = viewSize.height / 2f,
            onHitResultChanged = { reticleHit = it },
        ) {
            CylinderNode(
                radius = 0.018f,
                height = 0.002f,
                materialInstance = remember(materialLoader) {
                    materialLoader.createUnlitColorInstance(Color(0xE669E0C2))
                },
            )
        }
        objects.forEach { item ->
            androidx.compose.runtime.key(item.anchor.hashCode()) {
                AnchorNode(anchor = item.anchor) {
                    val color = when (item.type) {
                        "Cube" -> Color(0xFF80A8FF)
                        "Sphere" -> Color(0xFFFFB66E)
                        "Test tube" -> Color(0xFF7ADFCB)
                        else -> Color(0xFF82D8CD)
                    }
                    val isSelected = grabbing === item
                    val material = remember(materialLoader, item.type, isSelected) {
                        materialLoader.createColorInstance(
                            if (isSelected) Color(0xFF9CFFE8) else color,
                            metallic = 0f,
                            roughness = 0.32f,
                        )
                    }
                    Node(position = item.localPosition, rotation = item.rotation) {
                        when (item.type) {
                            "Cube" -> CubeNode(size = Size(0.08f), materialInstance = material, center = Position(0f, 0.04f, 0f))
                            "Sphere" -> SphereNode(radius = 0.045f, materialInstance = material, position = Position(0f, 0.045f, 0f))
                            "Test tube" -> {
                                CylinderNode(radius = 0.018f, height = 0.11f, materialInstance = material, position = Position(0f, 0.055f, 0f))
                                SphereNode(radius = 0.018f, materialInstance = material, position = Position(0f, 0.018f, 0f))
                            }
                            else -> {
                                CylinderNode(radius = 0.038f, height = 0.075f, materialInstance = material, position = Position(0f, 0.038f, 0f))
                                CylinderNode(radius = 0.039f, height = 0.004f, materialInstance = material, position = Position(0f, 0.078f, 0f))
                                CylinderNode(radius = 0.031f, height = 0.002f, materialInstance = material, position = Position(0f, 0.012f, 0f))
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun imagePointToView(frame: Frame, x: Float, y: Float): Pair<Float, Float>? = try {
    val output = FloatArray(2)
    frame.transformCoordinates2d(Coordinates2d.IMAGE_NORMALIZED, floatArrayOf(x, y), Coordinates2d.VIEW, output)
    output[0].takeIf { it.isFinite() }?.let { it to output[1] }
} catch (_: Exception) {
    null
}

private fun tabletopHit(frame: Frame, x: Float, y: Float): HitResult? = try {
    frame.hitTest(x, y).firstOrNull { hit ->
        val plane = hit.trackable as? Plane
        plane != null && plane.type == Plane.Type.HORIZONTAL_UPWARD_FACING &&
            plane.trackingState == TrackingState.TRACKING && hit.distance < 3f
    }
} catch (_: Exception) {
    null
}

private fun screenPosition(frame: Frame, item: PlacedObject): Pair<Float, Float>? {
    return try {
        val view = FloatArray(16)
        val projection = FloatArray(16)
        val transform = FloatArray(16)
        val clip = FloatArray(4)
        frame.camera.getViewMatrix(view, 0)
        frame.camera.getProjectionMatrix(projection, 0, 0.05f, 10f)
        Matrix.multiplyMM(transform, 0, projection, 0, view, 0)
        val point = item.anchor.pose.transformPoint(
            floatArrayOf(item.localPosition.x, item.localPosition.y + 0.04f, item.localPosition.z),
        )
        Matrix.multiplyMV(clip, 0, transform, 0, floatArrayOf(point[0], point[1], point[2], 1f), 0)
        if (clip[3] <= 0f) null else {
            val output = FloatArray(2)
            frame.transformCoordinates2d(
                Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,
                floatArrayOf(clip[0] / clip[3], clip[1] / clip[3]),
                Coordinates2d.VIEW,
                output,
            )
            output[0].takeIf { it.isFinite() }?.let { it to output[1] }
        }
    } catch (_: Exception) {
        null
    }
}
