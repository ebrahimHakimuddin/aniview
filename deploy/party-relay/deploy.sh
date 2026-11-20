#!/usr/bin/env bash
# Builds the watch party relay and installs (or updates) it on a server, listening on 127.0.0.1:7447 for a
# Cloudflare Tunnel on the same machine. Safe to re-run. It doesn't touch cloudflared: see docs/party-relay.md.
#
#   deploy/party-relay/deploy.sh <ssh-target> [hostname]
#   deploy/party-relay/deploy.sh ubuntu@203.0.113.7 party.example.com
#
# Needs: a Linux x86-64 machine here (the binary is built for this one's platform), and ssh access with passwordless
# sudo there (the default on OCI images). With [hostname], it also checks the relay answers through the tunnel.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <ssh-target> [hostname]" >&2
  exit 2
fi
target=$1 host=${2:-}
if [[ -n $host && ! $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  echo "not a hostname: $host" >&2
  exit 2
fi
if [[ "$(uname -sm)" != "Linux x86_64" ]]; then
  echo "build this on Linux x86-64: dart compile exe only builds for the machine it runs on" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
if command -v fvm >/dev/null; then
  dart=(fvm dart)
elif command -v dart >/dev/null; then
  dart=(dart)
else
  dart=("$HOME/fvm/versions/stable/bin/dart")
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> building the relay"
(cd "$repo" && "${dart[@]}" compile exe tool/party_relay.dart -o "$tmp/party-relay")

echo "==> copying to $target"
remote=$(ssh "$target" 'mktemp -d')
scp -q "$tmp/party-relay" "$here/party-relay.service" "$target:$remote/"

echo "==> installing on $target"
# shellcheck disable=SC2087 # $remote is meant to expand here, on this side.
ssh "$target" sudo bash -s <<EOF
set -euo pipefail
trap 'rm -rf "$remote"' EXIT
install -m 755 "$remote/party-relay" /usr/local/bin/party-relay
install -m 644 "$remote/party-relay.service" /etc/systemd/system/party-relay.service
systemctl daemon-reload
systemctl enable party-relay
systemctl restart party-relay
for _ in \$(seq 10); do
  [[ "\$(curl -fsS http://127.0.0.1:7447/ 2>/dev/null)" == "party relay" ]] && exit 0
  sleep 1
done
echo "the relay isn't answering on 127.0.0.1:7447" >&2
journalctl -u party-relay -n 20 --no-pager >&2
exit 1
EOF
echo "    the relay answers on 127.0.0.1:7447 on the server"

if [[ -z $host ]]; then
  cat <<EOF

Now route a public hostname of your Cloudflare Tunnel to http://127.0.0.1:7447 (docs/party-relay.md), then
re-run with the hostname to check it: $0 $target <hostname>
EOF
  exit 0
fi

echo "==> checking https://$host/"
for _ in $(seq 6); do
  if [[ "$(curl -fsS --max-time 5 "https://$host/" 2>/dev/null)" == "party relay" ]]; then
    cat <<EOF

The relay is up: wss://$host

Next: build the app with it as the default relay. Add this line to dart_defines.env (and to the DART_DEFINES
GitHub secret, for CI builds):

  PARTY_RELAY=wss://$host
EOF
    exit 0
  fi
  sleep 2
done
cat >&2 <<EOF
https://$host/ didn't answer 'party relay'. The relay itself is up on the server, so check the tunnel: a public
hostname $host routed to http://127.0.0.1:7447, and cloudflared running (systemctl status cloudflared).
EOF
exit 1
