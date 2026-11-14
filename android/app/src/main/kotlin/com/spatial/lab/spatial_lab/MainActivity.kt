package com.spatial.lab.spatial_lab

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.StandardMessageCodec
import com.spatial.lab.spatial_lab.ar.SpatialArViewFactory

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "spatial_lab/ar_view",
            SpatialArViewFactory(flutterEngine.dartExecutor.binaryMessenger, StandardMessageCodec.INSTANCE),
        )
    }
}
