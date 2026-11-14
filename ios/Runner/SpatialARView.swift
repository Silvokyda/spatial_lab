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

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
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
  var grabOffset = SCNVector3Zero
  var highlightNode: SCNNode?

  init(anchor: ARAnchor, anchorNode: SCNNode, contentNode: SCNNode, kind: String) {
    self.anchor = anchor
    self.anchorNode = anchorNode
    self.contentNode = contentNode
    self.kind = kind
  }
}

private struct HandSample {
  let x: CGFloat
  let y: CGFloat
  let pinchDistance: CGFloat
  let confidence: Float
  let rollDegrees: Float
  let latencyMs: Double
  let timestamp: TimeInterval
  let pinching: Bool
}

final class SpatialARPlatformView: NSObject, FlutterPlatformView, ARSCNViewDelegate {
  private let sceneView: ARSCNView
  private let channel: FlutterMethodChannel
  private let handQueue = DispatchQueue(label: "spatial_lab.vision_hand", qos: .userInitiated)
  private let handLock = NSLock()
  private var latestHand: HandSample?
  private var handDetectionEnabled = false
  private var visionBusy = false
  private var lastVisionStart: TimeInterval = 0
  private var lastHandSeen: TimeInterval = 0
  private var lastHandEvent: TimeInterval = 0
  private var smoothedPoint = CGPoint.zero
  private var hasSmoothedPoint = false
  private var pinchEnterCount = 0
  private var pinchExitCount = 0
  private var lastGestureSampleTimestamp: TimeInterval = 0
  private var isPinching = false
  private var grabbedObject: PlacedARObject?
  private var gestureState = "Idle"
  private var releaseUntil: TimeInterval = 0
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
  private var measuredHandFPS = 0.0
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

    let tap = UITapGestureRecognizer(target: self, action: #selector(placeObject(_:)))
    sceneView.addGestureRecognizer(tap)

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    if ARWorldTrackingConfiguration.isSupported {
      let configuration = ARWorldTrackingConfiguration()
      configuration.planeDetection = [.horizontal]
      configuration.isLightEstimationEnabled = true
      sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
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

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getState":
      result(statePayload())
    case "addObject":
      let arguments = call.arguments as? [String: Any]
      activeKind = arguments?["type"] as? String ?? "Beaker"
      result(nil)
    case "resetScene":
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
      handLock.lock()
      latestHand = nil
      handLock.unlock()
      isPinching = false
      grabbedObject = nil
      pinchEnterCount = 0
      pinchExitCount = 0
      setGestureState(handDetectionEnabled ? "Searching" : "Idle")
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
    anchorNode.addChildNode(content)
    return PlacedARObject(anchor: anchor, anchorNode: anchorNode, contentNode: content, kind: kind)
  }

  @objc private func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    scheduleVisionIfNeeded(now: now)
    updateTracking(now: now)
    updateManipulation(now: now)
    sendMetricsIfNeeded(now: now)
  }

  private func scheduleVisionIfNeeded(now: TimeInterval) {
    guard handDetectionEnabled, now - lastVisionStart >= 0.10 else { return }
    guard !visionBusy else {
      droppedVisionFrames += 1
      lastVisionStart = now
      return
    }
    guard let frame = sceneView.session.currentFrame else { return }
    lastVisionStart = now
    visionBusy = true
    let pixelBuffer = frame.capturedImage
    let orientation = CGImagePropertyOrientation.right
    handQueue.async { [weak self] in
      guard let self else { return }
      let started = CACurrentMediaTime()
      let request = VNDetectHumanHandPoseRequest()
      request.maximumHandCount = 1
      var sample: HandSample?
      do {
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
        if let observation = request.results?.first,
           let thumb = try? observation.recognizedPoint(.thumbTip),
           let index = try? observation.recognizedPoint(.indexTip),
           let wrist = try? observation.recognizedPoint(.wrist),
           let indexMCP = try? observation.recognizedPoint(.indexMCP),
           let littleMCP = try? observation.recognizedPoint(.littleMCP),
           min(thumb.confidence, min(index.confidence, wrist.confidence)) >= 0.25 {
          let dx = thumb.location.x - index.location.x
          let dy = thumb.location.y - index.location.y
          let pinchDistance = hypot(dx, dy)
          let palmX = (thumb.location.x + index.location.x) * 0.5
          let palmY = (thumb.location.y + index.location.y) * 0.5
          let palmDX = indexMCP.location.x - littleMCP.location.x
          let palmDY = indexMCP.location.y - littleMCP.location.y
          sample = HandSample(
            x: palmX,
            y: palmY,
            pinchDistance: pinchDistance,
            confidence: min(thumb.confidence, index.confidence),
            rollDegrees: Float(atan2(palmDY, palmDX) * 180 / .pi),
            latencyMs: (CACurrentMediaTime() - started) * 1_000,
            timestamp: CACurrentMediaTime(),
            pinching: pinchDistance < 0.055
          )
        }
      } catch {
        NSLog("Spatial Lab Vision hand request failed: %@", error.localizedDescription)
      }
      DispatchQueue.main.async {
        self.visionBusy = false
        self.handLock.lock()
        self.latestHand = sample
        self.handLock.unlock()
        if let sample {
          self.lastHandSeen = sample.timestamp
          self.emitHandMetrics(sample)
        } else if CACurrentMediaTime() - self.lastHandEvent > 0.2 {
          self.lastHandEvent = CACurrentMediaTime()
          self.channel.invokeMethod("handMetrics", arguments: ["detected": false, "gesture": "Hand lost"])
        }
      }
    }
  }

  private func updateTracking(now: TimeInterval) {
    guard now - lastStatusAt >= 0.35 else { return }
    lastStatusAt = now
    guard let frame = sceneView.session.currentFrame else { return }
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

  private func imagePointToView(_ hand: HandSample) -> CGPoint? {
    guard let frame = sceneView.session.currentFrame else { return nil }
    let orientation = sceneView.window?.windowScene?.interfaceOrientation ?? .portrait
    let transform = frame.displayTransform(for: orientation, viewportSize: sceneView.bounds.size)
    let normalized = CGPoint(x: hand.x, y: hand.y).applying(transform)
    guard normalized.x.isFinite, normalized.y.isFinite else { return nil }
    let point = CGPoint(x: normalized.x * sceneView.bounds.width, y: (1 - normalized.y) * sceneView.bounds.height)
    if hasSmoothedPoint {
      smoothedPoint = CGPoint(
        x: smoothedPoint.x * 0.65 + point.x * 0.35,
        y: smoothedPoint.y * 0.65 + point.y * 0.35
      )
    } else {
      smoothedPoint = point
      hasSmoothedPoint = true
    }
    return smoothedPoint
  }

  private func updateManipulation(now: TimeInterval) {
    guard handDetectionEnabled else { return }
    handLock.lock()
    let sample = latestHand
    handLock.unlock()

    guard let sample, now - sample.timestamp < 0.35, let screenPoint = imagePointToView(sample) else {
      hasSmoothedPoint = false
      if grabbedObject != nil && now - lastHandSeen > 0.35 {
        releaseGrab()
        setGestureState("Hand lost")
      } else if now - lastHandSeen > 0.35 {
        setGestureState("Searching")
      }
      return
    }

    if sample.timestamp != lastGestureSampleTimestamp {
      lastGestureSampleTimestamp = sample.timestamp
      let isInsidePinch = sample.pinchDistance < 0.055
      let isOutsidePinch = sample.pinchDistance > 0.078
      pinchEnterCount = isInsidePinch ? pinchEnterCount + 1 : 0
      pinchExitCount = isOutsidePinch ? pinchExitCount + 1 : 0

      if !isPinching && pinchEnterCount >= 2 {
        isPinching = true
        beginGrab(at: screenPoint)
      } else if isPinching && pinchExitCount >= 2 {
        isPinching = false
        releaseGrab()
        releaseUntil = now + 0.15
      }
    }

    if isPinching, let held = grabbedObject {
      moveGrabbedObject(held, to: screenPoint, rollDegrees: sample.rollDegrees)
      setGestureState("Grabbing")
    } else if isPinching {
      setGestureState("Pinching")
    } else if now < releaseUntil {
      setGestureState("Releasing")
    } else {
      setGestureState("Hovering")
    }

    if now - lastHandEvent >= 0.1 {
      lastHandEvent = now
      channel.invokeMethod("handMetrics", arguments: [
        "detected": true,
        "gesture": gestureState,
        "pinchDistance": Double(sample.pinchDistance),
        "confidence": Double(sample.confidence),
        "latencyMs": sample.latencyMs,
        "x": Double(sample.x),
        "y": Double(sample.y),
      ])
    }
  }

  private func beginGrab(at point: CGPoint) {
    guard let candidate = objects.values.min(by: { distance($0, to: point) < distance($1, to: point) }),
          distance(candidate, to: point) <= 92,
          let hit = planeHit(at: point) else { return }
    let worldPosition = candidate.contentNode.presentation.worldPosition
    candidate.grabOffset = SCNVector3(worldPosition.x - hit.x, 0, worldPosition.z - hit.z)
    grabbedObject = candidate
    let ring = SCNTorus(ringRadius: 0.052, pipeRadius: 0.002)
    ring.firstMaterial?.diffuse.contents = UIColor(red: 0.45, green: 1, blue: 0.88, alpha: 0.9)
    ring.firstMaterial?.lightingModel = .constant
    let highlight = SCNNode(geometry: ring)
    highlight.eulerAngles.x = .pi / 2
    highlight.position.y = 0.004
    candidate.anchorNode.addChildNode(highlight)
    candidate.highlightNode = highlight
  }

  private func moveGrabbedObject(_ object: PlacedARObject, to point: CGPoint, rollDegrees: Float) {
    guard let hit = planeHit(at: point) else { return }
    let localHit = object.anchorNode.convertPosition(hit, from: sceneView.scene.rootNode)
    object.contentNode.position = SCNVector3(
      localHit.x + object.grabOffset.x,
      0,
      localHit.z + object.grabOffset.z
    )
    // The palm line provides a rough in-plane rotation cue, not metric wrist pose.
    object.contentNode.eulerAngles.y = -rollDegrees * .pi / 180
  }

  private func planeHit(at point: CGPoint) -> SCNVector3? {
    guard let query = sceneView.raycastQuery(from: point, allowing: .existingPlaneInfinite, alignment: .horizontal),
          let result = sceneView.session.raycast(query).first else { return nil }
    return SCNVector3(result.worldTransform.columns.3.x, result.worldTransform.columns.3.y, result.worldTransform.columns.3.z)
  }

  private func distance(_ object: PlacedARObject, to point: CGPoint) -> CGFloat {
    let projected = sceneView.projectPoint(objectCenterWorldPosition(object))
    return hypot(CGFloat(projected.x) - point.x, CGFloat(projected.y) - point.y)
  }

  private func objectCenterWorldPosition(_ object: PlacedARObject) -> SCNVector3 {
    object.contentNode.presentation.convertPosition(SCNVector3(0, 0.05, 0), to: sceneView.scene.rootNode)
  }

  private func releaseGrab() {
    grabbedObject?.highlightNode?.removeFromParentNode()
    grabbedObject?.highlightNode = nil
    grabbedObject = nil
    pinchEnterCount = 0
    pinchExitCount = 0
  }

  private func setGestureState(_ state: String) {
    guard state != gestureState else { return }
    gestureState = state
    channel.invokeMethod("gestureState", arguments: state)
  }

  private func emitHandMetrics(_ sample: HandSample) {
    channel.invokeMethod("handMetrics", arguments: [
      "detected": true,
      "gesture": sample.pinching ? "Pinching" : "Hand detected",
      "pinchDistance": Double(sample.pinchDistance),
      "confidence": Double(sample.confidence),
      "latencyMs": sample.latencyMs,
      "x": Double(sample.x),
      "y": Double(sample.y),
    ])
  }

  private func sendMetricsIfNeeded(now: TimeInterval) {
    guard now - lastMetricsAt >= 1 else { return }
    let elapsed = max(now - lastMetricsAt, 0.001)
    if lastMetricsAt > 0 {
      measuredHandFPS = Double(inferenceFrameCount) / elapsed
      channel.invokeMethod("performanceMetrics", arguments: [
        "arFps": measuredARFPS,
        "handFps": measuredHandFPS,
        "droppedFrames": droppedVisionFrames,
        "trackingFailures": trackingFailureCount,
      ])
    }
    inferenceFrameCount = 0
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
      self?.updateStatus("AR interrupted", "Return to Spatial Lab to resume tracking", force: true)
    }
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    guard ARWorldTrackingConfiguration.isSupported else { return }
    let configuration = ARWorldTrackingConfiguration()
    configuration.planeDetection = [.horizontal]
    configuration.isLightEstimationEnabled = true
    session.run(configuration)
  }

  @objc private func applicationWillResignActive(_ notification: Notification) {
    sceneView.session.pause()
  }

  @objc private func applicationDidBecomeActive(_ notification: Notification) {
    guard ARWorldTrackingConfiguration.isSupported else { return }
    let configuration = ARWorldTrackingConfiguration()
    configuration.planeDetection = [.horizontal]
    configuration.isLightEstimationEnabled = true
    sceneView.session.run(configuration)
  }
}
