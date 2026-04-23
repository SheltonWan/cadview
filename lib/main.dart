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
        // ── IconButton：蓝色 hover / pressed 反馈 ──────────────────────────
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>(
              (states) {
                if (states.contains(WidgetState.pressed)) {
                  return const Color(0x4D0078D4); // 30% 蓝
                }
                if (states.contains(WidgetState.hovered)) {
                  return const Color(0x260078D4); // 15% 蓝
                }
                if (states.contains(WidgetState.focused)) {
                  return const Color(0x330078D4); // 20% 蓝
                }
                return null;
              },
            ),
          ),
        ),
        // ── ElevatedButton：白色叠加高亮 ───────────────────────────────────
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>(
              (states) {
                if (states.contains(WidgetState.pressed)) {
                  return const Color(0x33FFFFFF); // 20% 白
                }
                if (states.contains(WidgetState.hovered)) {
                  return const Color(0x1AFFFFFF); // 10% 白
                }
                return null;
              },
            ),
          ),
        ),
        // ── OutlinedButton：白色叠加高亮 ───────────────────────────────────
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            overlayColor: WidgetStateProperty.resolveWith<Color?>(
              (states) {
                if (states.contains(WidgetState.pressed)) {
                  return const Color(0x29FFFFFF); // 16% 白
                }
                if (states.contains(WidgetState.hovered)) {
                  return const Color(0x14FFFFFF); // 8% 白
                }
                return null;
              },
            ),
          ),
        ),
        // ── TextButton：蓝色前景 + 叠加高亮 ───────────────────────────────
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith<Color?>(
              (states) {
                if (states.contains(WidgetState.pressed)) {
                  return const Color(0xFF81D4FA); // 按下变亮
                }
                return const Color(0xFF4FC3F7); // 默认浅蓝
              },
            ),
            overlayColor: WidgetStateProperty.resolveWith<Color?>(
              (states) {
                if (states.contains(WidgetState.pressed)) {
                  return const Color(0x334FC3F7); // 20% 浅蓝
                }
                if (states.contains(WidgetState.hovered)) {
                  return const Color(0x1A4FC3F7); // 10% 浅蓝
                }
                return null;
              },
            ),
          ),
        ),
        // ── ListTile：蓝色选中 / 悬停高亮 ──────────────────────────────────
        listTileTheme: const ListTileThemeData(
          selectedColor: Color(0xFF4FC3F7),
          selectedTileColor: Color(0x1A0078D4),
        ),
      ),
      home: const FileBrowserScreen(),
    );
  }
}


