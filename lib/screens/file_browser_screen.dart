import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'viewer_screen.dart';

class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  Directory? _currentDir;
  List<FileSystemEntity> _dwgFiles = [];
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        foregroundColor: Colors.white,
        title: const Text(
          'PropOS CAD',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '选择文件夹',
            onPressed: _pickFolder,
          ),
          IconButton(
            icon: const Icon(Icons.insert_drive_file_outlined),
            tooltip: '直接打开文件',
            onPressed: _pickFile,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.blue),
      );
    }

    if (_currentDir == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.architecture, size: 80, color: Color(0xFF555555)),
            const SizedBox(height: 24),
            const Text(
              '打开文件夹或直接选择 DWG / DXF 文件',
              style: TextStyle(color: Color(0xFF888888), fontSize: 16),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0078D4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                  ),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('选择文件夹'),
                  onPressed: _pickFolder,
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                  ).copyWith(
                    side: WidgetStateProperty.resolveWith<BorderSide?>(
                      (states) {
                        if (states.contains(WidgetState.pressed) ||
                            states.contains(WidgetState.hovered)) {
                          return const BorderSide(color: Color(0xFF888888));
                        }
                        return const BorderSide(color: Color(0xFF555555));
                      },
                    ),
                  ),
                  icon: const Icon(Icons.insert_drive_file_outlined),
                  label: const Text('打开文件'),
                  onPressed: _pickFile,
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (_dwgFiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_off,
              size: 60,
              color: Color(0xFF555555),
            ),
            const SizedBox(height: 16),
            Text(
              '此文件夹中没有 DWG / DXF 文件',
              style: const TextStyle(
                color: Color(0xFF888888),
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _currentDir!.path,
              style: const TextStyle(
                color: Color(0xFF555555),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: _pickFolder,
              child: const Text('选择其他文件夹'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Directory info bar
        Container(
          width: double.infinity,
          color: const Color(0xFF252525),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.folder, size: 16, color: Color(0xFFFFAA00)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _currentDir!.path,
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 13,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              Text(
                '${_dwgFiles.length} 个文件',
                style: const TextStyle(
                  color: Color(0xFF666666),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        // File list
        Expanded(
          child: ListView.separated(
            itemCount: _dwgFiles.length,
            separatorBuilder: (context, index) =>
                const Divider(height: 1, color: Color(0xFF2A2A2A)),
            itemBuilder: (context, i) => _buildFileTile(_dwgFiles[i] as File),
          ),
        ),
      ],
    );
  }

  Widget _buildFileTile(File file) {
    final name = p.basename(file.path);
    final ext = p.extension(file.path).toUpperCase();
    final stat = file.statSync();
    final size = _formatSize(stat.size);
    final modified = _formatDate(stat.modified);
    final isDwg = ext == '.DWG';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: isDwg
              ? const Color(0xFF1A3A5C)
              : const Color(0xFF1A4A2E),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Text(
            ext.replaceAll('.', ''),
            style: TextStyle(
              color: isDwg ? const Color(0xFF4FC3F7) : const Color(0xFF81C784),
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$size  ·  $modified',
        style: const TextStyle(
          color: Color(0xFF888888),
          fontSize: 12,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right,
        color: Color(0xFF555555),
      ),
      hoverColor: const Color(0x1A0078D4),
      onTap: () => _openFile(file.path),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _pickFolder() async {
    setState(() => _loading = true);
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择包含 DWG 文件的文件夹',
      );
      if (dirPath != null && mounted) {
        await _loadFilesFromDir(Directory(dirPath));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickFile() async {
    setState(() => _loading = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['dwg', 'dxf', 'DWG', 'DXF'],
        dialogTitle: '选择 CAD 文件',
      );
      if (result != null && result.files.single.path != null && mounted) {
        _openFile(result.files.single.path!);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFilesFromDir(Directory dir) async {
    final entities = dir.listSync(followLinks: false);
    final dwg = entities
        .whereType<File>()
        .where((f) {
          final ext = p.extension(f.path).toLowerCase();
          return ext == '.dwg' || ext == '.dxf';
        })
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    setState(() {
      _currentDir = dir;
      _dwgFiles = dwg;
    });
  }

  void _openFile(String filePath) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ViewerScreen(filePath: filePath),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}'
        '-${dt.day.toString().padLeft(2, '0')}';
  }
}
