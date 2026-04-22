import 'package:flutter/material.dart';
import 'screens/file_browser_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PropOsCadApp());
}

class PropOsCadApp extends StatelessWidget {
  const PropOsCadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PropOS CAD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0078D4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const FileBrowserScreen(),
    );
  }
}


