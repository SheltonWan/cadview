import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter/webview_flutter.dart';
import '../services/local_server.dart';

class ViewerScreen extends StatefulWidget {
  final String filePath;

  const ViewerScreen({super.key, required this.filePath});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  WebViewController? _controller;
  bool _viewerReady = false;
  bool _serverError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initViewer();
  }

  Future<void> _initViewer() async {
    // Ensure the local HTTP server is running
    try {
      await LocalServer.instance.start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _serverError = true;
          _errorMessage = '无法启动本地服务: $e';
        });
      }
      return;
    }

    final port = LocalServer.instance.port;
    final viewerUrl = 'http://127.0.0.1:$port/viewer/';

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            // Page loaded → load the DWG file
            _loadFile();
          },
          onWebResourceError: (error) {
            if (mounted) {
              setState(() {
                _errorMessage = '页面加载错误: ${error.description}';
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(viewerUrl));

    if (mounted) {
      setState(() => _controller = controller);
    }
  }

  void _onBridgeMessage(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'ready') {
        // Vue app is mounted → load the file
        setState(() => _viewerReady = true);
        _loadFile();
      } else if (type == 'error') {
        final msg = data['payload']?.toString() ?? '未知错误';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('CAD 错误: $msg'),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      }
    } catch (_) {
      // Ignore malformed messages
    }
  }

  void _loadFile() {
    final controller = _controller;
    if (controller == null) return;

    final port = LocalServer.instance.port;
    final encodedPath = Uri.encodeComponent(widget.filePath);
    final fileUrl = 'http://127.0.0.1:$port/dwg?path=$encodedPath';

    controller.runJavaScript(
      "if (window.cadViewer) { window.cadViewer.loadFile('$fileUrl'); }",
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(widget.filePath);

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            const SizedBox(width: 4),
            const Icon(Icons.architecture, size: 18, color: Color(0xFF4FC3F7)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName,
                style: const TextStyle(fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // Reload button
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新加载',
            onPressed: _viewerReady ? _loadFile : null,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_serverError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 60, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? '启动服务器失败',
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_controller == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.blue),
            SizedBox(height: 16),
            Text(
              '正在启动查看器…',
              style: TextStyle(color: Color(0xFF888888)),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        // Subtle loading overlay until viewer signals ready
        if (!_viewerReady)
          Container(
            color: const Color(0xFF1E1E1E),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF4FC3F7)),
                  SizedBox(height: 16),
                  Text(
                    '正在加载 CAD 文件…',
                    style: TextStyle(color: Color(0xFF888888)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
