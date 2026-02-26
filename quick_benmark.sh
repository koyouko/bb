#!/usr/bin/env bash
###############################################################################
#  Quick Benchmark — runs a focused subset for fast validation
#  Use this first to verify everything works before the full suite.
#
#  Usage: ./quick-benchmark.sh --bootstrap <host:port> [--command-config <file>]
###############################################################################
set -euo pipefail

BOOTSTRAP="${2:-localhost:9092}"
CMD_CFG=""
COMMAND_CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap)      BOOTSTRAP="$2"; shift 2 ;;
    --command-config) COMMAND_CONFIG="$2"; CMD_CFG="--command-config $2"; shift 2 ;;
    *) shift ;;
  esac
done

PRODUCER_CFG=""
[[ -n "$COMMAND_CONFIG" ]] && PRODUCER_CFG="--producer.config $COMMAND_CONFIG"
CONSUMER_CFG=""
[[ -n "$COMMAND_CONFIG" ]] && CONSUMER_CFG="--consumer.config $COMMAND_CONFIG"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="./quick-bench-${TIMESTAMP}"
mkdir -p "$OUT_DIR"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         QUICK MRC BENCHMARK — VALIDATION RUN               ║"
echo "║  Bootstrap: $BOOTSTRAP"
echo "║  Output:    $OUT_DIR"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Replica placement JSON ──────────────────────────────────────────────────
PLACEMENT_FILE="${OUT_DIR}/placement.json"
cat > "$PLACEMENT_FILE" <<'EOF'
{
  "version": 2,
  "replicas": [
    { "count": 1, "constraints": { "rack": "slough" } },
    { "count": 1, "constraints": { "rack": "gloucester" } }
  ],
  "observers": [
    { "count": 1, "constraints": { "rack": "slough" } },
    { "count": 1, "constraints": { "rack": "gloucester" } }
  ],
  "observerPromotionPolicy": "under-min-isr"
}
EOF

PLACEMENT=$(cat "$PLACEMENT_FILE")

# ── Quick test matrix ───────────────────────────────────────────────────────
PARTITIONS=(1 6)
PAYLOADS=("4096" "1048576")
PAYLOAD_LABELS=("4KB" "1MB")
COMPRESSIONS=("none" "zstd")
NUM_RECORDS=50000

echo ""
echo "Test matrix: ${#PARTITIONS[@]} partition configs × ${#PAYLOADS[@]} payloads × ${#COMPRESSIONS[@]} compressions"
echo "Records per test: $NUM_RECORDS"
echo ""

CSV="${OUT_DIR}/quick_results.csv"
echo "topic,partitions,payload,compression,records_per_sec,mb_per_sec,avg_latency_ms,p95_ms,p99_ms,p999_ms" > "$CSV"

for p in "${PARTITIONS[@]}"; do
  for i in "${!PAYLOADS[@]}"; do
    size=${PAYLOADS[$i]}
    label=${PAYLOAD_LABELS[$i]}
    for comp in "${COMPRESSIONS[@]}"; do
      TOPIC="quick-bench-${p}p-${label}-${comp}"

      echo "━━━ Creating topic: $TOPIC (${p} partitions, 4 replicas) ━━━"
      kafka-topics --bootstrap-server "$BOOTSTRAP" $CMD_CFG \
        --create --if-not-exists \
        --topic "$TOPIC" \
        --partitions "$p" \
        --replication-factor 4 \
        --config min.insync.replicas=2 \
        --config "confluent.placement.constraints=${PLACEMENT}" \
        2>&1 || echo "  (topic may already exist)"

      sleep 2

      # Adjust records for 1MB payload
      recs=$NUM_RECORDS
      (( size >= 1048576 )) && recs=$(( NUM_RECORDS / 10 ))

      EXTRA="acks=all"
      [[ "$comp" != "none" ]] && EXTRA="${EXTRA},compression.type=${comp}"

      echo "━━━ Producer test: $TOPIC ━━━"
      RAW_FILE="${OUT_DIR}/raw_${TOPIC}.txt"
      kafka-producer-perf-test \
        --topic "$TOPIC" \
        --num-records "$recs" \
        --record-size "$size" \
        --throughput -1 \
        --producer-props bootstrap.servers="$BOOTSTRAP" $EXTRA \
        $PRODUCER_CFG \
        2>&1 | tee "$RAW_FILE"

      # Parse last line
      SUMMARY=$(tail -1 "$RAW_FILE")
      rps=$(echo "$SUMMARY" | grep -oP '[\d.]+(?= records/sec)' || echo "N/A")
      mbps=$(echo "$SUMMARY" | grep -oP '[\d.]+(?= MB/sec)' || echo "N/A")
      avg=$(echo "$SUMMARY" | grep -oP '[\d.]+(?= ms avg latency)' || echo "N/A")
      p95=$(echo "$SUMMARY" | grep -oP '[\d.]+(?= ms 95th)' || echo "N/A")
      p99=$(echo "$SUMMARY" | grep -oP '[\d.]+(?= ms 99th)' || echo "N/A")
      p999=$(echo "$SUMMARY" | grep -oP '[\d.]+(?= ms 99.9th)' || echo "N/A")

      echo "$TOPIC,$p,$label,$comp,$rps,$mbps,$avg,$p95,$p99,$p999" >> "$CSV"

      echo "━━━ Consumer test: $TOPIC ━━━"
      kafka-consumer-perf-test \
        --bootstrap-server "$BOOTSTRAP" \
        --topic "$TOPIC" \
        --group "quick-cg-${TOPIC}" \
        --messages "$recs" \
        $CONSUMER_CFG \
        2>&1 | tee "${OUT_DIR}/consumer_${TOPIC}.txt"

      sleep 3
    done
  done
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  QUICK BENCHMARK RESULTS                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║ %-30s %8s %8s %8s %8s ║\n" "TOPIC" "Rec/s" "MB/s" "AvgLat" "P99"
echo "╠══════════════════════════════════════════════════════════════╣"
tail -n +2 "$CSV" | while IFS=',' read -r topic parts pl comp rps mbps avg p95 p99 p999; do
  printf "║ %-30s %8s %8s %6sms %6sms ║\n" "$topic" "$rps" "$mbps" "$avg" "$p99"
done
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Results CSV: $CSV"
echo ""
echo "If this looks good, run the full suite:"
echo "  ./kafka-mrc-benchmark.sh --bootstrap $BOOTSTRAP"
