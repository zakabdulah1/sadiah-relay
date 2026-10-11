# Sadiah Relay CP168 — Cloudflare Development Relay

CP168 moves the CP167 relay behavior from Dart/Docker to Cloudflare Worker + Durable Object so the real cross-network pilot can proceed without Render.

## Pilot path

Sadiah Digital Owner/Operator -> HTTPS workers.dev -> Durable Object relay -> WebSocket -> OPPO Sadiah Server Mini -> /v2

## Endpoints

- GET /health
- GET /tunnel/status?server_id=<server-id>
- WSS /tunnel/connect?server_id=<server-id>&key=<relay-secret>
- GET|POST /r/<server-id>/health
- GET|POST /r/<server-id>/v2/*

## Development scope

- One OPPO pilot first.
- Relay secret stays outside source.
- Cloudflare stores no business database.
- No /v1 production route.
- Cross-network remains NOT PASS until the OPPO and Sadiah Digital are actually exercised on different networks.
