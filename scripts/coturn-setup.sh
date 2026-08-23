#!/usr/bin/env bash
# Provisions a bare Ubuntu/Debian instance (e.g. an EC2 box, separate from the
# k8s cluster) as a standalone Coturn STUN/TURN server for Saarathi's WebRTC
# calls. Run as root (or via sudo) on the target instance itself:
#
#   curl -fsSL https://raw.githubusercontent.com/<org>/saarathi/main/scripts/coturn-setup.sh | sudo bash
#   # or, from a checkout:
#   sudo TURN_SECRET=... ./scripts/coturn-setup.sh
#
# Why a dedicated box instead of running Coturn inside the k8s cluster: its
# relay needs a wide UDP port range (41 ports by default) bound to a stable
# public IP. That's a `hostNetwork: true` pod on a pinned node in k8s — real
# extra attack surface and operational fragility on shared cluster nodes for
# a single-purpose relay. A small dedicated instance keeps it isolated and
# lets its firewall rules be scoped to exactly this one job.
#
# What this script does:
#   1. Installs coturn from the distro package repos.
#   2. Writes /etc/turnserver.conf (shared-secret auth, matching Saarathi's
#      TURN_SECRET convention — rides mints short-lived per-call credentials
#      from it at GET /v1/rtc/ice, the server never stores per-user creds).
#   3. Enables + (re)starts the coturn systemd service.
#   4. Opens the required firewall ports via ufw, if present (or prints the
#      raw port list to open manually).
#   5. Prints the exact values.yaml/GitHub-secret settings to copy into the
#      Helm chart deploy (rides.config.turnUrls / TURN_SECRET).
#
# Safe to re-run: overwrites turnserver.conf and restarts the service each
# time, e.g. to rotate TURN_SECRET or change the port range.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

REALM="${REALM:-saarathi.np}"
LISTENING_PORT="${LISTENING_PORT:-3478}"
MIN_PORT="${MIN_PORT:-49160}"
MAX_PORT="${MAX_PORT:-49200}"

# Reuse an existing secret across re-runs if one's already configured, so a
# routine re-run (e.g. to bump the port range) doesn't silently rotate it and
# invalidate every credential the running `rides` service already minted.
EXISTING_SECRET=""
if [[ -f /etc/turnserver.conf ]]; then
  EXISTING_SECRET="$(grep -oP '(?<=^static-auth-secret=).*' /etc/turnserver.conf || true)"
fi
TURN_SECRET="${TURN_SECRET:-${EXISTING_SECRET:-$(openssl rand -hex 32)}}"

EXTERNAL_IP="${EXTERNAL_IP:-}"
if [[ -z "$EXTERNAL_IP" ]]; then
  # Try cloud metadata endpoints first (works unauthenticated on EC2/GCE/etc
  # without extra flags in most default configs), then fall back to a public
  # echo service.
  EXTERNAL_IP="$(curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  if [[ -z "$EXTERNAL_IP" ]]; then
    EXTERNAL_IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$EXTERNAL_IP" ]]; then
    echo "Couldn't auto-detect the public IP — pass EXTERNAL_IP=1.2.3.4 explicitly." >&2
    exit 1
  fi
fi

echo "==> Installing coturn"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq coturn

echo "==> Writing /etc/turnserver.conf"
cat > /etc/turnserver.conf <<EOF
listening-port=${LISTENING_PORT}
min-port=${MIN_PORT}
max-port=${MAX_PORT}
realm=${REALM}
server-name=saarathi
external-ip=${EXTERNAL_IP}
fingerprint
use-auth-secret
static-auth-secret=${TURN_SECRET}
no-tls
no-dtls
log-file=/var/log/turnserver.log
simple-log
no-cli
EOF

# The Debian/Ubuntu coturn package ships disabled by default (TURNSERVER_ENABLED=0).
echo "TURNSERVER_ENABLED=1" > /etc/default/coturn

echo "==> Enabling + starting coturn"
systemctl enable coturn >/dev/null
systemctl restart coturn
sleep 1
systemctl --no-pager status coturn | head -5

echo "==> Firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${LISTENING_PORT}/tcp" >/dev/null
  ufw allow "${LISTENING_PORT}/udp" >/dev/null
  ufw allow "${MIN_PORT}:${MAX_PORT}/udp" >/dev/null
  echo "ufw rules added for ${LISTENING_PORT} tcp/udp and ${MIN_PORT}-${MAX_PORT}/udp."
else
  cat <<EOF
ufw not found — open these manually (e.g. in the instance's security group /
cloud firewall, not just an OS-level one):
  ${LISTENING_PORT}/tcp
  ${LISTENING_PORT}/udp
  ${MIN_PORT}-${MAX_PORT}/udp
EOF
fi

cat <<EOF

==> Done. Coturn is listening on ${EXTERNAL_IP}:${LISTENING_PORT}.

Set these in the Saarathi Helm deploy:
  values.yaml:            services.rides.config.turnUrls: "turn:${EXTERNAL_IP}:${LISTENING_PORT}"
  GitHub Actions secret:  SAARATHI_TURN_SECRET = ${TURN_SECRET}

(Same TURN_SECRET must be set on both sides — this box and rides — since
credentials are HMAC'd with it, not stored per-user.)
EOF
