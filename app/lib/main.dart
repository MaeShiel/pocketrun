import 'package:flutter/material.dart';

// PocketRun's own screen. When `pocketrun start` connects from the PC, the project's code
// replaces this one (hot restart), so the project runs here instead.
void main() {
  runApp(const PocketRunApp());
}

class PocketRunApp extends StatelessWidget {
  const PocketRunApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketRun',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const _WaitingScreen(),
    );
  }
}

class _WaitingScreen extends StatelessWidget {
  const _WaitingScreen();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.phone_android, size: 72),
              const SizedBox(height: 16),
              Text('PocketRun', style: text.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Waiting for a project.\nRun "pocketrun start" in your project folder on the PC.',
                textAlign: TextAlign.center,
                style: text.bodyLarge,
              ),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
