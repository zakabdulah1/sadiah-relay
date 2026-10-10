import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class Tunnel {
  Tunnel(this.serverId, this.socket);
  final String serverId;
  final WebSocket socket;
  final Map<String, Completer<Map<String, dynamic>>> pending = {};
}

final Map<String, Tunnel> tunnels = {};
final Random secureRandom = Random.secure();
const int maxRequestBodyBytes = 2 * 1024 * 1024;
const int maxPendingPerTunnel = 64;
final RegExp serverIdPattern = RegExp(r'^[A-Za-z0-9_-]{12,96}$');

Map<String, String> loadSecrets() {
  final raw = Platform.environment['SADIAH_TUNNELS_JSON'] ?? '{}';
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw StateError('SADIAH_TUNNELS_JSON must be a JSON object');
  final secrets = decoded.map((key, value) => MapEntry('$key', '$value'));
  for (final entry in secrets.entries) {
    if (!serverIdPattern.hasMatch(entry.key)) {
      throw StateError('Invalid server id in SADIAH_TUNNELS_JSON');
    }
    if (entry.value.length < 32) {
      throw StateError('Tunnel secrets must be at least 32 characters');
    }
  }
  return secrets;
}

String bearer(HttpRequest request) {
  final value = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
  return value.startsWith('Bearer ') ? value.substring(7) : '';
}

Future<void> jsonResponse(HttpResponse response, int status, Object body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.headers.set('Cache-Control', 'no-store');
  response.headers.set('X-Content-Type-Options', 'nosniff');
  response.write(jsonEncode(body));
  await response.close();
}


Future<String> readBodyLimited(HttpRequest request) async {
  final declared = request.contentLength;
  if (declared > maxRequestBodyBytes) {
    throw const HttpException('payload_too_large');
  }
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in request) {
    total += chunk.length;
    if (total > maxRequestBodyBytes) {
      throw const HttpException('payload_too_large');
    }
    builder.add(chunk);
  }
  return utf8.decode(builder.takeBytes(), allowMalformed: false);
}

bool allowedMethod(String method) => method == 'GET' || method == 'POST';

Future<void> main() async {
  final secrets = loadSecrets();
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('Sadiah public relay listening on :$port');

  await for (final request in server) {
    unawaited(handle(request, secrets));
  }
}

Future<void> handle(HttpRequest request, Map<String, String> secrets) async {
  try {
    if (request.method == 'GET' && request.uri.path == '/health') {
      return jsonResponse(request.response, HttpStatus.ok, {
        'status': 'ok',
        'service': 'sadiah-public-relay',
        'connected_servers': tunnels.length,
      });
    }

    if (request.uri.path == '/tunnel/connect' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final serverId = request.uri.queryParameters['server_id'] ?? '';
      final expected = secrets[serverId];
      if (!serverIdPattern.hasMatch(serverId) ||
          expected == null ||
          bearer(request) != expected) {
        return jsonResponse(request.response, HttpStatus.forbidden, {'error': 'forbidden'});
      }
      final socket = await WebSocketTransformer.upgrade(request);
      final previous = tunnels.remove(serverId);
      await previous?.socket.close(WebSocketStatus.goingAway, 'replaced');
      final tunnel = Tunnel(serverId, socket);
      tunnels[serverId] = tunnel;
      socket.pingInterval = const Duration(seconds: 20);
      try {
        await for (final frame in socket) {
          if (frame is! String) continue;
          try {
            final decoded = jsonDecode(frame);
            if (decoded is! Map || decoded['type'] != 'response') continue;
            final message = Map<String, dynamic>.from(decoded);
            final id = '${message['request_id'] ?? ''}';
            if (id.isEmpty) continue;
            tunnel.pending.remove(id)?.complete(message);
          } catch (_) {
            // A malformed response frame must not tear down an otherwise
            // healthy tunnel. The corresponding request will time out safely.
          }
        }
      } finally {
        if (identical(tunnels[serverId], tunnel)) tunnels.remove(serverId);
        for (final pending in tunnel.pending.values) {
          if (!pending.isCompleted) {
            pending.complete({'status': 502, 'body': '{"error":"tunnel_disconnected"}'});
          }
        }
        tunnel.pending.clear();
      }
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.length < 2 || segments.first != 'r') {
      return jsonResponse(request.response, HttpStatus.notFound, {'error': 'not_found'});
    }
    final serverId = segments[1];
    if (!serverIdPattern.hasMatch(serverId) || !allowedMethod(request.method)) {
      return jsonResponse(request.response, HttpStatus.notFound, {'error': 'not_found'});
    }
    final forwardPath = '/${segments.skip(2).join('/')}';
    if (forwardPath != '/health' && !forwardPath.startsWith('/v2/')) {
      return jsonResponse(request.response, HttpStatus.notFound, {'error': 'not_found'});
    }
    final tunnel = tunnels[serverId];
    if (tunnel == null || tunnel.socket.readyState != WebSocket.open) {
      return jsonResponse(request.response, HttpStatus.serviceUnavailable, {'error': 'server_offline'});
    }

    if (tunnel.pending.length >= maxPendingPerTunnel) {
      return jsonResponse(request.response, HttpStatus.serviceUnavailable, {'error': 'relay_busy'});
    }
    String body;
    try {
      body = await readBodyLimited(request);
    } on HttpException catch (error) {
      if (error.message == 'payload_too_large') {
        return jsonResponse(request.response, HttpStatus.requestEntityTooLarge, {'error': 'payload_too_large'});
      }
      rethrow;
    } on FormatException {
      return jsonResponse(request.response, HttpStatus.badRequest, {'error': 'invalid_utf8'});
    }
    final requestId = '${DateTime.now().microsecondsSinceEpoch}-${secureRandom.nextInt(1 << 32)}';
    final completer = Completer<Map<String, dynamic>>();
    tunnel.pending[requestId] = completer;
    final query = request.uri.hasQuery ? '?${request.uri.query}' : '';
    final forwardedHeaders = <String, String>{};
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    final contentType = request.headers.value(HttpHeaders.contentTypeHeader);
    final accept = request.headers.value(HttpHeaders.acceptHeader);
    if (auth != null) forwardedHeaders[HttpHeaders.authorizationHeader] = auth;
    if (contentType != null) {
      forwardedHeaders[HttpHeaders.contentTypeHeader] = contentType;
    }
    if (accept != null) forwardedHeaders[HttpHeaders.acceptHeader] = accept;

    tunnel.socket.add(jsonEncode({
      'type': 'request',
      'request_id': requestId,
      'method': request.method,
      'path': '$forwardPath$query',
      'headers': forwardedHeaders,
      'body': body,
    }));

    Map<String, dynamic> relayResponse;
    try {
      relayResponse = await completer.future.timeout(const Duration(seconds: 35));
    } on TimeoutException {
      relayResponse = {'status': 504, 'body': '{"error":"tunnel_timeout"}'};
    } finally {
      tunnel.pending.remove(requestId);
    }

    request.response.statusCode = (relayResponse['status'] as num?)?.toInt() ?? 502;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.headers.set('X-Content-Type-Options', 'nosniff');
    final responseHeaders = Map<String, dynamic>.from(
        relayResponse['headers'] as Map? ?? const <String, dynamic>{});
    final responseContentType = responseHeaders[HttpHeaders.contentTypeHeader];
    if (responseContentType != null) {
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        '$responseContentType',
      );
    }
    request.response.write('${relayResponse['body'] ?? ''}');
    await request.response.close();
  } catch (_) {
    try {
      await jsonResponse(
        request.response,
        HttpStatus.internalServerError,
        {'error': 'relay_error'},
      );
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}
