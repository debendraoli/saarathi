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
# Override endpoints via env vars. By default all client traffic flows through
# the API gateway (Traefik, :8080); set GATEWAY= to change it. Requires
# OTP_DEV_MODE=true so the OTP is echoed back (default in backend/.env).
set -euo pipefail

GW="${GATEWAY:-http://localhost:8080}"       # single front door (Traefik gateway)
API="${API:-$GW}"
RIDES="${RIDES:-$GW}"
NOTIFY="${NOTIFY:-$GW}"
PAYMENTS="${PAYMENTS:-$GW}"
CAMPAIGNS="${CAMPAIGNS:-$GW}"
PARTNERS="${PARTNERS:-$GW}"
MERCHANT="${MERCHANT:-$GW}"
PLACESVC="${PLACESVC:-$GW}"  # named distinctly — $PLACES is already a rider's saved-places count below
ROUTING="${ROUTING:-http://localhost:8084}"  # internal (rides→routing); not exposed via gateway
ADMIN_PHONE="${SEED_DEV_ADMIN_PHONE:-+9779800000000}"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
j() { curl -fsS "$@"; }
step() { printf '\n▶ %s\n' "$1"; }
idem() { echo "idem-$$-$RANDOM-$(date +%s%N)"; }

step "health checks"
# Liveness probes hit the services directly (as k8s does); /health isn't routed.
j "http://localhost:8081/health" | jq -e '.status=="ok"' >/dev/null && echo "  auth ok"
j "http://localhost:8082/health" | jq -e '.status=="ok"' >/dev/null && echo "  rides ok"
j "http://localhost:8083/health" | jq -e '.status=="ok"' >/dev/null && echo "  notify ok"
j "http://localhost:8084/health" | jq -e '.status=="ok"' >/dev/null && echo "  routing ok"
j "http://localhost:8085/health" | jq -e '.status=="ok"' >/dev/null && echo "  payments ok"
j "http://localhost:8086/health" | jq -e '.status=="ok"' >/dev/null && echo "  campaigns ok"
j "http://localhost:8087/health" | jq -e '.status=="ok"' >/dev/null && echo "  partners ok"
j "http://localhost:8089/health" | jq -e '.status=="ok"' >/dev/null && echo "  places ok"
# The gateway routes an unauthenticated call to notify → 401 proves path routing.
GWCODE=$(curl -sS -o /dev/null -w '%{http_code}' "$GW/v1/notifications")
[ "$GWCODE" = "401" ] || { echo "  gateway not routing (got $GWCODE)"; exit 1; }
echo "  gateway routing ok (:8080 → services)"

login() { # phone [as_driver] -> token pair JSON on stdout
  local phone="$1" as_driver="${2:-false}" code
  code=$(j -X POST "$API/v1/auth/otp/request" -H 'content-type: application/json' \
    -d "{\"phone\":\"$phone\"}" | jq -r '.dev_code // empty')
  [ -n "$code" ] || { echo "no dev_code — is OTP_DEV_MODE=true?" >&2; exit 1; }
  j -X POST "$API/v1/auth/otp/verify" -H 'content-type: application/json' \
    -d "{\"phone\":\"$phone\",\"code\":\"$code\",\"as_driver\":$as_driver}"
}

step "OTP token-bucket rate limiter (3 req/10min, blocks the 4th)"
# The IP layer is intentionally disabled here (OTP_RATE_LIMIT_IP_ALLOWLIST=*
# in docker-compose.yml — this whole suite shares one Docker-bridge address,
# which the IP bucket would otherwise treat as a single abusive caller). The
# phone layer runs the identical token-bucket algorithm, so blocking on it
# demonstrates the same mechanism the acceptance criterion is about.
RLPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
for i in 1 2 3; do
  RLSENT=$(j -X POST "$API/v1/auth/otp/request" -H 'content-type: application/json' \
    -d "{\"phone\":\"$RLPHONE\"}" | jq -r '.sent')
  [ "$RLSENT" = "true" ] || { echo "  request $i should succeed (sent=$RLSENT)"; exit 1; }
done
RLCODE=$(curl -sS -X POST "$API/v1/auth/otp/request" -H 'content-type: application/json' \
  -d "{\"phone\":\"$RLPHONE\"}" | jq -r '.error.code')
[ "$RLCODE" = "OTP_RATE_LIMITED" ] \
  || { echo "  4th request in the window should be rate-limited (got '$RLCODE')"; exit 1; }
echo "  3 requests sent; 4th blocked ($RLCODE)"

step "staff login"
ADMIN_TOKEN=$(login "$ADMIN_PHONE" | jq -r '.access_token')
echo "  got staff token"

step "driver signup + register + KYC upload"
DPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
DLOGIN=$(login "$DPHONE" true)
DTOKEN=$(echo "$DLOGIN" | jq -r '.access_token')
DUID=$(echo "$DLOGIN" | jq -r '.user.id')
j -X POST "$API/v1/driver/register" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' \
  -d '{"license_number":"DL-0001","address":"Ghorahi-5, Dang","vehicle":{"class":"two_wheeler","plate_number":"BA-1-PA-1234","make":"Honda","model":"Shine"}}' >/dev/null
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

step "driver funds credit balance (required to accept jobs)"
# A driver needs a positive credit balance to accept offers — cash trips draw
# the platform's cut from it on completion instead of accruing wallet debt.
DREF0=$(j -X POST "$RIDES/v1/driver/credits/topup" -H "authorization: Bearer $DTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d '{"amount":1000}' | jq -r '.reference')
j -X POST "$PAYMENTS/v1/credits/topup/confirm" -H 'content-type: application/json' \
  -d "{\"reference\":\"$DREF0\"}" >/dev/null
DC_INIT=$(j "$RIDES/v1/driver/credits" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
echo "  driver credits after top-up: NPR $DC_INIT"

step "rider fare estimate (haversine offline fallback)"
RTOKEN=$(login "+97797$(( RANDOM % 900000 + 100000 ))" | jq -r '.access_token')
BODY='{"origin":{"lat":28.0336,"lng":82.4836},"stops":[{"lat":28.0400,"lng":82.4900}],"dest":{"lat":28.0450,"lng":82.4970},"vehicle_class":"two_wheeler","payment_method":"wallet"}'
j -X POST "$RIDES/v1/rides/estimate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$BODY" \
  | jq -e '.gross_fare and .final_fare and .distance_km' >/dev/null
echo "  estimate ok"

step "standardized error envelope (machine codes for i18n)"
ECODE=$(curl -sS -X POST "$RIDES/v1/rides/estimate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' \
  -d '{"origin":{"lat":28,"lng":82},"dest":{"lat":28.1,"lng":82.1},"vehicle_class":"spaceship"}' \
  | jq -r '.error.code')
[ "$ECODE" = "INVALID_VEHICLE_CLASS" ] || { echo "  expected INVALID_VEHICLE_CLASS, got '$ECODE'"; exit 1; }
echo "  error body → { error: { code: $ECODE, message } }"

step "feature flags (circuit breaker)"
FLAGCOUNT=$(j "$RIDES/v1/admin/flags" -H "authorization: Bearer $ADMIN_TOKEN" | jq 'length')
[ "$FLAGCOUNT" -ge 1 ] || { echo "  no feature flags seeded"; exit 1; }
j -X PUT "$RIDES/v1/admin/flags/rides.new_requests" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"enabled":false}' >/dev/null
BREAK=$(curl -sS -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d "$BODY" | jq -r '.error.code')
[ "$BREAK" = "FEATURE_DISABLED" ] || { echo "  circuit breaker not enforced (got '$BREAK')"; exit 1; }
j -X PUT "$RIDES/v1/admin/flags/rides.new_requests" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"enabled":true}' >/dev/null
echo "  $FLAGCOUNT flags; ride intake breaker → $BREAK → restored"

step "bounded fare bargaining"
EBODY='{"origin":{"lat":28.0336,"lng":82.4836},"dest":{"lat":28.0450,"lng":82.4970},"vehicle_class":"two_wheeler"}'
EST=$(j -X POST "$RIDES/v1/rides/estimate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$EBODY")
ALGO=$(echo "$EST" | jq -r '.gross_fare')
FLOOR=$(echo "$EST" | jq -r '.fare_floor')
CEIL=$(echo "$EST" | jq -r '.fare_ceiling')
BTRIP=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' \
  -d "{\"origin\":{\"lat\":28.0336,\"lng\":82.4836},\"dest\":{\"lat\":28.0450,\"lng\":82.4970},\"vehicle_class\":\"two_wheeler\",\"payment_method\":\"cash\",\"offered_fare\":$FLOOR}")
AGREED=$(echo "$BTRIP" | jq -r '.gross_fare')
awk -v a="$AGREED" -v f="$FLOOR" 'BEGIN{exit !(a+0==f+0)}' \
  || { echo "  bargain not applied ($AGREED != $FLOOR)"; exit 1; }
# Just probing the fare math, not actually taking the ride — cancel it so it
# doesn't trip the one-active-ride guard for the rest of this rider's steps.
j -X POST "$RIDES/v1/rides/$(echo "$BTRIP" | jq -r '.id')/status" \
  -H "authorization: Bearer $RTOKEN" -H 'content-type: application/json' \
  -d '{"status":"cancelled","reason":"smoke test probe"}' >/dev/null
echo "  algo=$ALGO  band=[$FLOOR, $CEIL]  agreed=$AGREED"

step "surge window (legal-clamped to +20%)"
SWID=$(j -X POST "$RIDES/v1/admin/surge" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"label":"smoke all-day","start_minute":0,"end_minute":1440,"multiplier":1.15,"vehicle_class":"two_wheeler"}' | jq -r '.id')
SURGE=$(j -X POST "$RIDES/v1/rides/estimate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$EBODY" | jq -r '.surge_multiplier')
awk -v s="$SURGE" 'BEGIN{exit !(s+0>=1.15 && s+0<=1.20)}' \
  || { echo "  surge not applied/clamped ($SURGE)"; exit 1; }
j -X POST "$RIDES/v1/admin/surge/$SWID/deactivate" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
echo "  surge multiplier during window: $SURGE (≤ legal 1.20)"

step "on-site KYC entry (staff onboards a walk-in driver)"
OPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
ODID=$(j -X POST "$API/v1/admin/drivers/onboard" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"phone\":\"$OPHONE\",\"full_name\":\"Walk In\",\"license_number\":\"DL-9\",\"address\":\"Tulsipur-3, Dang\",\"vehicle\":{\"class\":\"two_wheeler\",\"plate_number\":\"BA-2-PA-9\",\"model\":\"Shine\"}}" | jq -r '.id')
[ -n "$ODID" ] && [ "$ODID" != "null" ] || { echo "  onboard failed"; exit 1; }
printf 'license bytes' > /tmp/saarathi_lic.jpg
j -X POST "$API/v1/admin/drivers/$ODID/documents" -H "authorization: Bearer $ADMIN_TOKEN" \
  -F kind=license -F file=@/tmp/saarathi_lic.jpg >/dev/null
INQUEUE=$(j "$API/v1/admin/drivers?status=queue" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq --arg p "$OPHONE" '[.[] | select(.phone==$p)] | length')
[ "$INQUEUE" -eq 1 ] || { echo "  onboarded driver not in queue"; exit 1; }
echo "  onboarded $OPHONE on-site + license doc; in review queue"

step "driver bonus campaign"
j -X POST "$CAMPAIGNS/v1/admin/campaigns" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"code":"DRIVE5","title":"Driver quest","audience":"driver","kind":"flat","value":5}' >/dev/null
echo "  driver bonus campaign DRIVE5 created (granted on completion below)"

step "rider settings + saved places + recent searches"
j -X PUT "$API/v1/me/preferences" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"default_payment_method":"wallet","theme":"dark"}' >/dev/null
THEME=$(j "$API/v1/me/preferences" -H "authorization: Bearer $RTOKEN" | jq -r '.theme')
j -X POST "$API/v1/me/locations" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"label":"home","address":"Ghorahi","lat":28.0336,"lng":82.4836}' >/dev/null
PLACES=$(j "$API/v1/me/locations" -H "authorization: Bearer $RTOKEN" | jq 'length')
j -X POST "$API/v1/me/recent-searches" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"label":"Tribhuvan Chowk","address":"Ghorahi","lat":28.045,"lng":82.497}' >/dev/null
RECENT=$(j "$API/v1/me/recent-searches" -H "authorization: Bearer $RTOKEN" | jq 'length')
echo "  theme=$THEME  saved_places=$PLACES  recent_searches=$RECENT"

step "rider tops up prepaid credits"
REF=$(j -X POST "$PAYMENTS/v1/credits/topup" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d '{"amount":500}' | jq -r '.reference')
j -X POST "$PAYMENTS/v1/credits/topup/confirm" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "{\"reference\":\"$REF\"}" >/dev/null
CREDITS0=$(j "$PAYMENTS/v1/credits" -H "authorization: Bearer $RTOKEN" | jq -r '.balance')
echo "  credits after top-up: NPR $CREDITS0"

step "create multi-stop trip → accept → complete"
TRIPJSON=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d "$BODY")
TID=$(echo "$TRIPJSON" | jq -r '.id')
NSTOPS=$(echo "$TRIPJSON" | jq -r '.stops | length')
[ "$NSTOPS" -eq 1 ] || { echo "  stops not stored"; exit 1; }
echo "  trip $TID created (stops=$NSTOPS)"

# Driver goes online at the pickup so the dispatcher can reach them.
j -X POST "$RIDES/v1/driver/online" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' \
  -d '{"lat":28.0336,"lng":82.4836,"job_types":["ride"]}' >/dev/null
echo "  driver online near pickup"

# Wait for the dispatch engine to offer this trip to our driver.
OFFER=""
for _ in $(seq 1 15); do
  OFFER=$(j "$RIDES/v1/driver/offers" -H "authorization: Bearer $DTOKEN" \
    | jq -r --arg t "$TID" '.[] | select(.trip_id==$t) | .trip_id' | head -n1)
  [ -n "$OFFER" ] && break
  sleep 1
done
[ -n "$OFFER" ] || { echo "  no dispatch offer received"; exit 1; }
echo "  dispatch offered trip to driver"
j -X POST "$RIDES/v1/rides/$TID/offer/accept" -H "authorization: Bearer $DTOKEN" >/dev/null
echo "  driver accepted offer"
for s in arriving in_progress completed; do
  j -X POST "$RIDES/v1/rides/$TID/status" -H "authorization: Bearer $DTOKEN" \
    -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
done
echo "  trip completed"

step "ledger + wallet (hash-chained)"
LEDGER_COUNT=$(j "$RIDES/v1/admin/ledger" -H "authorization: Bearer $ADMIN_TOKEN" | jq 'length')
[ "$LEDGER_COUNT" -ge 1 ] || { echo "  no ledger entries"; exit 1; }
CHAIN=$(j "$RIDES/v1/admin/ledger/verify" -H "authorization: Bearer $ADMIN_TOKEN" | jq -r '.chain_intact')
[ "$CHAIN" = "true" ] || { echo "  ledger chain broken"; exit 1; }
WALLET=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
echo "  entries=$LEDGER_COUNT  chain_intact=$CHAIN  driver_wallet=NPR $WALLET"

step "payment settlement + withdrawal minimum"
CREDITS1=$(j "$PAYMENTS/v1/credits" -H "authorization: Bearer $RTOKEN" | jq -r '.balance')
echo "  rider credits after ride: NPR $CREDITS1 (was $CREDITS0)"
awk -v a="$CREDITS1" -v b="$CREDITS0" 'BEGIN{exit !(a<b)}' \
  || { echo "  rider credits were not charged"; exit 1; }
awk -v w="$WALLET" 'BEGIN{exit !(w>0)}' \
  || { echo "  driver earnings not credited"; exit 1; }
# This trip's payout is small (well under NPR 1,000) — a withdrawal for the
# whole balance should be rejected by the minimum-withdrawal rule. The full
# successful-payout + TDS + weekly-fee flow is exercised below on a bigger fare.
BELOWMIN=$(curl -sS -X POST "$PAYMENTS/v1/payouts" -H "authorization: Bearer $DTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d '{}' | jq -r '.error.code')
[ "$BELOWMIN" = "AMOUNT_INVALID" ] \
  || { echo "  below-minimum withdrawal should be rejected (got '$BELOWMIN')"; exit 1; }
echo "  wallet NPR $WALLET; withdrawal of the whole (sub-minimum) balance rejected ($BELOWMIN)"

step "live tracking + safety + ratings + notifications + analytics"
j -X POST "$RIDES/v1/rides/$TID/location" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' -d '{"lat":28.040,"lng":82.490,"heading":90,"speed":8}' >/dev/null
LOC=$(j "$RIDES/v1/rides/$TID/location" -H "authorization: Bearer $RTOKEN" | jq -r '.lat')
[ -n "$LOC" ] && [ "$LOC" != "null" ] || { echo "  no live location"; exit 1; }
echo "  live driver location shared (lat=$LOC)"

j -X POST "$RIDES/v1/rides/$TID/rate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"stars":5,"tags":["safe_driving","clean"],"comment":"great ride"}' >/dev/null
RATING=$(j "$RIDES/v1/drivers/$DUID/rating" -H "authorization: Bearer $RTOKEN" | jq -r '.avg_stars')
echo "  driver rating: $RATING"

REPID=$(j -X POST "$RIDES/v1/reports" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "{\"trip_id\":\"$TID\",\"category\":\"payment\",\"detail\":\"test dispute\"}" | jq -r '.id')
j -X POST "$RIDES/v1/admin/reports/$REPID/resolve" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"status":"resolved","resolution":"handled"}' >/dev/null
echo "  report filed + resolved"

SOSID=$(j -X POST "$RIDES/v1/rides/$TID/sos" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"lat":28.041,"lng":82.491,"note":"test"}' | jq -r '.id')
ACTIVE=$(j "$RIDES/v1/admin/sos" -H "authorization: Bearer $ADMIN_TOKEN" | jq 'length')
j -X POST "$RIDES/v1/admin/sos/$SOSID/resolve" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"note":"resolved in test"}' >/dev/null
echo "  SOS raised (active=$ACTIVE) + resolved"

# Notifications now flow over NATS to saarathi-notify (eventual consistency).
UNREAD=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  UNREAD=$(j "$NOTIFY/v1/notifications" -H "authorization: Bearer $RTOKEN" | jq -r '.unread')
  [ "$UNREAD" -ge 1 ] && break
  sleep 0.5
done
[ "$UNREAD" -ge 1 ] || { echo "  expected notifications"; exit 1; }
echo "  rider unread notifications: $UNREAD"

EARN=$(j "$RIDES/v1/driver/analytics" -H "authorization: Bearer $DTOKEN" | jq -r '.all_time.earnings')
echo "  driver all-time earnings: NPR $EARN"

step "rider ride history"
HIST=$(j "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" | jq 'length')
[ "$HIST" -ge 1 ] || { echo "  no history"; exit 1; }
echo "  rider history: $HIST trip(s) — can re-request from any"

step "parcel delivery (quote + POD/OTP + COD remittance)"
# Sender (rider) quotes then books a fragile 'small' parcel with NPR 200 COD.
DQUOTE=$(j -X POST "$RIDES/v1/delivery/estimate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' \
  -d '{"origin":{"lat":28.0336,"lng":82.4836},"dest":{"lat":28.0450,"lng":82.4970},"size_tier":"small","fragile":true}')
DFEE_Q=$(echo "$DQUOTE" | jq -r '.delivery_fee')
awk -v f="$DFEE_Q" 'BEGIN{exit !(f+0>0)}' || { echo "  delivery quote failed ($DFEE_Q)"; exit 1; }
PBOOK=$(j -X POST "$RIDES/v1/delivery/parcels" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' \
  -d '{"origin":{"lat":28.0336,"lng":82.4836},"dest":{"lat":28.0450,"lng":82.4970},"size_tier":"small","fragile":true,"recipient_name":"Sita","recipient_phone":"+9779812345678","cod_amount":200}')
PT=$(echo "$PBOOK" | jq -r '.trip.id')
POTP=$(echo "$PBOOK" | jq -r '.delivery_otp')
PFEE=$(echo "$PBOOK" | jq -r '.delivery_fee')
[ -n "$PT" ] && [ "$PT" != "null" ] || { echo "  parcel booking failed"; exit 1; }
# Driver opts into delivery jobs and takes the offer.
j -X POST "$RIDES/v1/driver/heartbeat" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' -d '{"lat":28.0336,"lng":82.4836,"job_types":["ride","delivery"]}' >/dev/null
POF=""
for _ in $(seq 1 15); do
  POF=$(j "$RIDES/v1/driver/offers" -H "authorization: Bearer $DTOKEN" \
    | jq -r --arg t "$PT" '.[] | select(.trip_id==$t) | .trip_id' | head -n1)
  [ -n "$POF" ] && break; sleep 1
done
[ -n "$POF" ] || { echo "  no delivery offer"; exit 1; }
j -X POST "$RIDES/v1/rides/$PT/offer/accept" -H "authorization: Bearer $DTOKEN" >/dev/null
for s in arriving in_progress; do
  j -X POST "$RIDES/v1/rides/$PT/status" -H "authorization: Bearer $DTOKEN" \
    -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
done
# A delivery cannot be completed via the plain status endpoint (POD required).
NOPOD=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$RIDES/v1/rides/$PT/status" \
  -H "authorization: Bearer $DTOKEN" -H 'content-type: application/json' -d '{"status":"completed"}')
[ "$NOPOD" = "400" ] || { echo "  delivery completed without POD (got $NOPOD)"; exit 1; }
# Wrong OTP is rejected.
BADOTP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$RIDES/v1/delivery/parcels/$PT/deliver" \
  -H "authorization: Bearer $DTOKEN" -H 'content-type: application/json' \
  -d "{\"photo_key\":\"pod/$PT.jpg\",\"otp\":\"0000-wrong\"}")
[ "$BADOTP" = "400" ] || { echo "  wrong OTP should be rejected (got $BADOTP)"; exit 1; }
# Sender credits before COD remittance.
CB0=$(j "$PAYMENTS/v1/credits" -H "authorization: Bearer $RTOKEN" | jq -r '.balance')
# Driver delivers with the recipient's OTP + proof photo → settle fee + remit COD.
DLV=$(j -X POST "$RIDES/v1/delivery/parcels/$PT/deliver" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' -d "{\"photo_key\":\"pod/$PT.jpg\",\"otp\":\"$POTP\",\"recipient\":\"Sita\"}")
echo "$DLV" | jq -e '.delivered==true and .cod_remitted==true' >/dev/null \
  || { echo "  delivery POD failed: $DLV"; exit 1; }
CB1=$(j "$PAYMENTS/v1/credits" -H "authorization: Bearer $RTOKEN" | jq -r '.balance')
awk -v a="$CB1" -v b="$CB0" 'BEGIN{d=a-b; exit !(d>199.99 && d<200.01)}' \
  || { echo "  COD not remitted to sender ($CB0 -> $CB1)"; exit 1; }
# The delivery emitted a shared-ledger entry like a ride.
DLED=$(j "$RIDES/v1/admin/ledger" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq --arg t "$PT" '[.[] | select(.trip_id==$t)] | length')
[ "$DLED" -ge 1 ] || { echo "  delivery not in ledger"; exit 1; }
echo "  parcel delivered: quote/fee NPR $PFEE, COD 200 remitted ($CB0 -> $CB1), ledgered"

step "driver credits fund the per-ride cut on cash trips (no subscription)"
DC0=$(j "$RIDES/v1/driver/credits" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
echo "  driver credits: NPR $DC0"

# A cash trip draws the platform's cut straight from the driver's credit
# balance instead of accruing wallet debt; the earnings wallet is untouched.
j -X POST "$RIDES/v1/driver/heartbeat" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' -d '{"lat":28.0336,"lng":82.4836,"job_types":["ride"]}' >/dev/null
WALLET_BEFORE_CASH=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
CASH_BODY='{"origin":{"lat":28.0336,"lng":82.4836},"dest":{"lat":28.0450,"lng":82.4970},"vehicle_class":"two_wheeler","payment_method":"cash"}'
T2=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d "$CASH_BODY" | jq -r '.id')
OF=""
for _ in $(seq 1 15); do
  OF=$(j "$RIDES/v1/driver/offers" -H "authorization: Bearer $DTOKEN" \
    | jq -r --arg t "$T2" '.[] | select(.trip_id==$t) | .trip_id' | head -n1)
  [ -n "$OF" ] && break; sleep 1
done
[ -n "$OF" ] || { echo "  no offer for cash trip"; exit 1; }
j -X POST "$RIDES/v1/rides/$T2/offer/accept" -H "authorization: Bearer $DTOKEN" >/dev/null
for s in arriving in_progress completed; do
  j -X POST "$RIDES/v1/rides/$T2/status" -H "authorization: Bearer $DTOKEN" \
    -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
done
COMM=$(j "$RIDES/v1/admin/ledger" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg t "$T2" '.[] | select(.trip_id==$t) | .commission')
FUND=$(j "$RIDES/v1/admin/ledger" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg t "$T2" '.[] | select(.trip_id==$t) | .accident_fund')
DC1=$(j "$RIDES/v1/driver/credits" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
WALLET_AFTER_CASH=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
awk -v c="$COMM" 'BEGIN{exit !(c+0>0)}' \
  || { echo "  cash trip commission should be > 0 ($COMM)"; exit 1; }
awk -v a="$DC0" -v b="$DC1" -v c="$COMM" -v f="$FUND" \
  'BEGIN{d=a-b; want=c+f; exit !(d>want-0.01 && d<want+0.01)}' \
  || { echo "  driver credits not drawn by commission+fund ($DC0 -> $DC1, want -$COMM-$FUND)"; exit 1; }
# The wallet may still tick up from the unrelated DRIVE5 completion bonus, but
# a cash trip must never pull it *down* — that's the old cash-owed debt this
# migration removed.
awk -v b="$WALLET_BEFORE_CASH" -v a="$WALLET_AFTER_CASH" 'BEGIN{exit !(a+0>=b+0-0.01)}' \
  || { echo "  cash trip should not create wallet debt ($WALLET_BEFORE_CASH -> $WALLET_AFTER_CASH)"; exit 1; }
echo "  cash trip commission NPR $COMM + fund NPR $FUND drawn from credits ($DC0 -> $DC1); wallet $WALLET_BEFORE_CASH -> $WALLET_AFTER_CASH (no debt)"

step "pay a cash trip's fare via gateway (Khalti/mock) instead of physical cash"
# Rider pays T2's fare through the gateway; the driver's wallet is credited
# with driver_payout exactly as a digital payment would have been — the
# ledger entry from completion is untouched (append-only).
T2_PAYOUT=$(j "$RIDES/v1/admin/ledger" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg t "$T2" '.[] | select(.trip_id==$t) | .driver_payout')
GWINIT=$(j -X POST "$PAYMENTS/v1/payments/trips/$T2/initiate" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json')
GWREF=$(echo "$GWINIT" | jq -r '.reference')
[ -n "$GWREF" ] && [ "$GWREF" != "null" ] || { echo "  gateway trip-payment initiate failed: $GWINIT"; exit 1; }
DUPLICATE=$(curl -sS -X POST "$PAYMENTS/v1/payments/trips/$T2/initiate" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' | jq -r '.error.code')
[ "$DUPLICATE" = "CONFLICT" ] || { echo "  double-initiate should conflict (got '$DUPLICATE')"; exit 1; }
WALLET_BEFORE_GW=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
GWCONFIRM=$(j -X POST "$PAYMENTS/v1/payments/trips/$T2/confirm" -H "authorization: Bearer $RTOKEN")
[ "$(echo "$GWCONFIRM" | jq -r '.confirmed')" = "true" ] || { echo "  gateway trip-payment confirm failed: $GWCONFIRM"; exit 1; }
WALLET_AFTER_GW=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
awk -v a="$WALLET_BEFORE_GW" -v b="$WALLET_AFTER_GW" -v p="$T2_PAYOUT" \
  'BEGIN{d=b-a; exit !(d>p-0.01 && d<p+0.01)}' \
  || { echo "  driver wallet not credited with driver_payout ($WALLET_BEFORE_GW -> $WALLET_AFTER_GW, want +$T2_PAYOUT)"; exit 1; }
echo "  trip $T2 fare NPR paid via gateway; driver wallet $WALLET_BEFORE_GW -> $WALLET_AFTER_GW (+NPR $T2_PAYOUT payout)"

step "credit floor blocks ride acceptance below zero"
# A driver who never topped up (balance 0) can't accept jobs — cash trips
# would have nothing to draw the platform's cut from.
ZPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
ZLOGIN=$(login "$ZPHONE" true)
ZTOKEN=$(echo "$ZLOGIN" | jq -r '.access_token')
j -X POST "$API/v1/driver/register" -H "authorization: Bearer $ZTOKEN" -H 'content-type: application/json' \
  -d '{"license_number":"DL-ZERO","address":"Ghorahi-5, Dang","vehicle":{"class":"two_wheeler","plate_number":"BA-1-PA-9999","model":"Shine"}}' >/dev/null
j -X POST "$API/v1/driver/documents" -H "authorization: Bearer $ZTOKEN" \
  -F kind=vehicle_photo -F file=@/tmp/saarathi_vphoto.jpg >/dev/null
ZID=$(j "$API/v1/admin/drivers?status=queue" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg p "$ZPHONE" '.[] | select(.phone==$p) | .id' | head -n1)
j -X POST "$API/v1/admin/drivers/$ZID/approve" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
ZCREDITS=$(j "$RIDES/v1/driver/credits" -H "authorization: Bearer $ZTOKEN" | jq -r '.balance')
awk -v b="$ZCREDITS" 'BEGIN{exit !(b+0<=0)}' \
  || { echo "  fresh driver should start with zero credits (got $ZCREDITS)"; exit 1; }
# Take the funded driver offline so this offer can only go to the zero-credit one.
j -X POST "$RIDES/v1/driver/offline" -H "authorization: Bearer $DTOKEN" >/dev/null
j -X POST "$RIDES/v1/driver/heartbeat" -H "authorization: Bearer $ZTOKEN" \
  -H 'content-type: application/json' -d '{"lat":28.0336,"lng":82.4836,"job_types":["ride"]}' >/dev/null
BT=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d "$CASH_BODY" | jq -r '.id')
BOF=""
for _ in $(seq 1 15); do
  BOF=$(j "$RIDES/v1/driver/offers" -H "authorization: Bearer $ZTOKEN" \
    | jq -r --arg t "$BT" '.[] | select(.trip_id==$t) | .trip_id' | head -n1)
  [ -n "$BOF" ] && break; sleep 1
done
[ -n "$BOF" ] || { echo "  no offer to test the credit floor against"; exit 1; }
BLOCK=$(curl -sS -X POST "$RIDES/v1/rides/$BT/offer/accept" -H "authorization: Bearer $ZTOKEN" | jq -r '.error.code')
[ "$BLOCK" = "INSUFFICIENT_DRIVER_CREDITS" ] \
  || { echo "  zero-credit driver should be blocked from accepting (got '$BLOCK')"; exit 1; }
# The blocked offer leaves this trip stuck unaccepted — cancel it so it
# doesn't trip the one-active-ride guard for this rider's later steps.
j -X POST "$RIDES/v1/rides/$BT/status" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"status":"cancelled","reason":"smoke test probe"}' >/dev/null
echo "  zero-credit driver blocked from accepting ($BLOCK)"

step "withdrawal rules: payout accounts, weekly fee, idempotent replay"
# A fresh driver + a big digital-payment ride so the earnings wallet clears
# the NPR 1,000 withdrawal minimum comfortably.
WPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
WLOGIN=$(login "$WPHONE" true)
WTOKEN=$(echo "$WLOGIN" | jq -r '.access_token')
j -X POST "$API/v1/driver/register" -H "authorization: Bearer $WTOKEN" -H 'content-type: application/json' \
  -d '{"license_number":"DL-W1","address":"Ghorahi-5, Dang","vehicle":{"class":"two_wheeler","plate_number":"BA-1-PA-6543","model":"Shine"}}' >/dev/null
j -X POST "$API/v1/driver/documents" -H "authorization: Bearer $WTOKEN" \
  -F kind=vehicle_photo -F file=@/tmp/saarathi_vphoto.jpg >/dev/null
WID=$(j "$API/v1/admin/drivers?status=queue" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg p "$WPHONE" '.[] | select(.phone==$p) | .id' | head -n1)
j -X POST "$API/v1/admin/drivers/$WID/approve" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
WCREF=$(j -X POST "$RIDES/v1/driver/credits/topup" -H "authorization: Bearer $WTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d '{"amount":1000}' | jq -r '.reference')
j -X POST "$PAYMENTS/v1/credits/topup/confirm" -H 'content-type: application/json' \
  -d "{\"reference\":\"$WCREF\"}" >/dev/null

WRPHONE="+97797$(( RANDOM % 900000 + 100000 ))"
WRTOKEN=$(login "$WRPHONE" | jq -r '.access_token')
WRREF=$(j -X POST "$PAYMENTS/v1/credits/topup" -H "authorization: Bearer $WRTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d '{"amount":10000}' | jq -r '.reference')
j -X POST "$PAYMENTS/v1/credits/topup/confirm" -H "authorization: Bearer $WRTOKEN" \
  -H 'content-type: application/json' -d "{\"reference\":\"$WRREF\"}" >/dev/null

j -X POST "$RIDES/v1/driver/heartbeat" -H "authorization: Bearer $WTOKEN" \
  -H 'content-type: application/json' -d '{"lat":27.0,"lng":81.5,"job_types":["ride"]}' >/dev/null
BIGBODY='{"origin":{"lat":27.0,"lng":81.5},"dest":{"lat":29.0,"lng":83.5},"vehicle_class":"two_wheeler","payment_method":"wallet"}'
WT=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $WRTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d "$BIGBODY" | jq -r '.id')
WOF=""
for _ in $(seq 1 15); do
  WOF=$(j "$RIDES/v1/driver/offers" -H "authorization: Bearer $WTOKEN" \
    | jq -r --arg t "$WT" '.[] | select(.trip_id==$t) | .trip_id' | head -n1)
  [ -n "$WOF" ] && break; sleep 1
done
[ -n "$WOF" ] || { echo "  no offer for the big-fare wallet-building ride"; exit 1; }
j -X POST "$RIDES/v1/rides/$WT/offer/accept" -H "authorization: Bearer $WTOKEN" >/dev/null
for s in arriving in_progress completed; do
  j -X POST "$RIDES/v1/rides/$WT/status" -H "authorization: Bearer $WTOKEN" \
    -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
done
BIGWALLET=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $WTOKEN" | jq -r '.balance')
awk -v w="$BIGWALLET" 'BEGIN{exit !(w+0>2500)}' \
  || { echo "  wallet-building ride payout too small ($BIGWALLET)"; exit 1; }
echo "  driver wallet after big digital ride: NPR $BIGWALLET"

# Saved payout accounts: first one is forced default; a second with
# make_default flips it, enforcing exactly one default at a time.
PA1=$(j -X POST "$PAYMENTS/v1/payout-accounts" -H "authorization: Bearer $WTOKEN" -H 'content-type: application/json' \
  -d '{"kind":"bank","label":"NIC Asia ****1234","details":{"bank":"NIC Asia","account":"1234"}}')
PA1ID=$(echo "$PA1" | jq -r '.id')
PA1DEF=$(echo "$PA1" | jq -r '.is_default')
[ "$PA1DEF" = "true" ] || { echo "  first payout account should be the default"; exit 1; }
PA2=$(j -X POST "$PAYMENTS/v1/payout-accounts" -H "authorization: Bearer $WTOKEN" -H 'content-type: application/json' \
  -d '{"kind":"wallet","label":"eSewa ****9876","details":{"provider":"esewa","id":"9876"},"make_default":true}')
PA2ID=$(echo "$PA2" | jq -r '.id')
DEFAULTS=$(j "$PAYMENTS/v1/payout-accounts" -H "authorization: Bearer $WTOKEN" | jq '[.[] | select(.is_default)] | length')
[ "$DEFAULTS" = "1" ] || { echo "  should be exactly one default payout account (got $DEFAULTS)"; exit 1; }
NEWDEFAULT=$(j "$PAYMENTS/v1/payout-accounts" -H "authorization: Bearer $WTOKEN" | jq -r --arg id "$PA2ID" '.[] | select(.id==$id) | .is_default')
[ "$NEWDEFAULT" = "true" ] || { echo "  make_default did not flip the default"; exit 1; }
echo "  payout accounts: $PA1ID (bank, initial default) -> $PA2ID (wallet, now default)"

# Idempotent withdrawal: replaying the same key must not double-debit.
PK1=$(idem)
POUT1=$(j -X POST "$PAYMENTS/v1/payouts" -H "authorization: Bearer $WTOKEN" \
  -H "x-idempotency-key: $PK1" -H 'content-type: application/json' -d '{"amount":1200}')
POUT1B=$(j -X POST "$PAYMENTS/v1/payouts" -H "authorization: Bearer $WTOKEN" \
  -H "x-idempotency-key: $PK1" -H 'content-type: application/json' -d '{"amount":1200}')
[ "$(echo "$POUT1" | jq -r '.reference')" = "$(echo "$POUT1B" | jq -r '.reference')" ] \
  || { echo "  replayed withdrawal returned a different reference"; exit 1; }
WFEE1=$(echo "$POUT1" | jq -r '.weekly_fee')
awk -v f="$WFEE1" 'BEGIN{exit !(f+0==0)}' \
  || { echo "  first withdrawal this week should be fee-free (got $WFEE1)"; exit 1; }
WALLET_AFTER_1=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $WTOKEN" | jq -r '.balance')
awk -v before="$BIGWALLET" -v after="$WALLET_AFTER_1" \
  'BEGIN{exit !(before-after > 1199.99 && before-after < 1200.01)}' \
  || { echo "  replayed withdrawal double-debited the wallet ($BIGWALLET -> $WALLET_AFTER_1)"; exit 1; }
echo "  withdrawal NPR 1200 (fee-free, 1st this week) replayed with same key -> single debit ($BIGWALLET -> $WALLET_AFTER_1)"

# A second, distinct withdrawal the same week picks up the 2% weekly fee.
POUT2=$(j -X POST "$PAYMENTS/v1/payouts" -H "authorization: Bearer $WTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d '{"amount":1200}')
WFEE2=$(echo "$POUT2" | jq -r '.weekly_fee')
awk -v f="$WFEE2" 'BEGIN{exit !(f+0>23.9 && f+0<24.1)}' \
  || { echo "  second withdrawal this week should carry a 2% fee (got $WFEE2, want ~24)"; exit 1; }
echo "  second withdrawal this week: weekly_fee=NPR $WFEE2 (2% of 1200)"

step "payment dispute lifecycle"
DISPREF=$(echo "$POUT2" | jq -r '.reference')
DISPID=$(j -X POST "$PAYMENTS/v1/disputes" -H "authorization: Bearer $WTOKEN" -H 'content-type: application/json' \
  -d "{\"reference\":\"$DISPREF\",\"detail\":\"payout amount looks wrong\"}" | jq -r '.id')
MINE=$(j "$PAYMENTS/v1/disputes" -H "authorization: Bearer $WTOKEN" | jq --arg id "$DISPID" '[.[] | select(.id==$id)] | length')
[ "$MINE" = "1" ] || { echo "  dispute not visible to its filer"; exit 1; }
j -X POST "$PAYMENTS/v1/admin/disputes/$DISPID/status" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"status":"investigating"}' >/dev/null
j -X POST "$PAYMENTS/v1/admin/disputes/$DISPID/status" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{"status":"resolved","resolution":"refunded the difference"}' >/dev/null
DISPSTATUS=$(j "$PAYMENTS/v1/admin/disputes" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg id "$DISPID" '.[] | select(.id==$id) | .status')
[ "$DISPSTATUS" = "resolved" ] || { echo "  dispute did not resolve (got $DISPSTATUS)"; exit 1; }
echo "  dispute $DISPID on $DISPREF: open -> investigating -> resolved"

DUSED=$(j "$CAMPAIGNS/v1/admin/campaigns" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r '.[] | select(.code=="DRIVE5") | .used_count')
awk -v u="$DUSED" 'BEGIN{exit !(u+0>=1)}' \
  || { echo "  driver bonus not granted on completion ($DUSED)"; exit 1; }
echo "  driver bonus granted on trip completion (redemptions=$DUSED)"

step "cancellation with reason → complaints feed"
CID=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d "$EBODY" | jq -r '.id')
j -X POST "$RIDES/v1/rides/$CID/status" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"status":"cancelled","reason":"changed my mind"}' >/dev/null
INFEED=$(j "$RIDES/v1/admin/cancellations" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq --arg t "$CID" '[.[] | select(.id==$t)] | length')
[ "$INFEED" -eq 1 ] || { echo "  cancellation not in complaints feed"; exit 1; }
echo "  ride cancelled with reason; appears in complaints feed"

step "credit plans (maker-checker approval)"
PID=$(j -X POST "$RIDES/v1/admin/credit-plans" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"Standard","min_amount":1000,"max_amount":10000,"bonus_percent":5}' | jq -r '.id')
PSTAT=$(j "$RIDES/v1/admin/credit-plans" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg p "$PID" '.[] | select(.id==$p) | .status')
j -X POST "$RIDES/v1/admin/credit-plans/$PID/approve" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
ACTIVEP=$(j "$RIDES/v1/credit-plans" -H "authorization: Bearer $RTOKEN" \
  | jq --arg p "$PID" '[.[] | select(.id==$p)] | length')
[ "$ACTIVEP" -eq 1 ] || { echo "  plan not active for riders"; exit 1; }
echo "  plan created (was '$PSTAT') → approved → visible to riders"

step "filters / leaderboards + rides history"
TOPEARN=$(j "$RIDES/v1/admin/leaderboard?role=driver&by=earnings" -H "authorization: Bearer $ADMIN_TOKEN" | jq 'length')
RIDESN=$(j "$RIDES/v1/admin/rides" -H "authorization: Bearer $ADMIN_TOKEN" | jq 'length')
echo "  top-earner drivers=$TOPEARN  admin rides listed=$RIDESN"

step "platform analytics + event tracking"
OVR=$(j "$RIDES/v1/admin/analytics/overview" -H "authorization: Bearer $ADMIN_TOKEN")
TT=$(echo "$OVR" | jq -r '.trips.total')
GMV=$(echo "$OVR" | jq -r '.money.gmv')
COMPRATE=$(echo "$OVR" | jq -r '.trips.completion_rate')
TSN=$(j "$RIDES/v1/admin/analytics/timeseries?days=7" -H "authorization: Bearer $ADMIN_TOKEN" | jq '.series | length')
[ "$TT" -ge 1 ] || { echo "  analytics missing trips"; exit 1; }
[ "$TSN" -eq 7 ] || { echo "  timeseries wrong length ($TSN)"; exit 1; }
echo "  analytics: trips=$TT gmv=NPR $GMV completion_rate=$COMPRATE timeseries_days=$TSN"

step "merchant geofence: polygon -> H3 polyfill cache, contains query"
MID=$(j -X POST "$MERCHANT/v1/admin/merchants" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"name":"Ghorahi Geofence Test","vertical":"food","lat":28.0350,"lng":82.4850}' | jq -r '.id')
[ -n "$MID" ] && [ "$MID" != "null" ] || { echo "  merchant creation failed"; exit 1; }
ZSET=$(j -X PUT "$MERCHANT/v1/merchant/zone/$MID" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"points":[{"lat":28.030,"lng":82.480},{"lat":28.030,"lng":82.490},{"lat":28.040,"lng":82.490},{"lat":28.040,"lng":82.480}]}')
ZCELLS=$(echo "$ZSET" | jq -r '.cell_count')
awk -v c="$ZCELLS" 'BEGIN{exit !(c+0>0)}' || { echo "  zone polyfill produced no cells ($ZSET)"; exit 1; }
INSIDE=$(j "$MERCHANT/v1/merchant/zone/$MID/contains?lat=28.035&lng=82.485" | jq -r '.contains')
[ "$INSIDE" = "true" ] || { echo "  interior point should be inside the zone (got $INSIDE)"; exit 1; }
OUTSIDE=$(j "$MERCHANT/v1/merchant/zone/$MID/contains?lat=28.5&lng=83.0" | jq -r '.contains')
[ "$OUTSIDE" = "false" ] || { echo "  far point should be outside the zone (got $OUTSIDE)"; exit 1; }
NOZONE=$(j "$MERCHANT/v1/merchant/zone/00000000-0000-0000-0000-000000000000/contains?lat=28.035&lng=82.485" | jq -r '.zone_defined')
[ "$NOZONE" = "false" ] || { echo "  undefined zone should report zone_defined=false (got $NOZONE)"; exit 1; }
echo "  zone cached as $ZCELLS H3 cells; interior=in, ~50km away=out, undefined merchant=zone_defined:false"

step "marketplace order: geofence-bounded visibility + idempotent placement"
ITEMID=$(j -X POST "$MERCHANT/v1/merchant/menu" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"merchant_id\":\"$MID\",\"name\":\"Momo\",\"price\":150}" | jq -r '.id')
[ -n "$ITEMID" ] && [ "$ITEMID" != "null" ] || { echo "  menu item creation failed"; exit 1; }
VISIBLE_IN=$(j "$MERCHANT/v1/merchants?lat=28.035&lng=82.485" -H "authorization: Bearer $RTOKEN" \
  | jq --arg m "$MID" '[.[] | select(.id==$m)] | length')
[ "$VISIBLE_IN" -eq 1 ] || { echo "  merchant should be visible from inside its zone"; exit 1; }
VISIBLE_OUT=$(j "$MERCHANT/v1/merchants?lat=28.5&lng=83.0" -H "authorization: Bearer $RTOKEN" \
  | jq --arg m "$MID" '[.[] | select(.id==$m)] | length')
[ "$VISIBLE_OUT" -eq 0 ] || { echo "  merchant should be hidden outside its zone"; exit 1; }
ORDBODY="{\"merchant_id\":\"$MID\",\"items\":[{\"menu_item_id\":\"$ITEMID\",\"qty\":2}],\"delivery\":{\"lat\":28.035,\"lng\":82.485},\"payment_method\":\"cash\"}"
IDEMKEY=$(idem)
OID1=$(j -X POST "$MERCHANT/v1/orders" -H "authorization: Bearer $RTOKEN" -H "x-idempotency-key: $IDEMKEY" \
  -H 'content-type: application/json' -d "$ORDBODY" | jq -r '.order.id')
[ -n "$OID1" ] && [ "$OID1" != "null" ] || { echo "  order placement failed"; exit 1; }
OID2=$(j -X POST "$MERCHANT/v1/orders" -H "authorization: Bearer $RTOKEN" -H "x-idempotency-key: $IDEMKEY" \
  -H 'content-type: application/json' -d "$ORDBODY" | jq -r '.order.id')
[ "$OID1" = "$OID2" ] || { echo "  replayed order should return the same id ($OID1 != $OID2)"; exit 1; }
ORDCOUNT=$(j "$MERCHANT/v1/orders" -H "authorization: Bearer $RTOKEN" | jq --arg m "$MID" '[.[] | select(.merchant_id==$m)] | length')
[ "$ORDCOUNT" -eq 1 ] || { echo "  idempotency key replay created a duplicate order (count=$ORDCOUNT)"; exit 1; }
OUTZONE_BODY="{\"merchant_id\":\"$MID\",\"items\":[{\"menu_item_id\":\"$ITEMID\",\"qty\":1}],\"delivery\":{\"lat\":28.5,\"lng\":83.0},\"payment_method\":\"cash\"}"
ZONEREJECT=$(curl -sS -w "|%{http_code}" -X POST "$MERCHANT/v1/orders" -H "authorization: Bearer $RTOKEN" -H "x-idempotency-key: $(idem)" \
  -H 'content-type: application/json' -d "$OUTZONE_BODY" | tail -c 4)
[ "$ZONEREJECT" = "|400" ] || { echo "  order to an out-of-zone address should be rejected (got $ZONEREJECT)"; exit 1; }
echo "  merchant visible in-zone/hidden out-of-zone; order $OID1 idempotent replay -> same id; out-of-zone order rejected"

step "dynamic rule-based campaign (new-customer only)"
j -X POST "$CAMPAIGNS/v1/admin/campaigns" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"code":"NEWBIE20","title":"New customer 20%","audience":"rider","kind":"percent","value":20,"max_discount":30,"rules":[{"type":"new_user","max_prior_rides":0}]}' >/dev/null
NTOKEN=$(login "+97796$(( RANDOM % 900000 + 100000 ))" | jq -r '.access_token')
NEWDISC=$(j -X POST "$RIDES/v1/rides/estimate" -H "authorization: Bearer $NTOKEN" \
  -H 'content-type: application/json' -d "$(echo "$EBODY" | jq '. + {code:"NEWBIE20"}')" | jq -r '.discount_amount')
awk -v d="$NEWDISC" 'BEGIN{exit !(d+0>0)}' \
  || { echo "  new-customer discount not applied ($NEWDISC)"; exit 1; }
VETDISC=$(j -X POST "$RIDES/v1/rides/estimate" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$(echo "$EBODY" | jq '. + {code:"NEWBIE20"}')" | jq -r '.discount_amount')
awk -v d="$VETDISC" 'BEGIN{exit !(d+0==0)}' \
  || { echo "  veteran rider should be ineligible ($VETDISC)"; exit 1; }
echo "  rule engine: new rider disc=NPR $NEWDISC, veteran disc=NPR $VETDISC (ineligible)"

step "fleet partnership (phase 1: tenancy + fleet management)"
OWNER_PHONE="+97798$(( RANDOM % 900000 + 100000 ))"
PID=$(j -X POST "$PARTNERS/v1/admin/partners" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"Ghorahi Moto Fleet\",\"owner_phone\":\"$OWNER_PHONE\",\"commission_share\":0.04}" | jq -r '.id')
[ -n "$PID" ] && [ "$PID" != "null" ] || { echo "  partner create failed"; exit 1; }
OWNER_TOKEN=$(login "$OWNER_PHONE" | jq -r '.access_token')
MYROLE=$(j "$PARTNERS/v1/partner/memberships" -H "authorization: Bearer $OWNER_TOKEN" \
  | jq -r --arg p "$PID" '.[] | select(.partner_id==$p) | .role')
[ "$MYROLE" = "owner" ] || { echo "  owner membership missing ($MYROLE)"; exit 1; }
MGR_PHONE="+97798$(( RANDOM % 900000 + 100000 ))"
j -X POST "$PARTNERS/v1/partner/$PID/members" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d "{\"phone\":\"$MGR_PHONE\",\"role\":\"manager\"}" >/dev/null
MGR_TOKEN=$(login "$MGR_PHONE" | jq -r '.access_token')
j -X POST "$PARTNERS/v1/partner/$PID/drivers" -H "authorization: Bearer $MGR_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"phone\":\"$DPHONE\",\"full_name\":\"Test Driver\",\"license_number\":\"DL-0001\",\"address\":\"Ghorahi-5, Dang\",\"vehicle_class\":\"two_wheeler\",\"plate_number\":\"BA-1-PA-1234\",\"model\":\"Shine\"}" >/dev/null
ROSTER=$(j "$PARTNERS/v1/partner/$PID/drivers" -H "authorization: Bearer $MGR_TOKEN" | jq 'length')
[ "$ROSTER" -ge 1 ] || { echo "  fleet roster empty"; exit 1; }
FLEET_TRIPS=$(j "$PARTNERS/v1/partner/$PID/analytics" -H "authorization: Bearer $OWNER_TOKEN" | jq -r '.trips.completed')
awk -v t="$FLEET_TRIPS" 'BEGIN{exit !(t+0>=1)}' \
  || { echo "  fleet analytics missing trips ($FLEET_TRIPS)"; exit 1; }
PID2=$(j -X POST "$PARTNERS/v1/admin/partners" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"Tulsipur Fleet\",\"owner_phone\":\"+97798$(( RANDOM % 900000 + 100000 ))\"}" | jq -r '.id')
FORBID=$(curl -sS -o /dev/null -w '%{http_code}' "$PARTNERS/v1/partner/$PID2/drivers" -H "authorization: Bearer $MGR_TOKEN")
[ "$FORBID" = "403" ] || { echo "  tenant isolation breach (got $FORBID)"; exit 1; }
echo "  partner onboarded; owner→manager→driver; fleet completed trips=$FLEET_TRIPS; cross-tenant=$FORBID (isolated)"

step "fleet partnership (phase 2: revenue-share + wallet + fleet bonus + payout)"
# A fresh approved fleet driver.
FDPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
FDLOGIN=$(login "$FDPHONE" true)
FDTOKEN=$(echo "$FDLOGIN" | jq -r '.access_token')
FDUID=$(echo "$FDLOGIN" | jq -r '.user.id')
j -X POST "$API/v1/driver/register" -H "authorization: Bearer $FDTOKEN" -H 'content-type: application/json' \
  -d '{"license_number":"DL-FLEET","address":"Ghorahi-5, Dang","vehicle":{"class":"two_wheeler","plate_number":"BA-9-PA-9","model":"Shine"}}' >/dev/null
j -X POST "$API/v1/driver/documents" -H "authorization: Bearer $FDTOKEN" \
  -F kind=license -F file=@/tmp/saarathi_lic.jpg >/dev/null
FDID=$(j "$API/v1/admin/drivers?status=queue" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg p "$FDPHONE" '.[] | select(.phone==$p) | .id' | head -n1)
j -X POST "$API/v1/admin/drivers/$FDID/approve" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
j -X POST "$PARTNERS/v1/partner/$PID/drivers" -H "authorization: Bearer $MGR_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"phone\":\"$FDPHONE\",\"full_name\":\"Fleet Driver\",\"license_number\":\"DL-FLEET\",\"address\":\"Ghorahi-5, Dang\",\"vehicle_class\":\"two_wheeler\",\"plate_number\":\"BA-9-PA-9\",\"model\":\"Shine\"}" >/dev/null

fleet_trip() { # completes a trip driven by the fleet driver via ops-assign; echoes trip id
  local t
  t=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
    -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' -d "$EBODY" | jq -r '.id')
  j -X POST "$RIDES/v1/admin/rides/$t/assign" -H "authorization: Bearer $ADMIN_TOKEN" \
    -H 'content-type: application/json' -d "{\"driver_id\":\"$FDUID\"}" >/dev/null
  for s in arriving in_progress completed; do
    j -X POST "$RIDES/v1/rides/$t/status" -H "authorization: Bearer $FDTOKEN" \
      -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
  done
  echo "$t"
}

fleet_trip >/dev/null   # first fleet trip → partner earns its revenue-share
SHARE=$(j "$PARTNERS/v1/partner/$PID/wallet" -H "authorization: Bearer $OWNER_TOKEN" | jq -r '.balance')
awk -v s="$SHARE" 'BEGIN{exit !(s+0>0)}' \
  || { echo "  partner revenue-share not accrued ($SHARE)"; exit 1; }

# Owner tops up the fleet wallet and launches a partner-funded driver bonus.
TREF=$(j -X POST "$PARTNERS/v1/partner/$PID/wallet/topup" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d '{"amount":500}' | jq -r '.reference')
j -X POST "$PARTNERS/v1/partner/$PID/wallet/topup/confirm" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d "{\"reference\":\"$TREF\"}" >/dev/null
j -X POST "$PARTNERS/v1/partner/$PID/campaigns" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d '{"code":"FLEET10","title":"Fleet bonus","kind":"flat","value":10}' >/dev/null

fleet_trip >/dev/null   # next fleet trip → partner-funded bonus paid from the wallet
FUSED=$(j "$PARTNERS/v1/partner/$PID/campaigns" -H "authorization: Bearer $OWNER_TOKEN" \
  | jq -r '.[] | select(.code=="FLEET10") | .used_count')
awk -v u="$FUSED" 'BEGIN{exit !(u+0>=1)}' || { echo "  fleet bonus not granted ($FUSED)"; exit 1; }
SPENT=$(j "$PARTNERS/v1/partner/$PID/ledger" -H "authorization: Bearer $OWNER_TOKEN" \
  | jq '[.[] | select(.kind=="promo_spend")] | length')
[ "$SPENT" -ge 1 ] || { echo "  fleet bonus not debited from wallet"; exit 1; }

PPOUT=$(j -X POST "$PARTNERS/v1/partner/$PID/payouts" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d '{}')
PPREF=$(echo "$PPOUT" | jq -r '.reference'); PPNET=$(echo "$PPOUT" | jq -r '.net')
j -X POST "$PAYMENTS/v1/psp/payout/callback" -H 'content-type: application/json' \
  -d "{\"reference\":\"$PPREF\",\"outcome\":\"paid\"}" >/dev/null
echo "  revenue-share=NPR $SHARE; wallet topup → fleet bonus used=$FUSED (debited) → payout net NPR $PPNET (settled)"

step "fleet partnership (phase 3: corporate rider tab + ledger integrity)"
# Owner puts a rider on the company tab with a monthly cap.
CRPHONE="+97797$(( RANDOM % 900000 + 100000 ))"
j -X POST "$PARTNERS/v1/partner/$PID/riders" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d "{\"phone\":\"$CRPHONE\",\"monthly_cap\":2000}" >/dev/null
CRTOKEN=$(login "$CRPHONE" | jq -r '.access_token')
# Fund the company wallet so it can cover corporate rides.
TREF2=$(j -X POST "$PARTNERS/v1/partner/$PID/wallet/topup" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d '{"amount":1000}' | jq -r '.reference')
j -X POST "$PARTNERS/v1/partner/$PID/wallet/topup/confirm" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d "{\"reference\":\"$TREF2\"}" >/dev/null
BAL0=$(j "$PARTNERS/v1/partner/$PID/wallet" -H "authorization: Bearer $OWNER_TOKEN" | jq -r '.balance')
# The corporate rider books on the company tab; a fleet driver completes it.
CT=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $CRTOKEN" \
  -H "x-idempotency-key: $(idem)" -H 'content-type: application/json' \
  -d '{"origin":{"lat":28.0336,"lng":82.4836},"dest":{"lat":28.0450,"lng":82.4970},"vehicle_class":"two_wheeler","payment_method":"corporate"}' | jq -r '.id')
j -X POST "$RIDES/v1/admin/rides/$CT/assign" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' -d "{\"driver_id\":\"$FDUID\"}" >/dev/null
for s in arriving in_progress completed; do
  j -X POST "$RIDES/v1/rides/$CT/status" -H "authorization: Bearer $FDTOKEN" \
    -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
done
CHARGED=$(j "$PARTNERS/v1/partner/$PID/ledger" -H "authorization: Bearer $OWNER_TOKEN" \
  | jq '[.[] | select(.kind=="ride_charge")] | length')
[ "$CHARGED" -ge 1 ] || { echo "  corporate ride not charged to company wallet"; exit 1; }
RIDER_CREDITS=$(j "$PAYMENTS/v1/credits" -H "authorization: Bearer $CRTOKEN" | jq -r '.balance')
awk -v b="$RIDER_CREDITS" 'BEGIN{exit !(b+0==0)}' \
  || { echo "  corporate rider charged personally ($RIDER_CREDITS)"; exit 1; }
BAL1=$(j "$PARTNERS/v1/partner/$PID/wallet" -H "authorization: Bearer $OWNER_TOKEN" | jq -r '.balance')
INTACT=$(j "$PARTNERS/v1/partner/$PID/ledger/verify" -H "authorization: Bearer $OWNER_TOKEN" | jq -r '.chain_intact')
[ "$INTACT" = "true" ] || { echo "  partner ledger chain broken"; exit 1; }
echo "  corporate tab: wallet ${BAL0} -> ${BAL1}, ride_charges=$CHARGED, rider paid NPR 0; ledger intact=$INTACT"

step "map contribution: distance-reject -> submit -> approve -> points -> badge -> redeem -> wallet credit"
CPHONE="+97795$(( RANDOM % 900000 + 100000 ))"
CTOKEN=$(login "$CPHONE" | jq -r '.access_token')
printf 'proof photo bytes' > /tmp/saarathi_place_photo.jpg

# The photo was (claimed) taken ~25km from the pin being contributed -> reject
# before it ever reaches a reviewer.
FARCODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$PLACESVC/v1/places/contributions" \
  -H "authorization: Bearer $CTOKEN" \
  -F category=building -F name="Far Building" -F lat=28.0336 -F lng=82.4836 \
  -F capture_lat=28.1 -F capture_lng=82.6 -F photo=@/tmp/saarathi_place_photo.jpg)
[ "$FARCODE" = "400" ] || { echo "  distant capture should be rejected (got $FARCODE)"; exit 1; }

# Ten approved "building"-category submissions -> 100 points (10 each) ->
# enough to redeem, enough to cross the "explorer" badge threshold (5), and
# navigable -> should surface in address search once approved.
for i in $(seq 1 10); do
  CID=$(j -X POST "$PLACESVC/v1/places/contributions" -H "authorization: Bearer $CTOKEN" \
    -F category=building -F name="Test Place $i" -F lat=28.0336 -F lng=82.4836 \
    -F capture_lat=28.0337 -F capture_lng=82.4837 -F photo=@/tmp/saarathi_place_photo.jpg | jq -r '.id')
  [ -n "$CID" ] && [ "$CID" != "null" ] || { echo "  contribution submit failed"; exit 1; }
  j -X POST "$PLACESVC/v1/admin/places/contributions/$CID/approve" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
done

PTS=$(j "$PLACESVC/v1/places/points" -H "authorization: Bearer $CTOKEN" | jq -r '.balance')
[ "$PTS" = "100" ] || { echo "  expected 100 points after 10 approvals, got $PTS"; exit 1; }
BADGE=$(j "$PLACESVC/v1/places/points" -H "authorization: Bearer $CTOKEN" | jq -r '.badges[0].code')
[ "$BADGE" = "explorer" ] || { echo "  explorer badge should auto-award at 5 approvals (got '$BADGE')"; exit 1; }

CWALLET0=$(j "$PAYMENTS/v1/credits" -H "authorization: Bearer $CTOKEN" | jq -r '.balance')
j -X POST "$PLACESVC/v1/places/points/redeem" -H "authorization: Bearer $CTOKEN" \
  -H 'content-type: application/json' -d '{"points":100}' >/dev/null
CWALLET1=$(j "$PAYMENTS/v1/credits" -H "authorization: Bearer $CTOKEN" | jq -r '.balance')
awk -v a="$CWALLET0" -v b="$CWALLET1" 'BEGIN{exit !(b-a==10)}' \
  || { echo "  redeeming 100 points should credit NPR 10 (wallet $CWALLET0 -> $CWALLET1)"; exit 1; }
PTS2=$(j "$PLACESVC/v1/places/points" -H "authorization: Bearer $CTOKEN" | jq -r '.balance')
[ "$PTS2" = "0" ] || { echo "  points balance should be 0 after full redemption (got $PTS2)"; exit 1; }
echo "  10 approved -> 100 points, explorer badge, redeemed for NPR 10 (wallet $CWALLET0 -> $CWALLET1)"

step "map contribution: approved building surfaces in rider address search"
SEARCHHIT=$(j "$RIDES/v1/geo/search?q=Test%20Place" -H "authorization: Bearer $CTOKEN" \
  | jq '[.[] | select(.label | startswith("Test Place"))] | length')
[ "$SEARCHHIT" -ge 1 ] || { echo "  approved contribution should appear in address search"; exit 1; }
echo "  approved contribution surfaced in /v1/geo/search"

printf '\n✅ SMOKE OK\n'
