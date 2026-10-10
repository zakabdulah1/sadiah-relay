# CP167 Deployment Gate

Before cross-network PASS can be claimed:

1. Relay repository is published to a Git host reachable by Render.
2. Render Free Web Service is created in Singapore from this repository.
3. A unique server ID and >=32-character random tunnel secret are configured on Render.
4. Sadiah Server Mini is built with the matching WSS URL, server ID, and tunnel secret.
5. Sadiah Digital is built with the public HTTPS relay base URL.
6. Relay `/health` is reachable publicly over HTTPS.
7. OPPO connects through WSS and `/health` reports one connected server.
8. Owner and Operator on different networks complete a real `/v2` activation/event/ACK round trip.
9. Network change/reconnect and Server down/up recovery are exercised.

Until all nine items are observed, cross-network remains NOT PASS.
