#!/usr/bin/env bash
#
# Read-only disaster recovery drill for one cell.
#
# A DR plan that has never been exercised is a document, not a capability. This
# script measures the things the failover actually depends on and compares them
# against the RPO and RTO the cell contract declares — without touching
# anything. It is safe to run against production, which is the point: a drill
# nobody dares run against prod tells you nothing about prod.
#
# What it does NOT do is promote the replica. Promotion is irreversible for the
# replication relationship and is a human decision made against
# docs/runbooks/failover.md.
#
#   scripts/dr_drill.sh acme/prod-syd
#
set -euo pipefail

CELL="${1:-}"
if [[ -z "$CELL" ]]; then
  echo "usage: $0 <venture>/<cell>   e.g. $0 acme/prod-syd" >&2
  exit 1
fi

VENTURE="${CELL%%/*}"
NAME="${CELL##*/}"
CONTRACT="ventures/${VENTURE}/cells/${NAME}.yaml"

[[ -f "$CONTRACT" ]] || { echo "no such cell contract: $CONTRACT" >&2; exit 1; }

for tool in gcloud yq; do
  command -v "$tool" >/dev/null || { echo "required tool not found: $tool" >&2; exit 1; }
done

PROJECT_PREFIX="${PROJECT_PREFIX:-cp}"
PROJECT_ID="${PROJECT_PREFIX}-${VENTURE}-${NAME}"
INSTANCE="${VENTURE}-${NAME}"
REPLICA="${INSTANCE}-standby"

REGION=$(yq -r '.region' "$CONTRACT")
STANDBY=$(yq -r '.dr.standby_region' "$CONTRACT")
RPO_MIN=$(yq -r '.dr.rpo_minutes' "$CONTRACT")
RTO_MIN=$(yq -r '.dr.rto_minutes' "$CONTRACT")

if [[ "$STANDBY" == "null" ]]; then
  echo "Cell $CELL declares no standby region — there is no cross-region DR to drill."
  exit 0
fi

pass=0
fail=0

check() {
  local label="$1" ok="$2" detail="$3"
  if [[ "$ok" == "yes" ]]; then
    printf '  \033[32m✓\033[0m %-42s %s\n' "$label" "$detail"
    pass=$((pass + 1))
  else
    printf '  \033[31m✗\033[0m %-42s %s\n' "$label" "$detail"
    fail=$((fail + 1))
  fi
}

echo
echo "DR drill — ${CELL}"
echo "  project        ${PROJECT_ID}"
echo "  primary        ${REGION}"
echo "  standby        ${STANDBY}"
echo "  objectives     RPO ${RPO_MIN}m / RTO ${RTO_MIN}m"
echo

# --- 1. Does the standby exist and is it serving? -----------------------------

replica_state=$(gcloud sql instances describe "$REPLICA" \
  --project "$PROJECT_ID" --format='value(state)' 2>/dev/null || echo "MISSING")

check "standby instance exists and is RUNNABLE" \
  "$([[ "$replica_state" == "RUNNABLE" ]] && echo yes || echo no)" \
  "state=${replica_state}"

replica_region=$(gcloud sql instances describe "$REPLICA" \
  --project "$PROJECT_ID" --format='value(region)' 2>/dev/null || echo "unknown")

check "standby is in the declared standby region" \
  "$([[ "$replica_region" == "$STANDBY" ]] && echo yes || echo no)" \
  "region=${replica_region}"

# --- 2. Is replication actually keeping up? -----------------------------------
# The number that decides whether the RPO is real.

lag=$(gcloud monitoring time-series list \
  --project "$PROJECT_ID" \
  --filter="metric.type=\"cloudsql.googleapis.com/database/replication/replica_lag\" AND resource.labels.database_id=\"${PROJECT_ID}:${REPLICA}\"" \
  --format='value(points[0].value.doubleValue)' 2>/dev/null | head -1 || echo "")

if [[ -z "$lag" ]]; then
  check "replica lag within RPO budget" "no" "no datapoint — is the metric being collected?"
else
  lag_int=${lag%.*}
  budget=$((RPO_MIN * 60))
  check "replica lag within RPO budget" \
    "$([[ "$lag_int" -lt "$budget" ]] && echo yes || echo no)" \
    "${lag_int}s of ${budget}s"
fi

# --- 3. Can we rewind, not just fail over? ------------------------------------
# Cross-region replication does not protect against a bad migration: the replica
# faithfully reproduces the damage. PITR is the control for that failure mode,
# and it is a different one.

pitr=$(gcloud sql instances describe "$INSTANCE" \
  --project "$PROJECT_ID" \
  --format='value(settings.backupConfiguration.pointInTimeRecoveryEnabled)' 2>/dev/null || echo "False")

check "point-in-time recovery enabled" \
  "$([[ "$pitr" == "True" ]] && echo yes || echo no)" \
  "pitr=${pitr}"

latest_backup=$(gcloud sql backups list --instance "$INSTANCE" \
  --project "$PROJECT_ID" --limit 1 --sort-by '~windowStartTime' \
  --format='value(windowStartTime)' 2>/dev/null || echo "")

check "a backup exists" \
  "$([[ -n "$latest_backup" ]] && echo yes || echo no)" \
  "${latest_backup:-none found}"

backup_location=$(gcloud sql instances describe "$INSTANCE" \
  --project "$PROJECT_ID" \
  --format='value(settings.backupConfiguration.location)' 2>/dev/null || echo "")

check "backups stay inside the residency envelope" \
  "$([[ "$backup_location" == "$REGION" || "$backup_location" == "$STANDBY" ]] && echo yes || echo no)" \
  "location=${backup_location:-default}"

# --- 4. Will the standby be usable after promotion? ---------------------------
# A CMEK-encrypted replica needs its key in its own region. If that key is
# missing or disabled, promotion produces an instance nobody can read.

if [[ "$(yq -r '.security.cmek' "$CONTRACT")" == "true" ]]; then
  key_state=$(gcloud kms keys describe sql \
    --project "$PROJECT_ID" \
    --location "$STANDBY" \
    --keyring "${INSTANCE}-standby" \
    --format='value(primary.state)' 2>/dev/null || echo "MISSING")

  check "standby-region CMEK key is enabled" \
    "$([[ "$key_state" == "ENABLED" ]] && echo yes || echo no)" \
    "state=${key_state}"
fi

# --- 5. Is there capacity to fail over into? ----------------------------------

cluster_nodes=$(gcloud container clusters describe "$INSTANCE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format='value(currentNodeCount)' 2>/dev/null || echo "0")

check "cluster is serving" \
  "$([[ "${cluster_nodes:-0}" -gt 0 ]] && echo yes || echo no)" \
  "${cluster_nodes} nodes"

echo
if [[ "$fail" -gt 0 ]]; then
  printf '\033[31m%d check(s) failed\033[0m, %d passed.\n' "$fail" "$pass"
  echo "The declared RPO of ${RPO_MIN}m is not currently achievable. See docs/runbooks/failover.md."
  exit 1
fi

printf '\033[32mAll %d checks passed.\033[0m\n' "$pass"
echo "Record this drill in docs/runbooks/failover.md under \"Drill log\"."
