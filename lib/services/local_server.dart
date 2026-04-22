import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// A local HTTP server that serves:
/// - `/viewer/**`  - Flutter assets (HTML/JS/CSS for the Vue CAD viewer)
/// - `/dwg`        - DWG file bytes from disk (query param: path)
class LocalServer {
  LocalServer._();
  static final LocalServer instance = LocalServer._();

  HttpServer? _server;
  int _port = 0;

  int get port => _port;
  bool get isRunning => _server != null;

  /// Start the local HTTP server. Safe to call multiple times (no-op if already running).
  Future<void> start() async {
    if (_server != null) return;

    // Extract viewer assets from Flutter bundle to the temp directory once.
    final viewerDir = await _extractViewerAssets();

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware)
        .addHandler(_router(viewerDir));

    _server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0, // port 0 → OS assigns a free port
    );
    _port = _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  // ---------------------------------------------------------------------------
  // Router
  // ---------------------------------------------------------------------------

  Handler _router(Directory viewerDir) {
    return (Request request) async {
      final path = request.url.path;

      // Serve DWG file from disk
      if (path == 'dwg') {
        return _serveDwg(request);
      }

      // Serve viewer static files
      if (path == '' || path == 'viewer' || path.startsWith('viewer/')) {
        return _serveViewer(request, viewerDir);
      }

      return Response.notFound('Not found: $path');
    };
  }

  // ---------------------------------------------------------------------------
  // /dwg handler
  // ---------------------------------------------------------------------------

  Response _serveDwg(Request request) {
    final rawPath = request.url.queryParameters['path'];
    if (rawPath == null || rawPath.isEmpty) {
      return Response.badRequest(body: 'Missing ?path= parameter');
    }

    final file = File(rawPath);
    if (!file.existsSync()) {
      return Response.notFound('File not found: $rawPath');
    }

    final bytes = file.readAsBytesSync();
    final ext = p.extension(rawPath).toLowerCase();
    final mime = ext == '.dxf' ? 'text/plain' : 'application/octet-stream';

    return Response.ok(
      bytes,
      headers: {
        'Content-Type': mime,
        'Content-Length': bytes.length.toString(),
        'Access-Control-Allow-Origin': '*',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Static viewer handler
  // ---------------------------------------------------------------------------

  Response _serveViewer(Request request, Directory viewerDir) {
    // Strip leading "viewer/" prefix, default to index.html
    var relPath = request.url.path;
    if (relPath == '' || relPath == 'viewer' || relPath == 'viewer/') {
      relPath = 'index.html';
    } else if (relPath.startsWith('viewer/')) {
      relPath = relPath.substring('viewer/'.length);
    }

    final file = File(p.join(viewerDir.path, relPath));
    if (!file.existsSync()) {
      return Response.notFound('Asset not found: $relPath');
    }

    final bytes = file.readAsBytesSync();
    return Response.ok(
      bytes,
      headers: {
        'Content-Type': _mimeFor(relPath),
        'Content-Length': bytes.length.toString(),
        // Required for SharedArrayBuffer / WASM threading
        'Cross-Origin-Opener-Policy': 'same-origin',
        'Cross-Origin-Embedder-Policy': 'require-corp',
        'Access-Control-Allow-Origin': '*',
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Asset extraction
  // ---------------------------------------------------------------------------

  /// Extracts bundled `assets/viewer/**` files to the temporary directory.
  /// Subsequent calls return the cached directory immediately.
  Future<Directory> _extractViewerAssets() async {
    final tmpBase = await getTemporaryDirectory();
    final viewerDir = Directory(p.join(tmpBase.path, 'prop_os_cad_viewer'));

    // List of files to extract (must match pubspec.yaml asset declarations)
    const assetFiles = [
      'assets/viewer/index.html',
      'assets/viewer/assets/index.js',
      'assets/viewer/assets/index.css',
      'assets/viewer/assets/libredwg-parser-worker.js',
    ];

    // Version stamp: increment when assetFiles changes to force re-extraction
    const extractionVersion = 'v2';

    // Re-use cached extraction if marker file exists with matching version
    final marker = File(p.join(viewerDir.path, '.extracted'));
    if (marker.existsSync() && marker.readAsStringSync().trim() == extractionVersion) {
      return viewerDir;
    }

    await viewerDir.create(recursive: true);

    for (final assetPath in assetFiles) {
      final ByteData data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      // Relative path within viewer dir
      final rel = assetPath.replaceFirst('assets/viewer/', '');
      final outFile = File(p.join(viewerDir.path, rel));
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(bytes);
    }

    await marker.writeAsString(extractionVersion);
    return viewerDir;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Middleware get _corsMiddleware => (Handler inner) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }
      final response = await inner(request);
      return response.change(headers: _corsHeaders);
    };
  };

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': '*',
  };

  static String _mimeFor(String path) {
    final ext = p.extension(path).toLowerCase();
    const map = {
      '.html': 'text/html; charset=utf-8',
      '.js': 'application/javascript; charset=utf-8',
      '.css': 'text/css; charset=utf-8',
      '.wasm': 'application/wasm',
      '.json': 'application/json; charset=utf-8',
      '.svg': 'image/svg+xml',
      '.png': 'image/png',
      '.ico': 'image/x-icon',
    };
    return map[ext] ?? 'application/octet-stream';
  }
}
