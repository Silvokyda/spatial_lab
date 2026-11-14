import ARKit
import Flutter
import SceneKit
import UIKit
import Vision

final class SpatialARViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    SpatialARPlatformView(frame: frame, viewId: viewId, messenger: messenger)
  }
}

private final class PlacedARObject {
  let anchor: ARAnchor
  let anchorNode: SCNNode
  let contentNode: SCNNode
  let kind: String
  /// Offset from the plane-ray hit to the object origin, in the anchor's local space.
  var grabOffset = SCNVector3Zero
  var grabStartYaw: Float = 0
  var highlightNode: SCNNode?

  init(anchor: ARAnchor, anchorNode: SCNNode, contentNode: SCNNode, kind: String) {
    self.anchor = anchor
    self.anchorNode = anchorNode
    self.contentNode = contentNode
    self.kind = kind
  }
}

/// Camera values copied from an ARFrame so the worker never retains the frame itself.
private struct CameraSnapshot {
  let transform: simd_float4x4
  let intrinsics: simd_float3x3
  let imageResolution: CGSize
}

/// LiDAR depth sampled around the fingertips. Diagnostic only: it is not used to move objects.
private struct HandDepthSample {
  let meters: Float
  let validFraction: Float
  let highConfidenceFraction: Float
  let worldPoint: simd_float3
}

/// Hand landmarks in normalized *captured image* coordinates (ARFrame.capturedImage,
/// sensor orientation, origin top-left). This is the space ARFrame.displayTransform expects.
private struct HandSample {
  let thumbTip: CGPoint
  let indexTip: CGPoint
  let indexMCP: CGPoint?
  let littleMCP: CGPoint?
  /// Fingertip gap divided by hand scale (both measured in image pixels). Orientation and distance independent.
  let pinchRatio: CGFloat
  /// Fingertip gap in Vision's normalized coordinates: the metric older builds displayed.
  let legacyTipDistance: CGFloat
  let handScalePx: CGFloat
  let confidence: Float
  let depth: HandDepthSample?
  let timestamp: TimeInterval

  var pinchMidpoint: CGPoint {
    CGPoint(x: (thumbTip.x + indexTip.x) * 0.5, y: (thumbTip.y + indexTip.y) * 0.5)
  }
}

private struct VisionOutcome {
  let sample: HandSample?
  /// True when Vision saw a hand but its landmarks were below the confidence floor.
  let lowConfidenceHand: Bool
}

final class SpatialARPlatformView: NSObject, FlutterPlatformView, ARSCNViewDelegate {
  // Pinch detection. The ratio is fingertip gap / hand scale (max of palm width and palm length).
  private let pinchEnterRatio: CGFloat = 0.35
  private let pinchExitRatio: CGFloat = 0.50
  private let pinchEnterSamples = 2
  private let pinchExitSamples = 3
  private let minLandmarkConfidence: Float = 0.30
  private let minPalmLandmarkConfidence: Float = 0.20
  // Interaction tuning.
  private let visionInterval: TimeInterval = 1.0 / 15.0
  private let selectionRadius: CGFloat = 110
  private let grabAcquireWindow: TimeInterval = 0.35
  private let handLossTimeout: TimeInterval = 0.35
  private let trackingLossReleaseDelay: TimeInterval = 0.5
  private let maxRayDistance: Float = 3.0
  private let maxDragFromAnchor: Float = 2.0
  private let rotationDeadbandRadians: Float = 8 * .pi / 180

  private let sceneView: ARSCNView
  private let overlayView = UIView()
  private let cursorLayer = CAShapeLayer()
  private let selectionRadiusLayer = CAShapeLayer()
  private let landmarkLayer = CAShapeLayer()
  private let channel: FlutterMethodChannel
  private let handQueue = DispatchQueue(label: "spatial_lab.vision_hand", qos: .userInitiated)
  private let handPoseRequest: VNDetectHumanHandPoseRequest = {
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1
    return request
  }()
  private let depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

  private var latestHand: HandSample?
  private var handDetectionEnabled = false
  private var debugOverlayEnabled = false
  private var visionBusy = false
  private var lastVisionStart: TimeInterval = 0
  private var lastHandSeen: TimeInterval = 0
  private var lastHandEvent: TimeInterval = 0
  private var lastInferenceLatencyMs = 0.0
  private var lastVisionLowConfidence = false
  private var smoothedPoint = CGPoint.zero
  private var hasSmoothedPoint = false
  private var smoothedPinchRatio: CGFloat = 1
  private var hasSmoothedPinchRatio = false
  private var pinchEnterCount = 0
  private var pinchExitCount = 0
  private var lastGestureSampleTimestamp: TimeInterval = 0
  private var isPinching = false
  private var pinchStartedAt: TimeInterval = 0
  private var grabbedObject: PlacedARObject?
  private var hoveredObject: PlacedARObject?
  private var grabStartHandAngle: Float?
  private var gestureState = "Idle"
  private var releaseUntil: TimeInterval = 0
  private var trackingLostSince: TimeInterval?
  // Diagnostics for the debug overlay.
  private var lastCandidateName: String?
  private var lastCandidateDistance: CGFloat?
  private var lastPlaneHit = false
  private var activeKind = "Beaker"
  private var planeAnchors = Set<UUID>()
  private var objects: [UUID: PlacedARObject] = [:]
  private var pendingObjectKinds: [UUID: String] = [:]
  private var lastTracking = "Starting AR"
  private var lastSurface = "Move your phone slowly to find a desk"
  private var placedCount = 0
  private var displayLink: CADisplayLink?
  private var lastStatusAt: TimeInterval = 0
  private var lastMetricsAt: TimeInterval = 0
  private var renderFrameCount = 0
  private var renderWindowStart: TimeInterval = 0
  private var measuredARFPS = 0.0
  private var inferenceFrameCount = 0
  private var detectedFrameCount = 0
  private var measuredHandFPS = 0.0
  private var measuredDetectedFPS = 0.0
  private var droppedVisionFrames = 0
  private var trackingFailureCount = 0

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
    sceneView = ARSCNView(frame: frame)
    channel = FlutterMethodChannel(name: "spatial_lab/ar_view_\(viewId)", binaryMessenger: messenger)
    super.init()

    sceneView.scene = SCNScene()
    sceneView.delegate = self
    sceneView.automaticallyUpdatesLighting = true
    sceneView.autoenablesDefaultLighting = true
    sceneView.backgroundColor = .black

    overlayView.frame = sceneView.bounds
    overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlayView.isUserInteractionEnabled = false
    overlayView.backgroundColor = .clear
    for layer in [selectionRadiusLayer, landmarkLayer, cursorLayer] {
      layer.fillColor = UIColor.clear.cgColor
      layer.isHidden = true
      overlayView.layer.addSublayer(layer)
    }
    selectionRadiusLayer.lineDashPattern = [6, 5]
    selectionRadiusLayer.lineWidth = 1
    selectionRadiusLayer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
    landmarkLayer.fillColor = UIColor(red: 1, green: 0.77, blue: 0.43, alpha: 0.95).cgColor
    sceneView.addSubview(overlayView)

    let tap = UITapGestureRecognizer(target: self, action: #selector(placeObject(_:)))
    sceneView.addGestureRecognizer(tap)

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    if ARWorldTrackingConfiguration.isSupported {
      sceneView.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
      lastTracking = "Limited tracking"
    } else {
      lastTracking = "ARKit unavailable"
      lastSurface = "This iPhone does not support ARKit world tracking"
    }

    displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
    displayLink?.add(to: .main, forMode: .common)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  func view() -> UIView { sceneView }

  deinit {
    displayLink?.invalidate()
    NotificationCenter.default.removeObserver(self)
    sceneView.session.pause()
    channel.setMethodCallHandler(nil)
  }

  private func makeConfiguration() -> ARWorldTrackingConfiguration {
    let configuration = ARWorldTrackingConfiguration()
    configuration.planeDetection = [.horizontal]
    configuration.isLightEstimationEnabled = true
    // LiDAR depth (iPhone 12 Pro and later Pro models) is sampled near the hand for diagnostics only.
    if depthSupported {
      configuration.frameSemantics.insert(.sceneDepth)
    }
    return configuration
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getState":
      result(statePayload())
    case "addObject":
      let arguments = call.arguments as? [String: Any]
      activeKind = arguments?["type"] as? String ?? "Beaker"
      result(nil)
    case "resetScene":
      endInteraction()
      let anchors = objects.values.map(\.anchor)
      anchors.forEach { sceneView.session.remove(anchor: $0) }
      objects.removeAll()
      pendingObjectKinds.removeAll()
      placedCount = 0
      updateStatus(lastTracking, "Move your phone slowly to find a desk", count: 0, force: true)
      result(nil)
    case "setHandTracking":
      let arguments = call.arguments as? [String: Any]
      handDetectionEnabled = arguments?["enabled"] as? Bool ?? false
      latestHand = nil
      lastHandSeen = 0
      endInteraction()
      updateCursor(nil, sample: nil, transform: nil)
      setGestureState(handDetectionEnabled ? "Searching" : "Idle")
      result(nil)
    case "setDebugOverlay":
      let arguments = call.arguments as? [String: Any]
      debugOverlayEnabled = arguments?["enabled"] as? Bool ?? false
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func statePayload() -> [String: Any] {
    ["tracking": lastTracking, "surface": lastSurface, "placedCount": placedCount, "deviceModel": "iPhone"]
  }

  private func updateStatus(_ tracking: String, _ surface: String, count: Int? = nil, force: Bool = false) {
    if let count { placedCount = count }
    guard force || tracking != lastTracking || surface != lastSurface else { return }
    lastTracking = tracking
    lastSurface = surface
    channel.invokeMethod("status", arguments: statePayload())
  }

  @objc private func placeObject(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended else { return }
    let point = recognizer.location(in: sceneView)
    guard let query = sceneView.raycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal),
          let hit = sceneView.session.raycast(query).first else {
      updateStatus(lastTracking, "Move your phone slowly until a horizontal surface is found", force: true)
      return
    }

    let anchor = ARAnchor(transform: hit.worldTransform)
    pendingObjectKinds[anchor.identifier] = activeKind
    sceneView.session.add(anchor: anchor)
  }

  func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let plane = anchor as? ARPlaneAnchor {
        self.planeAnchors.insert(anchor.identifier)
        self.installPlaneHighlight(for: plane, on: node)
        if self.objects.isEmpty {
          self.updateStatus(self.lastTracking, "Surface found · tap to place \(self.activeKind.lowercased())", force: true)
        }
      } else if let kind = self.pendingObjectKinds.removeValue(forKey: anchor.identifier) {
        let object = self.makeObject(kind: kind, anchor: anchor, anchorNode: node)
        self.objects[anchor.identifier] = object
        self.placedCount = self.objects.count
        self.updateStatus(self.lastTracking, "\(self.placedCount) object\(self.placedCount == 1 ? "" : "s") anchored", count: self.placedCount, force: true)
      }
    }
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    guard let plane = anchor as? ARPlaneAnchor else { return }
    DispatchQueue.main.async { [weak self, weak node] in
      guard let self, let node, self.planeAnchors.contains(anchor.identifier) else { return }
      self.updatePlaneHighlight(for: plane, on: node)
    }
  }

  func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.planeAnchors.remove(anchor.identifier)
      if self.grabbedObject?.anchor.identifier == anchor.identifier { self.endInteraction() }
      if self.hoveredObject?.anchor.identifier == anchor.identifier { self.setHovered(nil) }
      self.objects.removeValue(forKey: anchor.identifier)
      self.placedCount = self.objects.count
    }
  }

  private func installPlaneHighlight(for plane: ARPlaneAnchor, on node: SCNNode) {
    let material = SCNMaterial()
    material.diffuse.contents = UIColor(red: 0.30, green: 0.84, blue: 0.73, alpha: 0.13)
    material.isDoubleSided = true
    material.lightingModel = .constant
    let geometry = SCNPlane(width: CGFloat(plane.extent.x), height: CGFloat(plane.extent.z))
    geometry.materials = [material]
    let highlight = SCNNode(geometry: geometry)
    highlight.eulerAngles.x = -.pi / 2
    highlight.position = SCNVector3(plane.center.x, 0.001, plane.center.z)
    highlight.name = "plane-highlight-\(plane.identifier)"
    node.addChildNode(highlight)
  }

  private func updatePlaneHighlight(for plane: ARPlaneAnchor, on node: SCNNode) {
    guard let highlight = node.childNode(withName: "plane-highlight-\(plane.identifier)", recursively: false),
          let geometry = highlight.geometry as? SCNPlane else { return }
    geometry.width = CGFloat(plane.extent.x)
    geometry.height = CGFloat(plane.extent.z)
    highlight.position = SCNVector3(plane.center.x, 0.001, plane.center.z)
  }

  private func makeObject(kind: String, anchor: ARAnchor, anchorNode: SCNNode) -> PlacedARObject {
    let content = SCNNode()
    let tint: UIColor
    let baseHeight: Float
    switch kind {
    case "Cube":
      tint = UIColor(red: 0.44, green: 0.62, blue: 1.0, alpha: 1)
      baseHeight = 0.04
      let box = SCNBox(width: 0.08, height: 0.08, length: 0.08, chamferRadius: 0.005)
      box.firstMaterial?.diffuse.contents = tint
      let mesh = SCNNode(geometry: box)
      mesh.position.y = baseHeight
      content.addChildNode(mesh)
    case "Sphere":
      tint = UIColor(red: 1.0, green: 0.69, blue: 0.39, alpha: 1)
      baseHeight = 0.045
      let sphere = SCNSphere(radius: 0.045)
      sphere.firstMaterial?.diffuse.contents = tint
      let mesh = SCNNode(geometry: sphere)
      mesh.position.y = baseHeight
      content.addChildNode(mesh)
    case "Test tube":
      tint = UIColor(red: 0.48, green: 0.87, blue: 0.79, alpha: 1)
      baseHeight = 0.055
      let tube = SCNCylinder(radius: 0.018, height: 0.105)
      tube.firstMaterial?.diffuse.contents = tint.withAlphaComponent(0.75)
      let tubeNode = SCNNode(geometry: tube)
      tubeNode.position.y = 0.055
      content.addChildNode(tubeNode)
      let bottom = SCNSphere(radius: 0.018)
      bottom.firstMaterial?.diffuse.contents = tint.withAlphaComponent(0.75)
      let bottomNode = SCNNode(geometry: bottom)
      bottomNode.position.y = 0.006
      content.addChildNode(bottomNode)
    default:
      tint = UIColor(red: 0.40, green: 0.84, blue: 0.79, alpha: 0.8)
      baseHeight = 0.04
      let body = SCNCylinder(radius: 0.035, height: 0.075)
      body.firstMaterial?.diffuse.contents = tint
      body.firstMaterial?.isDoubleSided = true
      let bodyNode = SCNNode(geometry: body)
      bodyNode.position.y = 0.038
      content.addChildNode(bodyNode)
      let rim = SCNTorus(ringRadius: 0.034, pipeRadius: 0.003)
      rim.firstMaterial?.diffuse.contents = tint
      let rimNode = SCNNode(geometry: rim)
      rimNode.eulerAngles.x = .pi / 2
      rimNode.position.y = 0.077
      content.addChildNode(rimNode)
      let base = SCNCylinder(radius: 0.034, height: 0.003)
      base.firstMaterial?.diffuse.contents = tint
      let baseNode = SCNNode(geometry: base)
      baseNode.position.y = 0.002
      content.addChildNode(baseNode)
    }
    content.name = "spatial-object-\(anchor.identifier)"
    anchorNode.addChildNode(content)
    return PlacedARObject(anchor: anchor, anchorNode: anchorNode, contentNode: content, kind: kind)
  }

  // MARK: - Frame loop

  @objc private func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    let frame = sceneView.session.currentFrame
    scheduleVisionIfNeeded(now: now, frame: frame)
    updateTracking(now: now, frame: frame)
    updateManipulation(now: now, frame: frame)
    sendMetricsIfNeeded(now: now)
  }

  private var interfaceOrientation: UIInterfaceOrientation {
    sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
  }

  private func scheduleVisionIfNeeded(now: TimeInterval, frame: ARFrame?) {
    guard handDetectionEnabled, now - lastVisionStart >= visionInterval else { return }
    lastVisionStart = now
    guard !visionBusy else {
      droppedVisionFrames += 1
      return
    }
    guard let frame else { return }
    visionBusy = true
    let pixelBuffer = frame.capturedImage
    let orientation = Self.visionOrientation(for: interfaceOrientation)
    let depth = frame.sceneDepth
    let camera = CameraSnapshot(
      transform: frame.camera.transform,
      intrinsics: frame.camera.intrinsics,
      imageResolution: frame.camera.imageResolution
    )
    let request = handPoseRequest
    let minConfidence = minLandmarkConfidence
    let minPalmConfidence = minPalmLandmarkConfidence
    handQueue.async { [weak self] in
      let started = CACurrentMediaTime()
      let outcome = SpatialARPlatformView.detectHand(
        pixelBuffer: pixelBuffer,
        orientation: orientation,
        request: request,
        depth: depth,
        camera: camera,
        minConfidence: minConfidence,
        minPalmConfidence: minPalmConfidence
      )
      let latency = (CACurrentMediaTime() - started) * 1_000
      DispatchQueue.main.async {
        guard let self else { return }
        self.visionBusy = false
        self.inferenceFrameCount += 1
        self.lastInferenceLatencyMs = latency
        self.lastVisionLowConfidence = outcome.lowConfidenceHand
        // A single missed frame keeps the previous sample; staleness (handLossTimeout) decides loss.
        if let sample = outcome.sample, self.handDetectionEnabled {
          self.detectedFrameCount += 1
          self.latestHand = sample
          self.lastHandSeen = sample.timestamp
        }
      }
    }
  }

  // MARK: - Vision (runs on handQueue)

  private static func visionOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
    // ARFrame.capturedImage is always in the sensor's native landscape-right orientation.
    switch orientation {
    case .portrait: return .right
    case .portraitUpsideDown: return .left
    case .landscapeLeft: return .down
    case .landscapeRight: return .up
    default: return .right
    }
  }

  /// Converts a Vision point (normalized, origin bottom-left, in the *oriented* image) into
  /// normalized captured-image coordinates (origin top-left, sensor orientation).
  private static func capturedImagePoint(fromVision point: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
    let ox = point.x
    let oy = 1 - point.y
    switch orientation {
    case .right: return CGPoint(x: oy, y: 1 - ox)
    case .left: return CGPoint(x: 1 - oy, y: ox)
    case .down: return CGPoint(x: 1 - ox, y: 1 - oy)
    default: return CGPoint(x: ox, y: oy)
    }
  }

  private static func detectHand(
    pixelBuffer: CVPixelBuffer,
    orientation: CGImagePropertyOrientation,
    request: VNDetectHumanHandPoseRequest,
    depth: ARDepthData?,
    camera: CameraSnapshot,
    minConfidence: Float,
    minPalmConfidence: Float
  ) -> VisionOutcome {
    do {
      try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
    } catch {
      NSLog("Spatial Lab Vision hand request failed: %@", error.localizedDescription)
      return VisionOutcome(sample: nil, lowConfidenceHand: false)
    }
    guard let observation = request.results?.first,
          let points = try? observation.recognizedPoints(.all) else {
      return VisionOutcome(sample: nil, lowConfidenceHand: false)
    }
    guard let thumb = points[.thumbTip], let index = points[.indexTip],
          thumb.confidence >= minConfidence, index.confidence >= minConfidence else {
      return VisionOutcome(sample: nil, lowConfidenceHand: true)
    }

    let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
    func imagePoint(_ joint: VNHumanHandPoseObservation.JointName, _ floor: Float) -> CGPoint? {
      guard let point = points[joint], point.confidence >= floor else { return nil }
      return capturedImagePoint(fromVision: point.location, orientation: orientation)
    }
    func pixelDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
      hypot((a.x - b.x) * width, (a.y - b.y) * height)
    }

    let thumbTip = capturedImagePoint(fromVision: thumb.location, orientation: orientation)
    let indexTip = capturedImagePoint(fromVision: index.location, orientation: orientation)
    let indexMCP = imagePoint(.indexMCP, minPalmConfidence)
    let littleMCP = imagePoint(.littleMCP, minPalmConfidence)
    let wrist = imagePoint(.wrist, minPalmConfidence)
    let middleMCP = imagePoint(.middleMCP, minPalmConfidence)

    // Hand scale: the larger of palm width and palm length, so turning the hand edge-on
    // (which collapses one of them) does not inflate the ratio.
    var handScale: CGFloat = 0
    if let indexMCP, let littleMCP { handScale = max(handScale, pixelDistance(indexMCP, littleMCP)) }
    if let wrist, let middleMCP { handScale = max(handScale, pixelDistance(wrist, middleMCP)) }
    guard handScale > 12 else {
      return VisionOutcome(sample: nil, lowConfidenceHand: true)
    }

    let tipGap = pixelDistance(thumbTip, indexTip)
    let depthSample = depth.flatMap { sampleDepth($0, near: [indexTip, thumbTip], camera: camera) }
    let sample = HandSample(
      thumbTip: thumbTip,
      indexTip: indexTip,
      indexMCP: indexMCP,
      littleMCP: littleMCP,
      pinchRatio: tipGap / handScale,
      legacyTipDistance: hypot(thumb.location.x - index.location.x, thumb.location.y - index.location.y),
      handScalePx: handScale,
      confidence: min(thumb.confidence, index.confidence),
      depth: depthSample,
      timestamp: CACurrentMediaTime()
    )
    return VisionOutcome(sample: sample, lowConfidenceHand: false)
  }

  /// Median LiDAR depth in a 5x5 window around each fingertip; returns the nearer valid tip,
  /// unprojected to world space through the camera intrinsics and pose of the same frame.
  private static func sampleDepth(_ depth: ARDepthData, near imagePoints: [CGPoint], camera: CameraSnapshot) -> HandDepthSample? {
    let depthMap = depth.depthMap
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
    guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
    let width = CVPixelBufferGetWidth(depthMap)
    let height = CVPixelBufferGetHeight(depthMap)
    let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

    let confidenceMap = depth.confidenceMap
    if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
    defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }
    let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
    let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

    var best: (meters: Float, valid: Float, high: Float, point: CGPoint)?
    for point in imagePoints {
      let centerX = Int(point.x * CGFloat(width))
      let centerY = Int(point.y * CGFloat(height))
      var values: [Float] = []
      var highCount = 0
      var total = 0
      for dy in -2...2 {
        for dx in -2...2 {
          let x = centerX + dx
          let y = centerY + dy
          guard x >= 0, y >= 0, x < width, y < height else { continue }
          total += 1
          var confidence: UInt8 = 2
          if let confidenceBase {
            confidence = confidenceBase.advanced(by: y * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)[x]
          }
          guard confidence >= UInt8(ARConfidenceLevel.medium.rawValue) else { continue }
          let meters = depthBase.advanced(by: y * depthRowBytes).assumingMemoryBound(to: Float32.self)[x]
          guard meters.isFinite, meters > 0.1, meters < 3 else { continue }
          values.append(meters)
          if confidence >= UInt8(ARConfidenceLevel.high.rawValue) { highCount += 1 }
        }
      }
      guard total > 0, values.count >= 5 else { continue }
      values.sort()
      let median = values[values.count / 2]
      if best == nil || median < best!.meters {
        best = (median, Float(values.count) / Float(total), Float(highCount) / Float(total), point)
      }
    }
    guard let best else { return nil }

    let u = Float(best.point.x * camera.imageResolution.width)
    let v = Float(best.point.y * camera.imageResolution.height)
    let fx = camera.intrinsics[0][0]
    let fy = camera.intrinsics[1][1]
    let cx = camera.intrinsics[2][0]
    let cy = camera.intrinsics[2][1]
    // ARKit camera space: +x right, +y up, camera looks down -z. Image v grows downward.
    let local = simd_float4((u - cx) / fx * best.meters, -(v - cy) / fy * best.meters, -best.meters, 1)
    let world = camera.transform * local
    return HandDepthSample(
      meters: best.meters,
      validFraction: best.valid,
      highConfidenceFraction: best.high,
      worldPoint: simd_float3(world.x, world.y, world.z)
    )
  }

  // MARK: - Tracking status

  private func updateTracking(now: TimeInterval, frame: ARFrame?) {
    guard now - lastStatusAt >= 0.35 else { return }
    lastStatusAt = now
    guard let frame else { return }
    let tracking: String
    switch frame.camera.trackingState {
    case .normal: tracking = "Tracking"
    case .notAvailable: tracking = "Limited tracking"
    case .limited: tracking = "Limited tracking"
    }
    if objects.isEmpty && !planeAnchors.isEmpty {
      updateStatus(tracking, "Surface found · tap to place \(activeKind.lowercased())")
    } else if objects.isEmpty {
      updateStatus(tracking, "Move your phone slowly to find a desk")
    } else {
      updateStatus(tracking, "\(objects.count) object\(objects.count == 1 ? "" : "s") anchored")
    }
  }

  // MARK: - Hand manipulation

  /// Normalized captured-image point -> AR view point, through the same display transform ARSCNView uses.
  private func viewPoint(_ imagePoint: CGPoint, transform: CGAffineTransform) -> CGPoint? {
    let normalized = imagePoint.applying(transform)
    guard normalized.x.isFinite, normalized.y.isFinite else { return nil }
    return CGPoint(x: normalized.x * sceneView.bounds.width, y: normalized.y * sceneView.bounds.height)
  }

  private func handAngle(_ sample: HandSample, transform: CGAffineTransform) -> Float? {
    guard let indexMCP = sample.indexMCP, let littleMCP = sample.littleMCP,
          let a = viewPoint(indexMCP, transform: transform),
          let b = viewPoint(littleMCP, transform: transform) else { return nil }
    return Float(atan2(b.y - a.y, b.x - a.x))
  }

  private func updateManipulation(now: TimeInterval, frame: ARFrame?) {
    guard handDetectionEnabled, let frame else { return }
    var trackingNormal = false
    if case .normal = frame.camera.trackingState { trackingNormal = true }
    if trackingNormal {
      trackingLostSince = nil
    } else if trackingLostSince == nil {
      trackingLostSince = now
    }

    guard let sample = latestHand, now - sample.timestamp < handLossTimeout else {
      // No fresh hand: release in place (the object keeps its last anchored position).
      hasSmoothedPoint = false
      hasSmoothedPinchRatio = false
      let hadGrab = grabbedObject != nil
      endInteraction()
      setHovered(nil)
      lastCandidateName = nil
      lastCandidateDistance = nil
      lastPlaneHit = false
      if hadGrab || (lastHandSeen > 0 && now - lastHandSeen < 1.5) {
        setGestureState("Hand lost")
      } else {
        setGestureState("Searching")
      }
      updateCursor(nil, sample: nil, transform: nil)
      emitHandMetricsIfNeeded(now: now, sample: nil, point: nil)
      return
    }

    let transform = frame.displayTransform(for: interfaceOrientation, viewportSize: sceneView.bounds.size)
    guard let rawPoint = viewPoint(sample.pinchMidpoint, transform: transform) else { return }
    if hasSmoothedPoint {
      smoothedPoint = CGPoint(
        x: smoothedPoint.x * 0.6 + rawPoint.x * 0.4,
        y: smoothedPoint.y * 0.6 + rawPoint.y * 0.4
      )
    } else {
      smoothedPoint = rawPoint
      hasSmoothedPoint = true
    }
    let point = smoothedPoint
    let angle = handAngle(sample, transform: transform)

    // Pinch state machine: advances once per new Vision sample.
    if sample.timestamp != lastGestureSampleTimestamp {
      lastGestureSampleTimestamp = sample.timestamp
      smoothedPinchRatio = hasSmoothedPinchRatio
        ? smoothedPinchRatio * 0.4 + sample.pinchRatio * 0.6
        : sample.pinchRatio
      hasSmoothedPinchRatio = true
      if smoothedPinchRatio < pinchEnterRatio {
        pinchEnterCount += 1
        pinchExitCount = 0
      } else if smoothedPinchRatio > pinchExitRatio {
        pinchExitCount += 1
        pinchEnterCount = 0
      } else {
        pinchEnterCount = 0
        pinchExitCount = 0
      }
      if !isPinching && pinchEnterCount >= pinchEnterSamples {
        isPinching = true
        pinchStartedAt = now
      } else if isPinching && pinchExitCount >= pinchExitSamples {
        isPinching = false
        if grabbedObject != nil {
          releaseGrab()
          releaseUntil = now + 0.3
        }
      }
    }

    if let held = grabbedObject {
      setHovered(nil)
      lastCandidateName = held.kind
      lastCandidateDistance = screenDistance(held, to: point)
      if let lostSince = trackingLostSince {
        // Freeze while ARKit tracking is degraded; release in place if it does not recover.
        if now - lostSince > trackingLossReleaseDelay {
          releaseGrab()
        }
        setGestureState("Tracking lost")
      } else {
        lastPlaneHit = moveGrabbedObject(held, to: point, handAngle: angle)
        setGestureState("Grabbing")
      }
    } else {
      let candidate = trackingNormal ? selectableCandidate(at: point) : nil
      if isPinching {
        setHovered(nil)
        if let candidate, now - pinchStartedAt <= grabAcquireWindow {
          beginGrab(candidate, at: point, handAngle: angle)
          setGestureState("Grabbing")
        } else {
          setGestureState(trackingNormal ? "Pinching" : "Tracking lost")
        }
      } else {
        setHovered(candidate)
        if !trackingNormal {
          setGestureState("Tracking lost")
        } else if now < releaseUntil {
          setGestureState("Releasing")
        } else {
          setGestureState("Hovering")
        }
      }
    }

    updateCursor(point, sample: sample, transform: transform)
    emitHandMetricsIfNeeded(now: now, sample: sample, point: point)
  }

  /// The nearest object whose projected center is within `selectionRadius` of the point (or that the
  /// point directly hits), and whose support plane the interaction ray intersects.
  private func selectableCandidate(at point: CGPoint) -> PlacedARObject? {
    var best: (object: PlacedARObject, distance: CGFloat)?
    let hits = sceneView.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
    for hit in hits {
      if let hitObject = placedObject(containing: hit.node) {
        best = (hitObject, 0)
        break
      }
    }
    if best == nil {
      for object in objects.values {
        guard let distance = screenDistance(object, to: point) else { continue }
        if best == nil || distance < best!.distance { best = (object, distance) }
      }
    }
    lastCandidateName = best?.object.kind
    lastCandidateDistance = best?.distance
    guard let best, best.distance <= selectionRadius else {
      lastPlaneHit = best.map { supportPlaneHit(at: point, for: $0.object) != nil } ?? false
      return nil
    }
    lastPlaneHit = supportPlaneHit(at: point, for: best.object) != nil
    return lastPlaneHit ? best.object : nil
  }

  private func placedObject(containing node: SCNNode) -> PlacedARObject? {
    var current: SCNNode? = node
    while let candidate = current {
      if let match = objects.values.first(where: { $0.contentNode === candidate }) { return match }
      current = candidate.parent
    }
    return nil
  }

  private func beginGrab(_ object: PlacedARObject, at point: CGPoint, handAngle: Float?) {
    guard let hit = supportPlaneHit(at: point, for: object) else { return }
    let localHit = object.anchorNode.convertPosition(hit, from: nil)
    let position = object.contentNode.position
    object.grabOffset = SCNVector3(position.x - localHit.x, 0, position.z - localHit.z)
    object.grabStartYaw = object.contentNode.eulerAngles.y
    grabStartHandAngle = handAngle
    grabbedObject = object
    setHighlight(object, style: .grabbed)
  }

  /// Tabletop-plane mode: the screen ray is intersected with the horizontal plane the object
  /// was placed on. Hand depth is not used, so the object never moves vertically.
  @discardableResult
  private func moveGrabbedObject(_ object: PlacedARObject, to point: CGPoint, handAngle: Float?) -> Bool {
    guard let hit = supportPlaneHit(at: point, for: object) else { return false }
    let localHit = object.anchorNode.convertPosition(hit, from: nil)
    let target = SCNVector3(localHit.x + object.grabOffset.x, 0, localHit.z + object.grabOffset.z)
    guard (target.x * target.x + target.z * target.z).squareRoot() <= maxDragFromAnchor else { return false }
    object.contentNode.position = target

    // Approximate yaw from the in-image rotation of the palm line, relative to the pose at grab time.
    if let handAngle, let startAngle = grabStartHandAngle {
      var delta = Self.wrapAngle(handAngle - startAngle)
      if abs(delta) < rotationDeadbandRadians {
        delta = 0
      } else {
        delta -= delta > 0 ? rotationDeadbandRadians : -rotationDeadbandRadians
      }
      let targetYaw = object.grabStartYaw - delta
      let currentYaw = object.contentNode.eulerAngles.y
      object.contentNode.eulerAngles.y = currentYaw + Self.wrapAngle(targetYaw - currentYaw) * 0.35
    }
    return true
  }

  private func supportPlaneHit(at point: CGPoint, for object: PlacedARObject) -> SCNVector3? {
    let planeY = object.anchorNode.worldPosition.y
    let near = sceneView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
    let far = sceneView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
    let direction = SCNVector3(far.x - near.x, far.y - near.y, far.z - near.z)
    guard abs(direction.y) > 1e-6 else { return nil }
    let t = (planeY - near.y) / direction.y
    guard t > 0 else { return nil }
    let hit = SCNVector3(near.x + direction.x * t, planeY, near.z + direction.z * t)
    if let camera = sceneView.pointOfView?.worldPosition {
      let dx = hit.x - camera.x, dy = hit.y - camera.y, dz = hit.z - camera.z
      guard (dx * dx + dy * dy + dz * dz).squareRoot() <= maxRayDistance else { return nil }
    }
    return hit
  }

  private func screenDistance(_ object: PlacedARObject, to point: CGPoint) -> CGFloat? {
    let center = object.contentNode.presentation.convertPosition(SCNVector3(0, 0.05, 0), to: nil)
    let projected = sceneView.projectPoint(center)
    guard projected.z > 0, projected.z < 1 else { return nil }
    return hypot(CGFloat(projected.x) - point.x, CGFloat(projected.y) - point.y)
  }

  private static func wrapAngle(_ angle: Float) -> Float {
    var value = angle
    while value > .pi { value -= 2 * .pi }
    while value < -.pi { value += 2 * .pi }
    return value
  }

  private func releaseGrab() {
    if let object = grabbedObject {
      setHighlight(object, style: nil)
    }
    grabbedObject = nil
    grabStartHandAngle = nil
    pinchEnterCount = 0
    pinchExitCount = 0
  }

  private func endInteraction() {
    releaseGrab()
    setHovered(nil)
    isPinching = false
  }

  private enum HighlightStyle { case hover, grabbed }

  private func setHovered(_ object: PlacedARObject?) {
    guard hoveredObject !== object else { return }
    if let previous = hoveredObject, previous !== grabbedObject { setHighlight(previous, style: nil) }
    hoveredObject = object
    if let object, object !== grabbedObject { setHighlight(object, style: .hover) }
  }

  private func setHighlight(_ object: PlacedARObject, style: HighlightStyle?) {
    object.highlightNode?.removeFromParentNode()
    object.highlightNode = nil
    guard let style else { return }
    let grabbed = style == .grabbed
    let ring = SCNTorus(ringRadius: 0.058, pipeRadius: grabbed ? 0.0035 : 0.0018)
    ring.firstMaterial?.diffuse.contents = grabbed
      ? UIColor(red: 0.45, green: 1, blue: 0.88, alpha: 0.95)
      : UIColor(white: 1, alpha: 0.6)
    ring.firstMaterial?.lightingModel = .constant
    let highlight = SCNNode(geometry: ring)
    highlight.position.y = 0.004
    // Child of the content node so the ring travels with the object.
    object.contentNode.addChildNode(highlight)
    object.highlightNode = highlight
  }

  private func setGestureState(_ state: String) {
    guard state != gestureState else { return }
    gestureState = state
    channel.invokeMethod("gestureState", arguments: state)
  }

  // MARK: - On-screen feedback

  private func updateCursor(_ point: CGPoint?, sample: HandSample?, transform: CGAffineTransform?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let point else {
      cursorLayer.isHidden = true
      selectionRadiusLayer.isHidden = true
      landmarkLayer.isHidden = true
      return
    }

    let color: UIColor
    var filled = false
    switch gestureState {
    case "Grabbing":
      color = UIColor(red: 0.41, green: 0.88, blue: 0.76, alpha: 1)
      filled = true
    case "Pinching":
      color = UIColor(red: 1, green: 0.77, blue: 0.43, alpha: 1)
      filled = true
    case "Releasing":
      color = UIColor(white: 0.85, alpha: 1)
    case "Tracking lost":
      color = UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1)
    default:
      color = hoveredObject != nil ? UIColor(red: 0.41, green: 0.88, blue: 0.76, alpha: 1) : .white
    }
    let radius: CGFloat = filled ? 10 : 14
    cursorLayer.path = UIBezierPath(
      ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    ).cgPath
    cursorLayer.strokeColor = color.cgColor
    cursorLayer.fillColor = filled ? color.withAlphaComponent(0.55).cgColor : UIColor.clear.cgColor
    cursorLayer.lineWidth = 2.5
    cursorLayer.isHidden = false

    selectionRadiusLayer.isHidden = !debugOverlayEnabled
    landmarkLayer.isHidden = !debugOverlayEnabled
    guard debugOverlayEnabled else { return }
    selectionRadiusLayer.path = UIBezierPath(
      ovalIn: CGRect(x: point.x - selectionRadius, y: point.y - selectionRadius, width: selectionRadius * 2, height: selectionRadius * 2)
    ).cgPath
    let tips = UIBezierPath()
    if let sample, let transform {
      for landmark in [sample.thumbTip, sample.indexTip] {
        if let p = viewPoint(landmark, transform: transform) {
          tips.append(UIBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)))
        }
      }
    }
    landmarkLayer.path = tips.cgPath
  }

  // MARK: - Telemetry

  private func emitHandMetricsIfNeeded(now: TimeInterval, sample: HandSample?, point: CGPoint?) {
    guard now - lastHandEvent >= 0.1 else { return }
    lastHandEvent = now
    var payload: [String: Any] = [
      "detected": sample != nil,
      "lowConfidenceHand": lastVisionLowConfidence,
      "gesture": gestureState,
      "latencyMs": lastInferenceLatencyMs,
      "enterRatio": Double(pinchEnterRatio),
      "exitRatio": Double(pinchExitRatio),
      "enterSamples": pinchEnterSamples,
      "exitSamples": pinchExitSamples,
      "enterCount": pinchEnterCount,
      "exitCount": pinchExitCount,
      "selectionRadius": Double(selectionRadius),
      "planeHit": lastPlaneHit,
      "selectable": hoveredObject != nil || grabbedObject != nil,
      "depthSupported": depthSupported,
      "moveMode": "Tabletop plane",
    ]
    if let sample {
      payload["pinchRatio"] = Double(smoothedPinchRatio)
      payload["rawPinchRatio"] = Double(sample.pinchRatio)
      payload["pinchDistance"] = Double(sample.legacyTipDistance)
      payload["handScalePx"] = Double(sample.handScalePx)
      payload["confidence"] = Double(sample.confidence)
      if let depth = sample.depth {
        payload["depthMeters"] = Double(depth.meters)
        payload["depthValid"] = Double(depth.validFraction)
        payload["depthHigh"] = Double(depth.highConfidenceFraction)
        if let reference = grabbedObject ?? hoveredObject ?? objects.values.first {
          let planeY = reference.anchorNode.worldPosition.y
          payload["handHeightCm"] = Double((depth.worldPoint.y - planeY) * 100)
        }
      }
    }
    if let point {
      payload["pointX"] = Double(point.x)
      payload["pointY"] = Double(point.y)
    }
    if let name = lastCandidateName { payload["candidate"] = name }
    if let distance = lastCandidateDistance { payload["candidateDistance"] = Double(distance) }
    channel.invokeMethod("handMetrics", arguments: payload)
  }

  private func sendMetricsIfNeeded(now: TimeInterval) {
    guard now - lastMetricsAt >= 1 else { return }
    let elapsed = max(now - lastMetricsAt, 0.001)
    if lastMetricsAt > 0 {
      measuredHandFPS = Double(inferenceFrameCount) / elapsed
      measuredDetectedFPS = Double(detectedFrameCount) / elapsed
      channel.invokeMethod("performanceMetrics", arguments: [
        "arFps": measuredARFPS,
        "handFps": measuredHandFPS,
        "detectedFps": measuredDetectedFPS,
        "droppedFrames": droppedVisionFrames,
        "trackingFailures": trackingFailureCount,
      ])
    }
    inferenceFrameCount = 0
    detectedFrameCount = 0
    lastMetricsAt = now
  }

  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    renderFrameCount += 1
    if renderWindowStart == 0 { renderWindowStart = time }
    if time - renderWindowStart >= 1 {
      measuredARFPS = Double(renderFrameCount) / (time - renderWindowStart)
      renderFrameCount = 0
      renderWindowStart = time
    }
  }

  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    let value = camera.trackingState == .normal ? "Tracking" : "Limited tracking"
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if value != "Tracking" { self.trackingFailureCount += 1 }
      self.updateStatus(value, self.lastSurface, force: true)
    }
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    DispatchQueue.main.async { [weak self] in
      self?.updateStatus("ARKit error", error.localizedDescription, force: true)
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    DispatchQueue.main.async { [weak self] in
      self?.endInteraction()
      self?.updateStatus("AR interrupted", "Return to Spatial Lab to resume tracking", force: true)
    }
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    guard ARWorldTrackingConfiguration.isSupported else { return }
    session.run(makeConfiguration())
  }

  @objc private func applicationWillResignActive(_ notification: Notification) {
    endInteraction()
    sceneView.session.pause()
  }

  @objc private func applicationDidBecomeActive(_ notification: Notification) {
    guard ARWorldTrackingConfiguration.isSupported else { return }
    sceneView.session.run(makeConfiguration())
  }
}
