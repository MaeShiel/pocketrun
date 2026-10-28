import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

// PocketRun demo: a live camera preview and text-to-speech, two plugins preloaded in PocketRun.
void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'hello_pocketrun',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _tts = FlutterTts();
  CameraController? _camera;
  String _status = 'Starting camera...';

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return setState(() => _status = 'No camera found');
      final controller = CameraController(cameras.first, ResolutionPreset.medium, enableAudio: false);
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _camera = controller;
        _status = 'Camera: ${cameras.length} found';
      });
    } catch (e) {
      setState(() => _status = 'Camera error: $e');
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Scaffold(
      appBar: AppBar(title: const Text('Hello PocketRun')),
      body: Column(
        children: [
          Expanded(
            child: camera == null
                ? Center(child: Text(_status))
                : ClipRect(child: Center(child: CameraPreview(camera))),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(_status),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _tts.speak('Hello from PocketRun'),
                  icon: const Icon(Icons.record_voice_over),
                  label: const Text('Speak'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
