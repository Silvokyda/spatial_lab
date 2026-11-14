# Spatial Lab architecture and feasibility notes

## First milestone architecture

- Flutter owns the compact camera overlay, object picker, reset control, and debug readout.
- The Android platform view hosts a native Jetpack Compose AR scene.
- SceneView `4.18.0` supplies ARCore plane detection, the camera background, a placement reticle, plane hit tests, world anchors, and Filament primitive rendering. It is chosen over the Flutter AR bridges because the current SceneView project marks its Flutter bridge deprecated; its Android AR library remains maintained.
- Placed objects are attached to ARCore anchors created from horizontal plane hits. Their positions are therefore independent of the camera after placement.
- MediaPipe Hand Landmarker runs on one worker thread, consuming throttled images acquired through ARCore's active frame. The AR image is downsampled to 480 pixels wide and converted from YUV to the ARGB input format accepted by the Android hand task.
- A two-frame pinch threshold and separate enter/exit distances provide hysteresis. Selection requires an object within 92 view pixels and a valid horizontal plane hit. During a grab, the hand ray is intersected with a tracked tabletop plane; the object moves as a child of its original anchor, preserving its grab offset. The anchor is not recreated during movement.
- Hand-loss tolerance freezes the object's last transform and releases control after 350 ms. A hand's palm line in the image provides approximate yaw rotation; it is not a wrist or full 3D orientation estimate.
- No server, account, cloud anchor, or network model loading is used.

## iOS architecture

- Flutter embeds a native `ARSCNView` using a `UiKitView`; `ARWorldTrackingConfiguration` enables horizontal plane detection, and virtual object nodes are parented to AR anchors.
- ARKit supplies the rear-camera image and tracking state in each `ARFrame`. Apple Vision's `VNDetectHumanHandPoseRequest` processes those frame pixel buffers on one serial worker at up to 10 inference attempts per second. It reads thumb/index landmarks from the ARKit-owned camera stream, so iOS does not start a second camera session.
- Vision returns normalized 2D hand landmarks. The prototype maps them through ARKit's display transform, raycasts onto an existing horizontal plane, preserves a grab offset, and moves the object's anchored child node. Depth remains constrained to that plane. A palm-line angle is used only as an approximate tabletop yaw cue.
- The iOS deployment target is 14.0. The camera permission string is declared in `Info.plist`; ARKit world-tracking support is checked before starting the session.
- `codemagic.yaml` builds an unsigned debug app and packages it as an IPA artifact. AltServer can re-sign a sideloaded IPA for personal testing, but free provisioning expires after seven days. The normal Codemagic signed IPA/TestFlight workflow needs Apple Developer Program signing credentials.

The Android toolchain available in this workspace is Flutter 3.41.7, Dart 3.11.5, JDK 21, Android SDK 35/36/37 preview, AGP 8.11.1, and Kotlin 2.2.20. SceneView 4.18.0 is pinned because the current 4.6x series requires AGP 9, Kotlin 2.3+, compile SDK 37, and JVM 21, which does not match Flutter's generated Android project. The 4.18 line supports the existing AGP 8 / Kotlin 2.2 / JVM 17 setup.

## Camera sharing and hand tracking

ARCore and MediaPipe do not need two independent camera sessions. ARCore's `Frame.acquireCameraImage()` yields the YUV 420 888 image associated with the current AR frame while that session is active. The frame must be closed promptly, inference must be throttled and moved off the rendering/UI path, and devices can return `NotYetAvailableException` or run out of outstanding image slots if images are retained. Android Camera2 Shared Camera is a separate, more involved route for adding app-owned camera surfaces; it is not needed for the documented ARCore CPU image API.

MediaPipe Hand Landmarker can consume Android image inputs and returns normalized image landmarks plus a separate hand-centric world landmark output. Neither output is an ARCore world pose. The intended conversion is:

1. Preserve the camera image dimensions and display rotation used for inference.
2. Convert the pinch midpoint from normalized image coordinates into the corresponding camera-image pixel. Account for the image orientation/crop before using camera intrinsics.
3. Build an ARCore hit test/ray from that screen point and intersect it with a detected horizontal plane.
4. Keep held objects constrained to that plane for the initial gesture prototype. Use a stable grab offset so the object does not snap on pinch start.

This provides meaningful world-space left/right/up/down movement on a tabletop while the phone and its camera move. It does not claim accurate free-space 6DoF hand tracking: monocular hand landmarks do not provide reliable metric distance from the camera. A device with usable ARCore depth could support an optional depth-aware mode later.

## Validation status

- Workspace created from an empty directory.
- Flutter, Dart, JDK, Android SDK, ADB, and emulator tools were inspected.
- Android: Flutter analysis and a debug APK build pass. The connected OPPO CPH2473 reports `The device is not supported` from ARCore's install service and is absent from Google's current supported-device list. The app displays that limitation instead of an empty camera view. AR tracking and hand interaction therefore remain unvalidated on this Android phone.
- iOS: the native ARKit/Vision source and unsigned Codemagic workflow are present, but this Windows workspace has no Xcode toolchain and no connected Codemagic Git repository. No iOS compile, install, camera, plane, gesture, or performance test has run yet. Those checks require a Codemagic build followed by installation on the iPhone 14 Pro.
- The iOS camera-sharing design reuses `ARFrame.capturedImage`, and the gesture mapping is intentionally plane-constrained. Hardware confirmation is still needed for image-orientation mapping, AR plane stability, Vision latency, selection radius, and rotation feel.

## Sources

- [SceneView repository and release notes](https://github.com/SceneView/sceneview)
- [SceneView Android quickstart](https://sceneview.github.io/docs/quickstart/)
- [ARCore `Frame.acquireCameraImage`](https://developers.google.com/ar/reference/java/com/google/ar/core/Frame#acquireCameraImage())
- [ARCore camera sharing](https://developers.google.com/ar/develop/java/camera-sharing)
- [MediaPipe Hand Landmarker](https://developers.google.com/edge/mediapipe/solutions/vision/hand_landmarker)
- [MediaPipe Android setup](https://developers.google.com/edge/mediapipe/solutions/setup_android)
- [ARCore supported devices](https://developers.google.com/ar/devices)
- [ARKit plane tracking](https://developer.apple.com/documentation/arkit/tracking-and-visualizing-planes)
- [ARSession camera frames](https://developer.apple.com/documentation/arkit/arsessiondelegate)
- [Vision hand-pose detection](https://developer.apple.com/videos/play/wwdc2020/10653/)
