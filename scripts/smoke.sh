#!/usr/bin/env bash
# End-to-end smoke test for Saarathi: exercises auth (OTP → KYC → staff
# approval) and rides (fare estimate → trip → accept → complete) against a live
# database. Requires both services running and `jq`.
#
#   Terminal 1:  cd backend && docker compose up -d
#                cargo run -p saarathi-auth
#   Terminal 2:  cargo run -p saarathi-rides
#   Terminal 3:  ./scripts/smoke.sh
#
# Override endpoints via API / RIDES env vars. Requires OTP_DEV_MODE=true so the
# OTP is echoed back (default in backend/.env).
set -euo pipefail

API="${API:-http://localhost:8081}"
RIDES="${RIDES:-http://localhost:8082}"
ADMIN_PHONE="${SEED_DEV_ADMIN_PHONE:-+9779800000000}"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
j() { curl -fsS "$@"; }
step() { printf '\n▶ %s\n' "$1"; }

step "health checks"
j "$API/health"   | jq -e '.status=="ok"' >/dev/null && echo "  auth ok"
j "$RIDES/health" | jq -e '.status=="ok"' >/dev/null && echo "  rides ok"

login() { # phone [as_driver] -> token pair JSON on stdout
  local phone="$1" as_driver="${2:-false}" code
  code=$(j -X POST "$API/v1/auth/otp/request" -H 'content-type: application/json' \
    -d "{\"phone\":\"$phone\"}" | jq -r '.dev_code // empty')
  [ -n "$code" ] || { echo "no dev_code — is OTP_DEV_MODE=true?" >&2; exit 1; }
  j -X POST "$API/v1/auth/otp/verify" -H 'content-type: application/json' \
    -d "{\"phone\":\"$phone\",\"code\":\"$code\",\"as_driver\":$as_driver}"
}

step "staff login"
ADMIN_TOKEN=$(login "$ADMIN_PHONE" | jq -r '.access_token')
echo "  got staff token"

step "driver signup + register + KYC upload"
DPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
DTOKEN=$(login "$DPHONE" true | jq -r '.access_token')
j -X POST "$API/v1/driver/register" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' \
  -d '{"license_number":"DL-0001","vehicle":{"class":"two_wheeler","plate_number":"BA-1-PA-1234","make":"Honda","model":"Shine"}}' >/dev/null
printf 'vehicle photo bytes' > /tmp/saarathi_vphoto.jpg
j -X POST "$API/v1/driver/documents" -H "authorization: Bearer $DTOKEN" \
  -F kind=vehicle_photo -F file=@/tmp/saarathi_vphoto.jpg >/dev/null
echo "  driver $DPHONE registered + vehicle_photo uploaded"

step "staff approves driver"
DID=$(j "$API/v1/admin/drivers?status=queue" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg p "$DPHONE" '.[] | select(.phone==$p) | .id' | head -n1)
[ -n "$DID" ] || { echo "  driver not found in queue"; exit 1; }
j -X POST "$API/v1/admin/drivers/$DID/approve" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
echo "  approved $DID"

step "rider fare estimate (haversine offline fallback)"
RTOKEN=$(login "+97797$(( RANDOM % 900000 + 100000 ))" | jq -r '.access_token')
BODY='{"origin":{"lat":28.0336,"lng":82.4836},"dest":{"lat":28.0450,"lng":82.4970},"vehicle_class":"two_wheeler"}'
j -X POST "$RIDES/v1/rides/estimate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$BODY" \
  | jq -e '.gross_fare and .final_fare and .distance_km' >/dev/null
echo "  estimate ok"

step "create trip → accept → complete"
TID=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$BODY" | jq -r '.id')
echo "  trip $TID created"
j -X POST "$RIDES/v1/rides/$TID/accept" -H "authorization: Bearer $DTOKEN" >/dev/null
echo "  driver accepted"
for s in arriving in_progress completed; do
  j -X POST "$RIDES/v1/rides/$TID/status" -H "authorization: Bearer $DTOKEN" \
    -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
done
echo "  trip completed"

printf '\n✅ SMOKE OK\n'
