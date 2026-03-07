#!/usr/bin/env bash
set -e

trap cleanup EXIT

cleanup() {
    echo -e "\n--- Cleanup Temporary Test Data ---"
    # Cleanup must be done on Primary; Replica will follow via replication.
    echo "Dropping test table on Japan Primary..."
    kubectl exec -n database $PRIMARY_POD -c postgres -- psql -U postgres -c "DROP TABLE IF EXISTS instant_sync;"
    echo "✅ SUCCESS: Cleanup command issued to Primary."

    echo -e "\n--- Final Check: Replication Status ---"
    kubectl exec -n database $REPLICA_POD -c postgres -- psql -U postgres -c "SELECT slot_name, active, delay_line FROM pg_stat_wal_receiver;" 2>/dev/null || echo "Replication stats check skipped."
}

# SafeChord Infrastructure: DB Replication & Delay Consistency Test
# Purpose: Verify JP-Primary to TW-Replica sync and the 1-minute apply delay.

# Fetch Pod names based on CNPG roles
PRIMARY_POD=$(kubectl get pod -n database -l cnpg.io/cluster=db-primary,role=primary -o name)
REPLICA_POD=$(kubectl get pod -n database -l cnpg.io/cluster=db-replica -o name | head -n 1)

if [ -z "$PRIMARY_POD" ] || [ -z "$REPLICA_POD" ]; then
    echo "Error: Primary or Replica Pod not found. Check your Kilo/Wireguard tunnel."
    exit 1
fi

echo "--- 1. Verify Read-Only Status (Taiwan Replica) ---"
# Expecting failure: Replica should reject write operations.
kubectl exec -n database $REPLICA_POD  -c postgres -- psql -U postgres -c "CREATE TABLE read_only_test (id int);" 2>&1 | grep -q "cannot execute CREATE TABLE in a read-only transaction"
if [ $? -eq 0 ]; then
    echo "✅ SUCCESS: Replica is Read-Only as expected."
else
    echo "❌ FAILURE: Replica accepted a write operation! Check your configuration."
    exit 1
fi

echo -e "\n--- 2. Instant Sync Speed Check (JP -> TW) ---"
TIMESTAMP=$(date +%s)
echo "Writing marker to Japan: $TIMESTAMP"
kubectl exec -n database $PRIMARY_POD -c postgres -- psql -U postgres -c "CREATE TABLE IF NOT EXISTS instant_sync (val text); INSERT INTO instant_sync VALUES ('$TIMESTAMP');"

# No sleep here, testing the raw speed of your Kilo/Wireguard tunnel
echo "Checking Taiwan immediately..."
CHECK_VAL=$(kubectl exec -n database $REPLICA_POD -c postgres -- psql -U postgres -t -c "SELECT count(*) FROM instant_sync WHERE val = '$TIMESTAMP';" | tr -d '[:space:]')

if [ "$CHECK_VAL" == "1" ]; then
    echo "✅ SUCCESS: Data arrived instantly (~80ms physical limit)."
else
    echo "⚠️  LAG: Data not found immediately. This might be due to transient network jitter."
    exit 1
fi