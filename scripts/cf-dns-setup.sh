#!/usr/bin/env bash
set -euo pipefail

# One-time DNS record population for roomler.live migration to Cloudflare.
# Run BEFORE switching nameservers at GoDaddy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DNS="${SCRIPT_DIR}/cf-dns.sh"

echo "=== Populating Cloudflare DNS records for roomler.live ==="
echo

# A records (all DNS-only, no proxy)
echo "--- A records ---"
"$DNS" add A roomler.live        94.130.141.98
"$DNS" add A coturn.roomler.live 94.130.141.74
"$DNS" add A coturn.roomler.live 94.130.141.98

echo
echo "--- MX records ---"
"$DNS" add MX roomler.live aspmx.l.google.com       1
"$DNS" add MX roomler.live alt1.aspmx.l.google.com  5
"$DNS" add MX roomler.live alt2.aspmx.l.google.com  5
"$DNS" add MX roomler.live aspmx2.googlemail.com    10
"$DNS" add MX roomler.live aspmx3.googlemail.com    10

echo
echo "=== Done. Verify with: $DNS list ==="
