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
DLOGIN=$(login "$DPHONE" true)
DTOKEN=$(echo "$DLOGIN" | jq -r '.access_token')
DUID=$(echo "$DLOGIN" | jq -r '.user.id')
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
  -H 'content-type: application/json' -d "$BODY" | jq -r '.error.code')
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
BTRIP=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" -H 'content-type: application/json' \
  -d "{\"origin\":{\"lat\":28.0336,\"lng\":82.4836},\"dest\":{\"lat\":28.0450,\"lng\":82.4970},\"vehicle_class\":\"two_wheeler\",\"payment_method\":\"cash\",\"offered_fare\":$FLOOR}")
AGREED=$(echo "$BTRIP" | jq -r '.gross_fare')
awk -v a="$AGREED" -v f="$FLOOR" 'BEGIN{exit !(a+0==f+0)}' \
  || { echo "  bargain not applied ($AGREED != $FLOOR)"; exit 1; }
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
  -d "{\"phone\":\"$OPHONE\",\"full_name\":\"Walk In\",\"license_number\":\"DL-9\",\"vehicle\":{\"class\":\"two_wheeler\",\"plate_number\":\"BA-2-PA-9\"}}" | jq -r '.id')
[ -n "$ODID" ] && [ "$ODID" != "null" ] || { echo "  onboard failed"; exit 1; }
printf 'license bytes' > /tmp/saarathi_lic.jpg
j -X POST "$API/v1/admin/drivers/$ODID/documents" -H "authorization: Bearer $ADMIN_TOKEN" \
  -F kind=license -F file=@/tmp/saarathi_lic.jpg >/dev/null
INQUEUE=$(j "$API/v1/admin/drivers?status=queue" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq --arg p "$OPHONE" '[.[] | select(.phone==$p)] | length')
[ "$INQUEUE" -eq 1 ] || { echo "  onboarded driver not in queue"; exit 1; }
echo "  onboarded $OPHONE on-site + license doc; in review queue"

step "driver bonus campaign"
j -X POST "$RIDES/v1/admin/campaigns" -H "authorization: Bearer $ADMIN_TOKEN" \
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
REF=$(j -X POST "$RIDES/v1/credits/topup" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d '{"amount":500}' | jq -r '.reference')
j -X POST "$RIDES/v1/credits/topup/confirm" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "{\"reference\":\"$REF\"}" >/dev/null
CREDITS0=$(j "$RIDES/v1/credits" -H "authorization: Bearer $RTOKEN" | jq -r '.balance')
echo "  credits after top-up: NPR $CREDITS0"

step "create multi-stop trip → accept → complete"
TRIPJSON=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$BODY")
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

step "payment settlement + driver payout"
CREDITS1=$(j "$RIDES/v1/credits" -H "authorization: Bearer $RTOKEN" | jq -r '.balance')
echo "  rider credits after ride: NPR $CREDITS1 (was $CREDITS0)"
awk -v a="$CREDITS1" -v b="$CREDITS0" 'BEGIN{exit !(a<b)}' \
  || { echo "  rider credits were not charged"; exit 1; }
awk -v w="$WALLET" 'BEGIN{exit !(w>0)}' \
  || { echo "  driver earnings not credited"; exit 1; }
PAID=$(j -X POST "$RIDES/v1/payouts" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' -d '{}' | jq -r '.amount')
WALLET2=$(j "$RIDES/v1/wallet" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
echo "  driver withdrew NPR $PAID; balance now NPR $WALLET2"

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

UNREAD=$(j "$RIDES/v1/notifications" -H "authorization: Bearer $RTOKEN" | jq -r '.unread')
[ "$UNREAD" -ge 1 ] || { echo "  expected notifications"; exit 1; }
echo "  rider unread notifications: $UNREAD"

EARN=$(j "$RIDES/v1/driver/analytics" -H "authorization: Bearer $DTOKEN" | jq -r '.all_time.earnings')
echo "  driver all-time earnings: NPR $EARN"

step "rider ride history"
HIST=$(j "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" | jq 'length')
[ "$HIST" -ge 1 ] || { echo "  no history"; exit 1; }
echo "  rider history: $HIST trip(s) — can re-request from any"

step "driver credits + subscription pass (0% commission)"
DREF=$(j -X POST "$RIDES/v1/driver/credits/topup" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' -d '{"amount":1000}' | jq -r '.reference')
j -X POST "$RIDES/v1/credits/topup/confirm" -H 'content-type: application/json' \
  -d "{\"reference\":\"$DREF\"}" >/dev/null
DC0=$(j "$RIDES/v1/driver/credits" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
j -X POST "$RIDES/v1/driver/subscription" -H "authorization: Bearer $DTOKEN" >/dev/null
ACTIVE=$(j "$RIDES/v1/driver/subscription" -H "authorization: Bearer $DTOKEN" | jq -r '.active')
DC1=$(j "$RIDES/v1/driver/credits" -H "authorization: Bearer $DTOKEN" | jq -r '.balance')
[ "$ACTIVE" = "true" ] || { echo "  pass not active"; exit 1; }
echo "  driver credits $DC0 → $DC1; pass active=$ACTIVE"

# A trip completed while the pass is active takes 0% commission.
j -X POST "$RIDES/v1/driver/heartbeat" -H "authorization: Bearer $DTOKEN" \
  -H 'content-type: application/json' -d '{"lat":28.0336,"lng":82.4836,"job_types":["ride"]}' >/dev/null
T2=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$BODY" | jq -r '.id')
OF=""
for _ in $(seq 1 15); do
  OF=$(j "$RIDES/v1/driver/offers" -H "authorization: Bearer $DTOKEN" \
    | jq -r --arg t "$T2" '.[] | select(.trip_id==$t) | .trip_id' | head -n1)
  [ -n "$OF" ] && break; sleep 1
done
[ -n "$OF" ] || { echo "  no offer for pass trip"; exit 1; }
j -X POST "$RIDES/v1/rides/$T2/offer/accept" -H "authorization: Bearer $DTOKEN" >/dev/null
for s in arriving in_progress completed; do
  j -X POST "$RIDES/v1/rides/$T2/status" -H "authorization: Bearer $DTOKEN" \
    -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
done
COMM=$(j "$RIDES/v1/admin/ledger" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg t "$T2" '.[] | select(.trip_id==$t) | .commission')
awk -v c="$COMM" 'BEGIN{exit !(c+0==0)}' \
  || { echo "  subscription commission not 0 ($COMM)"; exit 1; }
echo "  pass trip commission = NPR $COMM (driver kept 100% minus fund)"

DUSED=$(j "$RIDES/v1/admin/campaigns" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r '.[] | select(.code=="DRIVE5") | .used_count')
awk -v u="$DUSED" 'BEGIN{exit !(u+0>=1)}' \
  || { echo "  driver bonus not granted on completion ($DUSED)"; exit 1; }
echo "  driver bonus granted on trip completion (redemptions=$DUSED)"

step "cancellation with reason → complaints feed"
CID=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
  -H 'content-type: application/json' -d "$EBODY" | jq -r '.id')
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

step "dynamic rule-based campaign (new-customer only)"
j -X POST "$RIDES/v1/admin/campaigns" -H "authorization: Bearer $ADMIN_TOKEN" \
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
PID=$(j -X POST "$API/v1/admin/partners" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"Ghorahi Moto Fleet\",\"owner_phone\":\"$OWNER_PHONE\",\"commission_share\":0.04}" | jq -r '.id')
[ -n "$PID" ] && [ "$PID" != "null" ] || { echo "  partner create failed"; exit 1; }
OWNER_TOKEN=$(login "$OWNER_PHONE" | jq -r '.access_token')
MYROLE=$(j "$API/v1/partner/memberships" -H "authorization: Bearer $OWNER_TOKEN" \
  | jq -r --arg p "$PID" '.[] | select(.partner_id==$p) | .role')
[ "$MYROLE" = "owner" ] || { echo "  owner membership missing ($MYROLE)"; exit 1; }
MGR_PHONE="+97798$(( RANDOM % 900000 + 100000 ))"
j -X POST "$API/v1/partner/$PID/members" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d "{\"phone\":\"$MGR_PHONE\",\"role\":\"manager\"}" >/dev/null
MGR_TOKEN=$(login "$MGR_PHONE" | jq -r '.access_token')
j -X POST "$API/v1/partner/$PID/drivers" -H "authorization: Bearer $MGR_TOKEN" \
  -H 'content-type: application/json' -d "{\"phone\":\"$DPHONE\"}" >/dev/null
ROSTER=$(j "$API/v1/partner/$PID/drivers" -H "authorization: Bearer $MGR_TOKEN" | jq 'length')
[ "$ROSTER" -ge 1 ] || { echo "  fleet roster empty"; exit 1; }
FLEET_TRIPS=$(j "$RIDES/v1/partner/$PID/analytics" -H "authorization: Bearer $OWNER_TOKEN" | jq -r '.trips.completed')
awk -v t="$FLEET_TRIPS" 'BEGIN{exit !(t+0>=1)}' \
  || { echo "  fleet analytics missing trips ($FLEET_TRIPS)"; exit 1; }
PID2=$(j -X POST "$API/v1/admin/partners" -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d "{\"name\":\"Tulsipur Fleet\",\"owner_phone\":\"+97798$(( RANDOM % 900000 + 100000 ))\"}" | jq -r '.id')
FORBID=$(curl -sS -o /dev/null -w '%{http_code}' "$API/v1/partner/$PID2/drivers" -H "authorization: Bearer $MGR_TOKEN")
[ "$FORBID" = "403" ] || { echo "  tenant isolation breach (got $FORBID)"; exit 1; }
echo "  partner onboarded; owner→manager→driver; fleet completed trips=$FLEET_TRIPS; cross-tenant=$FORBID (isolated)"

step "fleet partnership (phase 2: revenue-share + wallet + fleet bonus + payout)"
# A fresh approved fleet driver (no subscription pass, so commission is non-zero).
FDPHONE="+97798$(( RANDOM % 900000 + 100000 ))"
FDLOGIN=$(login "$FDPHONE" true)
FDTOKEN=$(echo "$FDLOGIN" | jq -r '.access_token')
FDUID=$(echo "$FDLOGIN" | jq -r '.user.id')
j -X POST "$API/v1/driver/register" -H "authorization: Bearer $FDTOKEN" -H 'content-type: application/json' \
  -d '{"license_number":"DL-FLEET","vehicle":{"class":"two_wheeler","plate_number":"BA-9-PA-9"}}' >/dev/null
j -X POST "$API/v1/driver/documents" -H "authorization: Bearer $FDTOKEN" \
  -F kind=license -F file=@/tmp/saarathi_lic.jpg >/dev/null
FDID=$(j "$API/v1/admin/drivers?status=queue" -H "authorization: Bearer $ADMIN_TOKEN" \
  | jq -r --arg p "$FDPHONE" '.[] | select(.phone==$p) | .id' | head -n1)
j -X POST "$API/v1/admin/drivers/$FDID/approve" -H "authorization: Bearer $ADMIN_TOKEN" >/dev/null
j -X POST "$API/v1/partner/$PID/drivers" -H "authorization: Bearer $MGR_TOKEN" \
  -H 'content-type: application/json' -d "{\"phone\":\"$FDPHONE\"}" >/dev/null

fleet_trip() { # completes a trip driven by the fleet driver via ops-assign; echoes trip id
  local t
  t=$(j -X POST "$RIDES/v1/rides" -H "authorization: Bearer $RTOKEN" \
    -H 'content-type: application/json' -d "$EBODY" | jq -r '.id')
  j -X POST "$RIDES/v1/admin/rides/$t/assign" -H "authorization: Bearer $ADMIN_TOKEN" \
    -H 'content-type: application/json' -d "{\"driver_id\":\"$FDUID\"}" >/dev/null
  for s in arriving in_progress completed; do
    j -X POST "$RIDES/v1/rides/$t/status" -H "authorization: Bearer $FDTOKEN" \
      -H 'content-type: application/json' -d "{\"status\":\"$s\"}" >/dev/null
  done
  echo "$t"
}

fleet_trip >/dev/null   # first fleet trip → partner earns its revenue-share
SHARE=$(j "$RIDES/v1/partner/$PID/wallet" -H "authorization: Bearer $OWNER_TOKEN" | jq -r '.balance')
awk -v s="$SHARE" 'BEGIN{exit !(s+0>0)}' \
  || { echo "  partner revenue-share not accrued ($SHARE)"; exit 1; }

# Owner tops up the fleet wallet and launches a partner-funded driver bonus.
TREF=$(j -X POST "$RIDES/v1/partner/$PID/wallet/topup" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d '{"amount":500}' | jq -r '.reference')
j -X POST "$RIDES/v1/partner/$PID/wallet/topup/confirm" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d "{\"reference\":\"$TREF\"}" >/dev/null
j -X POST "$RIDES/v1/partner/$PID/campaigns" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d '{"code":"FLEET10","title":"Fleet bonus","kind":"flat","value":10}' >/dev/null

fleet_trip >/dev/null   # next fleet trip → partner-funded bonus paid from the wallet
FUSED=$(j "$RIDES/v1/partner/$PID/campaigns" -H "authorization: Bearer $OWNER_TOKEN" \
  | jq -r '.[] | select(.code=="FLEET10") | .used_count')
awk -v u="$FUSED" 'BEGIN{exit !(u+0>=1)}' || { echo "  fleet bonus not granted ($FUSED)"; exit 1; }
SPENT=$(j "$RIDES/v1/partner/$PID/ledger" -H "authorization: Bearer $OWNER_TOKEN" \
  | jq '[.[] | select(.kind=="promo_spend")] | length')
[ "$SPENT" -ge 1 ] || { echo "  fleet bonus not debited from wallet"; exit 1; }

PAYOUT=$(j -X POST "$RIDES/v1/partner/$PID/payouts" -H "authorization: Bearer $OWNER_TOKEN" \
  -H 'content-type: application/json' -d '{}' | jq -r '.amount')
echo "  revenue-share=NPR $SHARE; wallet topup → fleet bonus used=$FUSED (debited) → payout NPR $PAYOUT"

printf '\n✅ SMOKE OK\n'
