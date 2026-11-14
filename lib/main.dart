import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

void main() => runApp(const SpatialLabApp());

class SpatialLabApp extends StatelessWidget {
  const SpatialLabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Spatial Lab',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF69E0C2),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const SpatialLabScreen(),
      );
}

class SpatialLabScreen extends StatefulWidget {
  const SpatialLabScreen({super.key});

  @override
  State<SpatialLabScreen> createState() => _SpatialLabScreenState();
}

class _SpatialLabScreenState extends State<SpatialLabScreen> {
  static const _objects = ['Beaker', 'Cube', 'Sphere', 'Test tube'];
  int _selectedObject = 0;
  String _tracking = 'Starting AR';
  String _surface = 'Move your phone slowly to find a desk';
  int _placedCount = 0;
  bool _debug = false;
  bool _handEnabled = false;
  bool _handDetected = false;
  String _gesture = 'Hand tracking off';
  bool _lowConfidenceHand = false;
  double _pinchDistance = 0;
  double? _pinchRatio;
  double? _rawPinchRatio;
  double? _handScalePx;
  double _enterRatio = 0;
  double _exitRatio = 0;
  int _enterCount = 0;
  int _exitCount = 0;
  int _enterSamples = 0;
  int _exitSamples = 0;
  double _handConfidence = 0;
  double _handLatencyMs = 0;
  double? _pointX;
  double? _pointY;
  String? _candidate;
  double? _candidateDistance;
  double _selectionRadius = 0;
  bool _selectable = false;
  bool _planeHit = false;
  String _moveMode = '';
  bool _depthSupported = false;
  double? _depthMeters;
  double? _depthValid;
  double? _depthHigh;
  double? _handHeightCm;
  double _arFps = 0;
  double _handFps = 0;
  double _detectedFps = 0;
  int _droppedFrames = 0;
  int _trackingFailures = 0;
  String _deviceModel = 'Android phone';
  MethodChannel? _arChannel;

  bool get _arUnavailable => _tracking == 'ARCore unavailable';

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('spatial_lab/ar_view_$id');
    _arChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      final arguments = call.arguments;
      final data = arguments is Map
          ? Map<Object?, Object?>.from(arguments)
          : <Object?, Object?>{};
      if (call.method == 'status') {
        _applyArStatus(data);
      } else if (call.method == 'handMetrics') {
        double? number(String key) => (data[key] as num?)?.toDouble();
        setState(() {
          _handDetected = data['detected'] as bool? ?? false;
          _lowConfidenceHand = data['lowConfidenceHand'] as bool? ?? false;
          _gesture = data['gesture'] as String? ?? _gesture;
          _pinchDistance = number('pinchDistance') ?? _pinchDistance;
          _pinchRatio = number('pinchRatio');
          _rawPinchRatio = number('rawPinchRatio');
          _handScalePx = number('handScalePx');
          _enterRatio = number('enterRatio') ?? _enterRatio;
          _exitRatio = number('exitRatio') ?? _exitRatio;
          _enterCount = (data['enterCount'] as num?)?.toInt() ?? 0;
          _exitCount = (data['exitCount'] as num?)?.toInt() ?? 0;
          _enterSamples = (data['enterSamples'] as num?)?.toInt() ?? _enterSamples;
          _exitSamples = (data['exitSamples'] as num?)?.toInt() ?? _exitSamples;
          _handConfidence = number('confidence') ?? 0;
          // Latency is the last inference, reported whether or not a hand was found.
          _handLatencyMs = number('latencyMs') ?? _handLatencyMs;
          _pointX = number('pointX');
          _pointY = number('pointY');
          _candidate = data['candidate'] as String?;
          _candidateDistance = number('candidateDistance');
          _selectionRadius = number('selectionRadius') ?? _selectionRadius;
          _selectable = data['selectable'] as bool? ?? false;
          _planeHit = data['planeHit'] as bool? ?? false;
          _moveMode = data['moveMode'] as String? ?? _moveMode;
          _depthSupported = data['depthSupported'] as bool? ?? _depthSupported;
          _depthMeters = number('depthMeters');
          _depthValid = number('depthValid');
          _depthHigh = number('depthHigh');
          _handHeightCm = number('handHeightCm');
        });
      } else if (call.method == 'performanceMetrics') {
        setState(() {
          _arFps = (data['arFps'] as num?)?.toDouble() ?? 0;
          _handFps = (data['handFps'] as num?)?.toDouble() ?? 0;
          _detectedFps = (data['detectedFps'] as num?)?.toDouble() ?? 0;
          _droppedFrames = (data['droppedFrames'] as num?)?.toInt() ?? 0;
          _trackingFailures = (data['trackingFailures'] as num?)?.toInt() ?? 0;
        });
      } else if (call.method == 'gestureState') {
        setState(() => _gesture = call.arguments as String? ?? _gesture);
      }
    });
    channel.invokeMapMethod<Object?, Object?>('getState').then((data) {
      if (mounted && data != null) _applyArStatus(data);
    });
  }

  Widget _buildArView() {
    if (Platform.isAndroid) {
      return PlatformViewLink(
        viewType: 'spatial_lab/ar_view',
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        ),
        onCreatePlatformView: (params) {
          return PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 'spatial_lab/ar_view',
            layoutDirection: TextDirection.ltr,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
            ..addOnPlatformViewCreatedListener((id) {
              _onPlatformViewCreated(id);
              params.onPlatformViewCreated(id);
            })
            ..create();
        },
      );
    }
    if (Platform.isIOS) {
      return UiKitView(
        viewType: 'spatial_lab/ar_view',
        onPlatformViewCreated: _onPlatformViewCreated,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return const ColoredBox(color: Colors.black);
  }

  void _applyArStatus(Map<Object?, Object?> data) {
    setState(() {
      _tracking = data['tracking'] as String? ?? _tracking;
      _surface = data['surface'] as String? ?? _surface;
      _placedCount = data['placedCount'] as int? ?? _placedCount;
      _deviceModel = data['deviceModel'] as String? ?? _deviceModel;
    });
  }

  Future<void> _selectObject(int index) async {
    setState(() => _selectedObject = index);
    await _arChannel?.invokeMethod<void>('addObject', {'type': _objects[index]});
  }

  Future<void> _reset() async {
    await _arChannel?.invokeMethod<void>('resetScene');
  }

  Future<void> _toggleHandTracking() async {
    setState(() {
      _handEnabled = !_handEnabled;
      _gesture = _handEnabled ? 'Waiting for hand' : 'Hand tracking off';
      if (!_handEnabled) _handDetected = false;
    });
    await _arChannel?.invokeMethod<void>('setHandTracking', {'enabled': _handEnabled});
  }

  Future<void> _toggleDebug() async {
    setState(() => _debug = !_debug);
    // Native side draws the selection radius and fingertip landmarks only while this is on.
    if (Platform.isIOS) {
      await _arChannel?.invokeMethod<void>('setDebugOverlay', {'enabled': _debug});
    }
  }

  static Color _gestureColor(String gesture) => switch (gesture) {
        'Grabbing' => const Color(0xFF69E0C2),
        'Pinching' => const Color(0xFFFFC56D),
        'Releasing' => Colors.white70,
        'Hand lost' || 'Tracking lost' => const Color(0xFFFF6B6B),
        _ => Colors.white,
      };

  String get _gestureHint => switch (_gesture) {
        'Hovering' when _selectable => 'Hovering · pinch to grab',
        'Hovering' => 'Hovering · move closer to an object',
        'Pinching' => 'Pinching · nothing selectable',
        'Grabbing' => 'Grabbing · open fingers to release',
        'Releasing' => 'Released',
        'Hand lost' => 'Hand lost · object left in place',
        'Tracking lost' => 'AR tracking lost · holding still',
        _ => _gesture,
      };

  String _fmt(double? value, [int digits = 2]) => value == null ? '–' : value.toStringAsFixed(digits);

  String get _debugText {
    final ratio = _pinchRatio == null
        ? 'Pinch ratio: – (enter <${_fmt(_enterRatio)}, exit >${_fmt(_exitRatio)})'
        : 'Pinch ratio: ${_fmt(_pinchRatio)} raw ${_fmt(_rawPinchRatio)} (enter <${_fmt(_enterRatio)}, exit >${_fmt(_exitRatio)})';
    final candidate = _candidate == null
        ? 'Candidate: none'
        : 'Candidate: $_candidate ${_fmt(_candidateDistance, 0)} px (radius ${_fmt(_selectionRadius, 0)}) '
            '${_selectable ? "SELECTABLE" : "out of range"}';
    final depth = !_depthSupported
        ? 'Depth: sceneDepth unsupported'
        : _depthMeters == null
            ? 'Depth: LiDAR, no valid sample at fingertips'
            : 'Depth: LiDAR ${_fmt(_depthMeters)} m, valid ${_fmt((_depthValid ?? 0) * 100, 0)}%, '
                'high ${_fmt((_depthHigh ?? 0) * 100, 0)}%\n'
                '  hand above surface: ${_handHeightCm == null ? "–" : "${_fmt(_handHeightCm, 1)} cm"} (diagnostic only)';
    return 'AR tracking: $_tracking | anchored: $_placedCount\n'
        'Hand: ${_handDetected ? "detected" : _handEnabled ? (_lowConfidenceHand ? "low confidence" : "searching") : "off"}'
        ' | conf ${_fmt(_handConfidence)}\n'
        'Gesture: $_gesture\n'
        '$ratio\n'
        '  enter $_enterCount/$_enterSamples, exit $_exitCount/$_exitSamples | '
        'tip gap ${_fmt(_pinchDistance, 3)} (old metric) | hand ${_fmt(_handScalePx, 0)} px\n'
        'Point: ${_pointX == null ? "–" : "(${_fmt(_pointX, 0)}, ${_fmt(_pointY, 0)})"}\n'
        '$candidate\n'
        'Plane ray: ${_planeHit ? "hit" : "miss"} | move: ${_moveMode.isEmpty ? "–" : _moveMode}\n'
        '$depth\n'
        'Inference: ${_fmt(_handLatencyMs, 1)} ms | hand FPS ${_fmt(_handFps, 1)} (detected ${_fmt(_detectedFps, 1)})\n'
        'AR FPS: ${_fmt(_arFps, 1)} | skipped while busy: $_droppedFrames | AR failures: $_trackingFailures';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          _buildArView(),
          if (!_arUnavailable) SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      _glass(
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.blur_on_rounded, size: 18, color: Color(0xFF69E0C2)),
                              SizedBox(width: 8),
                              Text('SPATIAL LAB', style: TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (!_arUnavailable) ...[
                        _iconButton(Icons.restart_alt_rounded, 'Reset scene', _reset),
                        const SizedBox(width: 7),
                        _iconButton(
                          _handEnabled ? Icons.back_hand_rounded : Icons.back_hand_outlined,
                          _handEnabled ? 'Turn hand tracking off' : 'Turn hand tracking on',
                          _toggleHandTracking,
                          active: _handEnabled,
                        ),
                        const SizedBox(width: 7),
                        _iconButton(_debug ? Icons.bug_report : Icons.bug_report_outlined, 'Debug overlay', _toggleDebug),
                      ],
                    ],
                  ),
                ),
                if (_arUnavailable) ...[
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: _glass(
                          child: Padding(
                            padding: const EdgeInsets.all(22),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFC56D), size: 25),
                                const SizedBox(height: 13),
                                const Text('ARCore isn’t available on this phone', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 9),
                                Text(
                                  'Spatial Lab needs a phone certified for Google Play Services for AR. This $_deviceModel is not currently supported, so its camera scene cannot start.',
                                  style: TextStyle(fontSize: 14, height: 1.45, color: Colors.white70),
                                ),
                                const SizedBox(height: 16),
                                const Text('Use an ARCore-supported Android phone to try the spatial prototype.', style: TextStyle(fontSize: 13, height: 1.4, color: Color(0xFF69E0C2))),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  _glass(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 8, color: _tracking == 'Tracking' ? const Color(0xFF69E0C2) : const Color(0xFFFFC56D)),
                          const SizedBox(width: 7),
                          Text(_tracking, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                  if (_handEnabled) ...[
                    const SizedBox(height: 8),
                    _glass(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.back_hand_rounded, size: 13, color: _gestureColor(_gesture)),
                            const SizedBox(width: 7),
                            Text(_gestureHint, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _gestureColor(_gesture))),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  _glass(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.center_focus_weak_rounded, size: 17, color: Color(0xFF69E0C2)),
                          const SizedBox(width: 8),
                          Text(_surface, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  _glass(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < _objects.length; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: _objectButton(i),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _handEnabled ? 'Tap a surface to place · pinch near an object to move it' : 'Tap a detected surface to place',
                    style: const TextStyle(color: Colors.white70, fontSize: 12, shadows: [Shadow(color: Colors.black87, blurRadius: 8)]),
                  ),
                  const SizedBox(height: 18),
                ],
              ],
            ),
          ),
          if (_debug)
            Positioned(
              left: 16,
              right: 16,
              top: 120,
              child: IgnorePointer(
                child: _glass(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      _debugText,
                      style: const TextStyle(fontSize: 10, height: 1.45, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _objectButton(int index) {
    final active = index == _selectedObject;
    const icons = [Icons.science_outlined, Icons.crop_square_rounded, Icons.circle_outlined, Icons.biotech_outlined];
    return Material(
      color: active ? const Color(0xFF69E0C2).withValues(alpha: 0.18) : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _selectObject(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icons[index], size: 18, color: active ? const Color(0xFF69E0C2) : Colors.white70),
              const SizedBox(width: 6),
              Text(_objects[index], style: TextStyle(fontSize: 11, fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, String label, VoidCallback onPressed, {bool active = false}) =>
      _glass(child: IconButton(onPressed: onPressed, tooltip: label, visualDensity: VisualDensity.compact, color: active ? const Color(0xFF69E0C2) : null, icon: Icon(icon, size: 19)));

  Widget _glass({required Widget child}) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE8172022),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 18, offset: Offset(0, 5))],
        ),
        child: child,
      );
}
