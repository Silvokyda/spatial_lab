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
  double _pinchDistance = 0;
  double _handConfidence = 0;
  double _handLatencyMs = 0;
  double _arFps = 0;
  double _handFps = 0;
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
        setState(() {
          _handDetected = data['detected'] as bool? ?? false;
          _pinchDistance = (data['pinchDistance'] as num?)?.toDouble() ?? 0;
          _handConfidence = (data['confidence'] as num?)?.toDouble() ?? 0;
          _handLatencyMs = (data['latencyMs'] as num?)?.toDouble() ?? 0;
        });
      } else if (call.method == 'performanceMetrics') {
        setState(() {
          _arFps = (data['arFps'] as num?)?.toDouble() ?? 0;
          _handFps = (data['handFps'] as num?)?.toDouble() ?? 0;
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
                        _iconButton(_debug ? Icons.bug_report : Icons.bug_report_outlined, 'Debug overlay', () => setState(() => _debug = !_debug)),
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
                  const Text('Tap a detected surface to place', style: TextStyle(color: Colors.white70, fontSize: 12, shadows: [Shadow(color: Colors.black87, blurRadius: 8)])),
                  const SizedBox(height: 18),
                ],
              ],
            ),
          ),
          if (_debug)
            Positioned(
              left: 16,
              top: 76,
              child: _glass(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'AR tracking: $_tracking\n'
                    'Anchored objects: $_placedCount\n'
                    'Hand: ${_handDetected ? "detected" : _handEnabled ? "searching" : "off"}\n'
                    'Gesture: $_gesture\n'
                    'Pinch distance: ${_pinchDistance.toStringAsFixed(3)}\n'
                    'Confidence: ${_handConfidence.toStringAsFixed(2)}\n'
                    'Inference: ${_handLatencyMs.toStringAsFixed(1)} ms\n'
                    'AR FPS: ${_arFps.toStringAsFixed(1)} | hand FPS: ${_handFps.toStringAsFixed(1)}\n'
                    'Skipped while busy: $_droppedFrames | failures: $_trackingFailures',
                    style: const TextStyle(fontSize: 11, height: 1.5, fontFamily: 'monospace'),
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
