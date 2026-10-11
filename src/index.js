const BODY_LIMIT = 2 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 35000;
const SERVER_ID = /^[A-Za-z0-9_-]{6,96}$/;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    },
  });
}

function getStub(env, serverId) {
  return env.RELAY_TUNNELS.get(env.RELAY_TUNNELS.idFromName(serverId));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/health') {
      return json({ status: 'ok', service: 'sadiah-cloudflare-relay', version: 'cp168-dev' });
    }

    if (url.pathname === '/tunnel/connect' || url.pathname === '/tunnel/status') {
      const serverId = url.searchParams.get('server_id') || '';
      if (!SERVER_ID.test(serverId)) return json({ error: 'invalid_server_id' }, 400);
      if (url.pathname === '/tunnel/status') {
        return getStub(env, serverId).fetch(new Request('https://relay.internal/__status'));
      }
      return getStub(env, serverId).fetch(request);
    }

    const parts = url.pathname.split('/').filter(Boolean);
    if (parts.length >= 3 && parts[0] === 'r') {
      const serverId = parts[1];
      if (!SERVER_ID.test(serverId)) return json({ error: 'invalid_server_id' }, 400);
      const forwardPath = '/' + parts.slice(2).join('/');
      if (forwardPath !== '/health' && !forwardPath.startsWith('/v2/')) {
        return json({ error: 'not_found' }, 404);
      }
      if (request.method !== 'GET' && request.method !== 'POST') {
        return json({ error: 'method_not_allowed' }, 405);
      }
      const internalUrl = new URL('https://relay.internal/__forward');
      internalUrl.searchParams.set('path', forwardPath + url.search);
      return getStub(env, serverId).fetch(new Request(internalUrl, request));
    }

    return json({ error: 'not_found' }, 404);
  },
};

export class RelayTunnel {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.socket = null;
    this.pending = new Map();
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/tunnel/connect') return this.connect(request, url);
    if (url.pathname === '/__status') {
      return json({ status: 'ok', tunnel_connected: !!this.socket, pending: this.pending.size });
    }
    if (url.pathname === '/__forward') {
      return this.forward(request, url.searchParams.get('path') || '/');
    }
    return json({ error: 'not_found' }, 404);
  }

  async connect(request, url) {
    if (request.headers.get('Upgrade') !== 'websocket') return json({ error: 'websocket_required' }, 426);

    const supplied = url.searchParams.get('key') || '';
    const expected = this.env.RELAY_SECRET || '';
    if (!expected || supplied !== expected) return json({ error: 'forbidden' }, 403);

    if (this.socket) {
      try { this.socket.close(1012, 'replaced'); } catch (_) {}
      this.socket = null;
      this.failAll(502, 'tunnel_replaced');
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    this.socket = server;
    server.addEventListener('message', event => this.onMessage(event));
    server.addEventListener('close', () => this.onDisconnect('tunnel_closed'));
    server.addEventListener('error', () => this.onDisconnect('tunnel_error'));
    return new Response(null, { status: 101, webSocket: client });
  }

  async forward(request, path) {
    if (!this.socket) return json({ error: 'server_offline' }, 503);

    let body = '';
    if (request.method === 'POST') {
      const bytes = new Uint8Array(await request.arrayBuffer());
      if (bytes.byteLength > BODY_LIMIT) return json({ error: 'payload_too_large' }, 413);
      body = new TextDecoder().decode(bytes);
    }

    const requestId = crypto.randomUUID();
    const headers = {};
    for (const name of ['authorization', 'content-type', 'accept']) {
      const value = request.headers.get(name);
      if (value) headers[name] = value;
    }

    const result = new Promise(resolve => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        resolve({ status: 504, body: '{"error":"tunnel_timeout"}', headers: {} });
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(requestId, { resolve, timer });
    });

    try {
      this.socket.send(JSON.stringify({
        type: 'request',
        request_id: requestId,
        method: request.method,
        path,
        headers,
        body,
      }));
    } catch (_) {
      const pending = this.pending.get(requestId);
      if (pending) clearTimeout(pending.timer);
      this.pending.delete(requestId);
      this.onDisconnect('send_failed');
      return json({ error: 'server_offline' }, 503);
    }

    const response = await result;
    const responseHeaders = new Headers({
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    });
    if (response.headers?.['content-type']) {
      responseHeaders.set('content-type', response.headers['content-type']);
    }
    return new Response(response.body || '', {
      status: Number(response.status) || 502,
      headers: responseHeaders,
    });
  }

  onMessage(event) {
    try {
      const msg = JSON.parse(event.data);
      if (msg?.type !== 'response' || !msg.request_id) return;
      const pending = this.pending.get(msg.request_id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(msg.request_id);
      pending.resolve({
        status: Number(msg.status) || 502,
        body: typeof msg.body === 'string' ? msg.body : '',
        headers: msg.headers && typeof msg.headers === 'object' ? msg.headers : {},
      });
    } catch (_) {}
  }

  onDisconnect(reason) {
    this.socket = null;
    this.failAll(502, reason);
  }

  failAll(status, reason) {
    for (const [id, pending] of this.pending.entries()) {
      clearTimeout(pending.timer);
      pending.resolve({
        status,
        body: JSON.stringify({ error: reason }),
        headers: { 'content-type': 'application/json; charset=utf-8' },
      });
      this.pending.delete(id);
    }
  }
}
