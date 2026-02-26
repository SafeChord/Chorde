#!/usr/bin/env bash
set -e

# SafeChord Infrastructure: Valkey Basic Functionality Test
# Purpose: Verify Valkey connectivity, authentication, and basic SET/GET operations.

NAMESPACE="redis"
SERVICE_NAME="valkey"
POD_NAME="valkey-0" # StatefulSet naming convention

trap cleanup EXIT

cleanup() {
    echo -e "\n--- Cleanup Temporary Test Data ---"
    # Attempt to delete the test key
    if [ ! -z "$PASSWORD" ]; then
         kubectl exec -n $NAMESPACE $POD_NAME -- valkey-cli -a "$PASSWORD" DEL test_key > /dev/null 2>&1
         echo "✅ Cleanup complete."
    fi
}

echo "--- 1. Fetching Valkey Password ---"
# Decode password from Secret
PASSWORD=$(kubectl get secret redis-secret -n $NAMESPACE -o jsonpath="{.data.redis-password}" | base64 --decode)

if [ -z "$PASSWORD" ]; then
    echo "❌ ERROR: Could not retrieve password from Secret 'redis-secret'."
    exit 1
fi
echo "✅ Password retrieved."


echo -e "\n--- 2. Verify Connectivity & Authentication ---"
# Check if we can ping without password (should fail or require auth)
# Note: valkey-cli returns 'NOAUTH Authentication required.' on stderr if auth is missing
RESPONSE=$(kubectl exec -n $NAMESPACE $POD_NAME -- valkey-cli PING 2>&1 || true)
if [[ "$RESPONSE" == *"NOAUTH"* ]]; then
    echo "✅ SUCCESS: Valkey requires authentication (NOAUTH received)."
else
    # If it connects without auth, that's a security risk (unless configured otherwise)
    # But here we assume requirepass is set.
    echo "⚠️  WARNING: PING without password succeeded? Response: $RESPONSE"
fi

# Check with password
PONG=$(kubectl exec -n $NAMESPACE $POD_NAME -- valkey-cli -a "$PASSWORD" PING)
if [ "$PONG" == "PONG" ]; then
    echo "✅ SUCCESS: Authentication successful."
else
    echo "❌ FAILURE: Authentication failed. Response: $PONG"
    exit 1
fi


echo -e "\n--- 3. Basic Write/Read Test (SET/GET) ---"
TEST_VALUE="safechord-$(date +%s)"

echo "Writing key 'test_key' = '$TEST_VALUE'ப்பான"
kubectl exec -n $NAMESPACE $POD_NAME -- valkey-cli -a "$PASSWORD" SET test_key "$TEST_VALUE" > /dev/null

echo "Reading key 'test_key'ப்பான"
READ_VALUE=$(kubectl exec -n $NAMESPACE $POD_NAME -- valkey-cli -a "$PASSWORD" GET test_key | tr -d '[:space:]')

if [ "$READ_VALUE" == "$TEST_VALUE" ]; then
    echo "✅ SUCCESS: Data matches ('$READ_VALUE')."
else
    echo "❌ FAILURE: Data mismatch! Expected '$TEST_VALUE', got '$READ_VALUE'."
    exit 1
fi

echo -e "\n--- 4. Persistence Check (Info) ---"
# Just check if AOF is enabled as configured
AOF_ENABLED=$(kubectl exec -n $NAMESPACE $POD_NAME -- valkey-cli -a "$PASSWORD" INFO persistence | grep "aof_enabled:1" | tr -d '[:space:]')
if [ "$AOF_ENABLED" == "aof_enabled:1" ]; then
     echo "✅ SUCCESS: AOF Persistence is ENABLED."
else
     echo "⚠️  WARNING: AOF Persistence might be disabled. Check 'INFO persistence'."
fi
