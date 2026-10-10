# Sadiah Public Relay — CP167 Render Ready

This repository is intentionally relay-only. It does not contain Sadiah Digital, the Sadiah Server Mini database, business data, or operator credentials.

## Render deployment

Create a Web Service with:
- Runtime: Docker
- Region: Singapore
- Plan: Free (pilot/test)
- Dockerfile: `./Dockerfile`
- Docker context: `.`

Required environment variable:
- `SADIAH_TUNNELS_JSON` — JSON object mapping one Sadiah Server Mini ID to its long tunnel secret.

Render supplies `PORT` automatically. The relay listens on that port.

## Public endpoints

- `GET /health`
- `WSS /tunnel/connect?server_id=<server-id>` (Server Mini only; Bearer tunnel secret required)
- `GET|POST /r/<server-id>/health`
- `GET|POST /r/<server-id>/v2/*`

No `/v1` protocol is exposed. Business authorization remains enforced by Sadiah Server Mini `/v2` endpoints behind the tunnel.

## Production boundary

TLS is terminated by Render. The relay is deliberately thin and stateless: it forwards requests to the outbound WSS tunnel opened by the OPPO Server Mini. It is not the business database.
