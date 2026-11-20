# Watch party relay

`tool/party_relay.dart` is our own relay for watch parties: the subset of Nostr's NIP-01 that
`lib/party_transport.dart` speaks, and nothing else. Builds made with `--dart-define=PARTY_RELAY=wss://…` try it
first; the public relays in `NostrTransport.defaultRelays` stay behind it as fallback, so a relay outage doesn't
end parties.

It stores nothing: each event goes to whoever is subscribed to its room tag at that moment, then is gone. Messages
are end-to-end encrypted with a key derived from the room code, which neither the relay nor Cloudflare sees.

It runs as one self-contained binary under systemd on `127.0.0.1:7447`, reached through a Cloudflare Tunnel
(`cloudflared` on the same VM), which carries TLS. The VM opens no ports: it needs no ingress rules beyond SSH.
`deploy/party-relay/` holds the unit and `deploy.sh`.

## What it and Cloudflare see

Both the relay and Cloudflare, as the middleman, see client IP addresses, room tags (a hash of the room code, the
same for everyone in a room), when each message is sent, and ciphertext sizes. Neither sees message content. The
relay logs none of it; only errors go to the journal.

## One-time setup

Sized for an OCI "always free" VM.Standard.E2.1.Micro (x86, 1 GB RAM), Ubuntu or Oracle Linux, with `cloudflared`
already installed and running as a tunnel. Add one route to the tunnel, a public hostname such as
`party.example.com` (on a zone in your Cloudflare account) to `http://127.0.0.1:7447` (not `localhost`, which may resolve to IPv6 `::1`; the relay listens on IPv4 only):

- Dashboard-managed tunnel: Networking → Tunnels → your tunnel → Routes → Add route → Published application
  (called Public Hostname in older dashboards): the subdomain and domain, service URL `http://127.0.0.1:7447`.
- Config-file tunnel: an entry in cloudflared's `config.yml`, above the catch-all, then the DNS record:

  ```yaml
  ingress:
    - hostname: party.example.com
      service: http://127.0.0.1:7447
    - service: http_status:404
  ```

  ```sh
  cloudflared tunnel route dns <tunnel> party.example.com
  sudo systemctl restart cloudflared
  ```

WebSockets need nothing extra: Cloudflare proxies them without configuration and Tunnel supports them fully. If
upgrades fail anyway, check the zone's Network → WebSockets toggle is on.

Cloudflare closes WebSockets that carry no data for a while, and may drop any of them when it restarts edge servers.
Neither matters here: the app pings every 20 s and the relay every 30 s, well inside Cloudflare's timeouts, and the
app reconnects a dropped relay by itself (with backoff), the public relays carrying the party meanwhile.

## Deploy and update

From a Linux x86-64 machine with this repo, ssh access, and passwordless sudo on the server (the OCI default):

```sh
deploy/party-relay/deploy.sh ubuntu@203.0.113.7 party.example.com   # opc@… on Oracle Linux
```

It builds the binary, installs it and the unit, restarts the relay, checks it answers on the server, then checks
`https://<hostname>/` through the tunnel. Leave the hostname out to skip that last check. It never touches
cloudflared.

Re-run the same command to ship an update. Restarting drops connected parties for a moment; clients reconnect.

Then add `PARTY_RELAY=wss://<hostname>` to `dart_defines.env` and to the `DART_DEFINES` GitHub secret, so builds
use it.

## Checking it

- `curl https://<hostname>/` answers `party relay` (and `curl http://127.0.0.1:7447/` on the server).
- `systemctl status party-relay cloudflared`
- `journalctl -u party-relay` (errors only) and `journalctl -u cloudflared`

## Limits it enforces

- 2000 connections in all, 20 per client IP. Through the tunnel the client IP is Cloudflare's `CF-Connecting-IP`
  header, which the edge sets itself; `X-Forwarded-For` is ignored, as Cloudflare keeps whatever a client put in it.
- Frames up to 16 KiB, text only; no compression.
- 4 subscriptions per connection; only `#d` filters for kind 21000.
- Events: a burst of 40, then 10 a second, per connection. Only well-formed kind 21000 events with a 64-hex `d`
  tag and a `created_at` within 15 minutes of the server's clock.
- A 30 s ping drops connections that vanished without closing.
- systemd: `MemoryMax=300M` (restart on breach), `LimitNOFILE=8192`, `Restart=always`.

## Known limits

- A frame is read in full before its size is checked (dart:io gives no earlier hook), so one huge frame is
  buffered first; `MemoryMax` plus the restart is the backstop.
- Event ids and signatures aren't verified (clients verify both, and the room tag comes from the secret room code).
- Anything on the VM that can reach `127.0.0.1:7447` can claim any client IP with `CF-Connecting-IP`.
- One process, one machine: no redundancy beyond the public fallback relays.
