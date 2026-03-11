#!/usr/bin/env bash
set -e

# SafeChord Infrastructure: Kafka Connectivity Test
# Purpose: Verify Strimzi KRaft broker is reachable, can produce and consume messages.
# Usage: bash scripts/test/kafka/connectivity-test.sh

NAMESPACE="kafka"
BROKER_POD="k3han-cluster-dual-role-0"
BOOTSTRAP="localhost:9092"
TEST_TOPIC="_safechord-connectivity-test"
TEST_MESSAGE="safechord-ping-$(date +%s)"

trap cleanup EXIT

cleanup() {
    echo -e "\n--- Cleanup: Deleting test topic ---"
    kubectl exec -n "$NAMESPACE" "$BROKER_POD" -- \
        /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server "$BOOTSTRAP" \
        --delete --topic "$TEST_TOPIC" 2>/dev/null || true
    echo "✅ Cleanup done."
}

# --- 1. Broker reachability ---
echo "--- 1. Broker API Reachability ---"
kubectl exec -n "$NAMESPACE" "$BROKER_POD" -- \
    /opt/kafka/bin/kafka-broker-api-versions.sh \
    --bootstrap-server "$BOOTSTRAP" > /dev/null
echo "✅ SUCCESS: Broker is reachable."

# --- 2. Create test topic ---
echo -e "\n--- 2. Create Test Topic ---"
kubectl exec -n "$NAMESPACE" "$BROKER_POD" -- \
    /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$BOOTSTRAP" \
    --create --topic "$TEST_TOPIC" \
    --partitions 1 --replication-factor 1 \
    --if-not-exists
echo "✅ SUCCESS: Topic '$TEST_TOPIC' created."

# --- 3. Produce a message ---
echo -e "\n--- 3. Produce Test Message ---"
echo "Message: $TEST_MESSAGE"
echo "$TEST_MESSAGE" | kubectl exec -i -n "$NAMESPACE" "$BROKER_POD" -- \
    /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server "$BOOTSTRAP" \
    --topic "$TEST_TOPIC"
echo "✅ SUCCESS: Message produced."

# --- 4. Consume and verify ---
echo -e "\n--- 4. Consume and Verify ---"
RECEIVED=$(kubectl exec -n "$NAMESPACE" "$BROKER_POD" -- \
    /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server "$BOOTSTRAP" \
    --topic "$TEST_TOPIC" \
    --from-beginning \
    --max-messages 1 \
    --timeout-ms 10000 \
    2>/dev/null | tr -d '[:space:]')

if [ "$RECEIVED" = "$(echo "$TEST_MESSAGE" | tr -d '[:space:]')" ]; then
    echo "✅ SUCCESS: Message round-trip verified. Received: $RECEIVED"
else
    echo "❌ FAILURE: Message mismatch."
    echo "  Sent:     $TEST_MESSAGE"
    echo "  Received: $RECEIVED"
    exit 1
fi
