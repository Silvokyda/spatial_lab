# Spatial Lab

A Flutter AR prototype for placing lightweight virtual objects on horizontal surfaces and moving them with a camera-tracked pinch. Android uses ARCore; iOS uses ARKit and Apple Vision.

## Run it

1. Connect an ARCore supported Android phone with USB debugging enabled.
2. Install or update Google Play Services for AR on the phone.
3. Run `flutter run` from the project directory and grant camera access.
4. Point the rear camera at a desk and move the phone slowly until the plane grid and center reticle appear.
5. Select an object, then tap the desk to place it.
6. Enable hand tracking from the hand icon. Pinch near a placed object to grab it, move the pinch ray over the tabletop, and open the fingers to release it.

Hand motion is constrained to detected horizontal planes. The hand is tracked in ARCore's own camera frame, converted to a MediaPipe input image, and the pinch position is mapped to the AR view with ARCore's 2D coordinate transform before plane hit testing. The current feature does not estimate free space metric hand depth. Rotation follows the hand's image plane palm angle as an approximate tabletop yaw control.

The initial Beaker, Cube, Sphere, and Test tube are lightweight procedural shapes; the beaker is a simple cylinder assembly. Reset removes the current anchors. The debug button displays tracking state, pinch confidence/distance, inference latency, measured AR and hand rates, skipped busy frames, and tracking failures.

## iPhone

An iOS implementation is included for ARKit horizontal plane detection, anchored SceneKit primitives, and pinch manipulation using Vision hand-pose landmarks from ARKit's own camera frames. The hand ray is constrained to detected horizontal planes; its depth is not inferred from the monocular image. The palm line supplies only an approximate in-plane yaw cue.

This workspace runs on Windows and cannot compile the iOS target locally. `codemagic.yaml` defines an unsigned debug build and packages the `.app` as an `.ipa` artifact for personal sideloading. Codemagic needs the project in a connected Git repository to run that workflow. A free Apple Account sideload expires after seven days and must be refreshed with AltServer/AltStore. A paid membership is needed for Codemagic's normal signed IPA/TestFlight path.

The iPhone 14 Pro supports the ARKit world-tracking route. The connected Android phone, OPPO CPH2473, is not supported by Google Play Services for AR; the app now shows that compatibility result rather than starting an empty AR surface.

## Build

```powershell
flutter pub get
flutter analyze
flutter build apk --debug
```

Android implementation lives in `android/app/src/main/kotlin/com/spatial/lab/spatial_lab/ar/`. iOS implementation lives in `ios/Runner/SpatialARView.swift`. Flutter owns the UI and toolbar. Native AR views host the tracking sessions and 3D scene. On Android, MediaPipe Hand Landmarker consumes images acquired from the active ARCore session. On iOS, Vision consumes the active ARKit session's `ARFrame` pixel buffer. Neither platform opens a second camera. No backend is used.

## Current validation

`flutter analyze` and `flutter build apk --debug` pass in this workspace. The Android APK was installed on the connected OPPO CPH2473; the device's ARCore availability check reports it unsupported, so AR camera tracking could not be exercised there. iOS source has not yet been compiled or run: this Windows machine has no Xcode, and there is no Codemagic-connected Git remote in this workspace. The iOS AR scene, hand-frame processing, plane stability, gesture latency, and performance still need a Codemagic build and physical iPhone test.
