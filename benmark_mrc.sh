#!/usr/bin/env bash
###############################################################################
#  Confluent Kafka MRC Benchmark Suite
#  ────────────────────────────────────
#  Cluster : Confluent for Kubernetes (CFK) on OpenShift
#  Arch    : Confluent 2.5 – Multi-Region Cluster (MRC)
#  Racks   : slough  (broker.10, broker.11, broker.12)
#            gloucester (broker.20, broker.21, broker.22)
#  Replicas: 4 total  → 2 sync (1 per DC) + 2 observers (1 per DC)
#
#  Usage   : ./kafka-mrc-benchmark.sh [OPTIONS]
#            --bootstrap  <host:port>   Bootstrap server (default: localhost:9092)
#            --output-dir <dir>         Output directory  (default: ./benchmark-results)
#            --num-records <n>          Records per test  (default: 500000)
#            --dry-run                  Print commands without executing
#            --skip-topic-create        Skip topic creation (topics already exist)
#            --cleanup                  Delete benchmark topics after run
#            --command-config <file>    Client properties file (for auth/SSL)
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
BOOTSTRAP="localhost:9092"
OUTPUT_DIR="./benchmark-results"
NUM_RECORDS=500000
DRY_RUN=false
SKIP_TOPIC_CREATE=false
CLEANUP=false
COMMAND_CONFIG=""
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ─── Parse CLI args ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap)       BOOTSTRAP="$2";        shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2";        shift 2 ;;
    --num-records)     NUM_RECORDS="$2";       shift 2 ;;
    --dry-run)         DRY_RUN=true;           shift   ;;
    --skip-topic-create) SKIP_TOPIC_CREATE=true; shift ;;
    --cleanup)         CLEANUP=true;           shift   ;;
    --command-config)  COMMAND_CONFIG="$2";    shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Directories ─────────────────────────────────────────────────────────────
RESULTS_DIR="${OUTPUT_DIR}/${TIMESTAMP}"
RAW_DIR="${RESULTS_DIR}/raw"
SUMMARY_DIR="${RESULTS_DIR}/summary"
TOPICS_DIR="${RESULTS_DIR}/topic-configs"
mkdir -p "$RAW_DIR" "$SUMMARY_DIR" "$TOPICS_DIR"

# ─── Auth flag helper ────────────────────────────────────────────────────────
CMD_CFG_FLAG=""
PRODUCER_CFG_FLAG=""
CONSUMER_CFG_FLAG=""
if [[ -n "$COMMAND_CONFIG" ]]; then
  CMD_CFG_FLAG="--command-config $COMMAND_CONFIG"
  PRODUCER_CFG_FLAG="--producer.config $COMMAND_CONFIG"
  CONSUMER_CFG_FLAG="--consumer.config $COMMAND_CONFIG"
fi

# ─── Logging ─────────────────────────────────────────────────────────────────
LOG_FILE="${RESULTS_DIR}/benchmark.log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

run_cmd() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*" | tee -a "$LOG_FILE"
  else
    log "EXEC: $*"
    eval "$@" 2>&1
  fi
}

# ─── Benchmark Matrix ────────────────────────────────────────────────────────
# Payload sizes in bytes
declare -A PAYLOAD_SIZES=(
  ["2KB"]=2048
  ["4KB"]=4096
  ["64KB"]=65536
  ["256KB"]=262144
  ["1MB"]=1048576
)

# Partition counts – scale up; with larger partitions we use bigger payloads
PARTITION_COUNTS=(1 4 6 12 24 50)

# Compression codecs — zstd only (+ none as baseline)
COMPRESSIONS=("none" "zstd")

# ─── MRC Replica Placement JSON ─────────────────────────────────────────────
# 2 sync replicas (1 slough, 1 gloucester) + 2 observers (1 slough, 1 gloucester)
generate_placement_json() {
  local file="$1"
  cat > "$file" <<'PLACEMENT'
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
PLACEMENT
  log "Generated replica placement JSON → $file"
}

PLACEMENT_FILE="${TOPICS_DIR}/mrc-placement.json"
generate_placement_json "$PLACEMENT_FILE"

# ─── Topic naming convention ─────────────────────────────────────────────────
# bench-<partitions>p-<payload>-<compression>
topic_name() {
  local partitions=$1 payload_label=$2 compression=$3
  echo "bench-${partitions}p-${payload_label}-${compression}"
}

# ─── Create benchmark topics ────────────────────────────────────────────────
create_topic() {
  local name=$1 partitions=$2
  log "Creating topic: $name  partitions=$partitions  replicas=4 (2 sync + 2 observer)"
  run_cmd kafka-topics --bootstrap-server "$BOOTSTRAP" $CMD_CFG_FLAG \
    --create --if-not-exists \
    --topic "$name" \
    --partitions "$partitions" \
    --replication-factor 4 \
    --config min.insync.replicas=2 \
    --config confluent.placement.constraints="$(cat "$PLACEMENT_FILE")"
}

delete_topic() {
  local name=$1
  log "Deleting topic: $name"
  run_cmd kafka-topics --bootstrap-server "$BOOTSTRAP" $CMD_CFG_FLAG \
    --delete --topic "$name" 2>/dev/null || true
}

# ─── Throughput calculator helper ────────────────────────────────────────────
# kafka-producer-perf-test output last line example:
#   500000 records sent, 83472.4 records/sec (81.51 MB/sec), 320.1 ms avg latency, 1205.0 ms max latency, 280 ms 50th, 890 ms 95th, 1100 ms 99th, 1180 ms 99.9th.
parse_producer_output() {
  local file=$1
  # Grab the final summary line
  tail -1 "$file"
}

parse_consumer_output() {
  local file=$1
  # kafka-consumer-perf-test outputs CSV-like lines
  # start.time, end.time, data.consumed.in.MB, MB.sec, data.consumed.in.nMsg, nMsg.sec, rebalance.time.ms, fetch.time.ms, fetch.MB.sec, fetch.nMsg.sec
  tail -1 "$file"
}

# ─── Generate payload files ─────────────────────────────────────────────────
PAYLOAD_DIR="${RESULTS_DIR}/payloads"
mkdir -p "$PAYLOAD_DIR"

generate_payloads() {
  for label in "${!PAYLOAD_SIZES[@]}"; do
    local size=${PAYLOAD_SIZES[$label]}
    local file="${PAYLOAD_DIR}/payload_${label}.bin"
    if [[ ! -f "$file" ]]; then
      head -c "$size" /dev/urandom > "$file"
      log "Generated payload file: $file ($label = $size bytes)"
    fi
  done
}

generate_payloads

# ─── Adjust num-records for large payloads to keep test duration sane ────────
adjusted_records() {
  local payload_bytes=$1
  if (( payload_bytes >= 1048576 )); then
    echo $(( NUM_RECORDS / 10 ))      # 1MB → 1/10th records
  elif (( payload_bytes >= 262144 )); then
    echo $(( NUM_RECORDS / 5 ))       # 256KB → 1/5th records
  elif (( payload_bytes >= 65536 )); then
    echo $(( NUM_RECORDS / 2 ))       # 64KB → 1/2 records
  else
    echo "$NUM_RECORDS"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  MASTER CSV — every result row goes here for later graphing
# ═════════════════════════════════════════════════════════════════════════════
MASTER_CSV="${SUMMARY_DIR}/all_results.csv"
echo "test_type,topic,partitions,payload,compression,records_sent,records_per_sec,mb_per_sec,avg_latency_ms,max_latency_ms,p50_ms,p95_ms,p99_ms,p999_ms" \
  > "$MASTER_CSV"

CONSUMER_CSV="${SUMMARY_DIR}/consumer_results.csv"
echo "test_type,topic,partitions,payload,compression,data_consumed_mb,mb_per_sec,total_msgs,msgs_per_sec,rebalance_ms,fetch_time_ms" \
  > "$CONSUMER_CSV"

# ─── Producer perf test wrapper ──────────────────────────────────────────────
run_producer_perf() {
  local topic=$1 partitions=$2 payload_label=$3 compression=$4
  local payload_bytes=${PAYLOAD_SIZES[$payload_label]}
  local records
  records=$(adjusted_records "$payload_bytes")
  local out_file="${RAW_DIR}/producer_${topic}.txt"
  local throughput_rate="-1"   # unlimited

  log "━━━ PRODUCER TEST ━━━ topic=$topic partitions=$partitions payload=$payload_label compression=$compression records=$records"

  local extra_props="acks=all"
  if [[ "$compression" != "none" ]]; then
    extra_props="${extra_props},compression.type=${compression}"
  fi

  run_cmd kafka-producer-perf-test \
    --topic "$topic" \
    --num-records "$records" \
    --record-size "$payload_bytes" \
    --throughput "$throughput_rate" \
    --producer-props bootstrap.servers="$BOOTSTRAP" "$extra_props" \
    ${PRODUCER_CFG_FLAG} \
    2>&1 | tee "$out_file"

  if ! $DRY_RUN; then
    # Parse summary line
    local summary
    summary=$(parse_producer_output "$out_file")
    # Extract metrics with awk
    local recs_sec mb_sec avg_lat max_lat p50 p95 p99 p999
    recs_sec=$(echo "$summary" | grep -oP '[\d.]+(?= records/sec)')
    mb_sec=$(echo "$summary"   | grep -oP '[\d.]+(?= MB/sec)')
    avg_lat=$(echo "$summary"  | grep -oP '[\d.]+(?= ms avg latency)')
    max_lat=$(echo "$summary"  | grep -oP '[\d.]+(?= ms max latency)')
    p50=$(echo "$summary"      | grep -oP '[\d.]+(?= ms 50th)')
    p95=$(echo "$summary"      | grep -oP '[\d.]+(?= ms 95th)')
    p99=$(echo "$summary"      | grep -oP '[\d.]+(?= ms 99th)')
    p999=$(echo "$summary"     | grep -oP '[\d.]+(?= ms 99.9th)')

    echo "producer,$topic,$partitions,$payload_label,$compression,$records,$recs_sec,$mb_sec,$avg_lat,$max_lat,$p50,$p95,$p99,$p999" \
      >> "$MASTER_CSV"

    log "  → records/sec=$recs_sec  MB/sec=$mb_sec  avg_lat=${avg_lat}ms  p99=${p99}ms"
  fi
}

# ─── Consumer perf test wrapper ──────────────────────────────────────────────
run_consumer_perf() {
  local topic=$1 partitions=$2 payload_label=$3 compression=$4
  local payload_bytes=${PAYLOAD_SIZES[$payload_label]}
  local records
  records=$(adjusted_records "$payload_bytes")
  local out_file="${RAW_DIR}/consumer_${topic}.txt"
  local group="bench-consumer-group-${topic}"

  log "━━━ CONSUMER TEST ━━━ topic=$topic group=$group"

  run_cmd kafka-consumer-perf-test \
    --bootstrap-server "$BOOTSTRAP" \
    --topic "$topic" \
    --group "$group" \
    --messages "$records" \
    --show-detailed-stats \
    --print-metrics \
    ${CONSUMER_CFG_FLAG} \
    2>&1 | tee "$out_file"

  if ! $DRY_RUN; then
    local summary
    summary=$(parse_consumer_output "$out_file")
    # CSV columns: start.time, end.time, data.consumed.in.MB, MB.sec, data.consumed.in.nMsg, nMsg.sec, rebalance.time.ms, fetch.time.ms, fetch.MB.sec, fetch.nMsg.sec
    local data_mb mb_sec total_msgs msgs_sec rebal_ms fetch_ms
    data_mb=$(echo "$summary"   | awk -F', ' '{print $3}')
    mb_sec=$(echo "$summary"    | awk -F', ' '{print $4}')
    total_msgs=$(echo "$summary"| awk -F', ' '{print $5}')
    msgs_sec=$(echo "$summary"  | awk -F', ' '{print $6}')
    rebal_ms=$(echo "$summary"  | awk -F', ' '{print $7}')
    fetch_ms=$(echo "$summary"  | awk -F', ' '{print $8}')

    echo "consumer,$topic,$partitions,$payload_label,$compression,$data_mb,$mb_sec,$total_msgs,$msgs_sec,$rebal_ms,$fetch_ms" \
      >> "$CONSUMER_CSV"

    log "  → MB/sec=$mb_sec  msgs/sec=$msgs_sec  rebalance=${rebal_ms}ms"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
#  BENCHMARK EXECUTION PLAN
# ═════════════════════════════════════════════════════════════════════════════
log "╔══════════════════════════════════════════════════════════════════════╗"
log "║           CONFLUENT MRC BENCHMARK SUITE — START                    ║"
log "║  Bootstrap : $BOOTSTRAP"
log "║  Output    : $RESULTS_DIR"
log "║  Records   : $NUM_RECORDS (base, adjusted for large payloads)"
log "║  Timestamp : $TIMESTAMP"
log "╚══════════════════════════════════════════════════════════════════════╝"

# ─── Phase 1: Create all benchmark topics ────────────────────────────────────
if ! $SKIP_TOPIC_CREATE; then
  log "═══ PHASE 1: TOPIC CREATION ═══"
  for partitions in "${PARTITION_COUNTS[@]}"; do
    for payload_label in "${!PAYLOAD_SIZES[@]}"; do
      for compression in "${COMPRESSIONS[@]}"; do
        t=$(topic_name "$partitions" "$payload_label" "$compression")
        create_topic "$t" "$partitions"
      done
    done
  done
  log "Topic creation complete. Waiting 10s for metadata propagation..."
  sleep 10
else
  log "Skipping topic creation (--skip-topic-create)"
fi

# ─── Phase 2: Producer benchmarks ───────────────────────────────────────────
log "═══ PHASE 2: PRODUCER BENCHMARKS ═══"
for partitions in "${PARTITION_COUNTS[@]}"; do
  for payload_label in "${!PAYLOAD_SIZES[@]}"; do
    for compression in "${COMPRESSIONS[@]}"; do
      t=$(topic_name "$partitions" "$payload_label" "$compression")
      run_producer_perf "$t" "$partitions" "$payload_label" "$compression"
      # Brief cooldown between tests
      sleep 5
    done
  done
done

# ─── Phase 3: Consumer benchmarks ───────────────────────────────────────────
log "═══ PHASE 3: CONSUMER BENCHMARKS ═══"
for partitions in "${PARTITION_COUNTS[@]}"; do
  for payload_label in "${!PAYLOAD_SIZES[@]}"; do
    for compression in "${COMPRESSIONS[@]}"; do
      t=$(topic_name "$partitions" "$payload_label" "$compression")
      run_consumer_perf "$t" "$partitions" "$payload_label" "$compression"
      sleep 3
    done
  done
done

# ─── Phase 4 (optional): Cleanup topics ─────────────────────────────────────
if $CLEANUP; then
  log "═══ PHASE 4: CLEANUP ═══"
  for partitions in "${PARTITION_COUNTS[@]}"; do
    for payload_label in "${!PAYLOAD_SIZES[@]}"; do
      for compression in "${COMPRESSIONS[@]}"; do
        t=$(topic_name "$partitions" "$payload_label" "$compression")
        delete_topic "$t"
      done
    done
  done
fi

# ═════════════════════════════════════════════════════════════════════════════
#  SUMMARY REPORT
# ═════════════════════════════════════════════════════════════════════════════
REPORT="${SUMMARY_DIR}/benchmark_report.txt"

{
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║              CONFLUENT MRC BENCHMARK REPORT                        ║"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo "║  Date      : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "║  Bootstrap : $BOOTSTRAP"
  echo "║  Cluster   : CFK on OpenShift – MRC (slough / gloucester)"
  echo "║  Replicas  : 4 total (2 sync + 2 observers)"
  echo "║  Records   : $NUM_RECORDS (base)"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "──────────────────────────────────────────────────────────────────────"
  echo "  PRODUCER RESULTS"
  echo "──────────────────────────────────────────────────────────────────────"
  printf "%-45s %10s %10s %10s %10s %10s %10s\n" \
    "TOPIC" "Rec/s" "MB/s" "AvgLat" "P95" "P99" "P99.9"
  echo "──────────────────────────────────────────────────────────────────────"
  tail -n +2 "$MASTER_CSV" | while IFS=',' read -r _type topic parts payload comp recs rps mbps avg mx p50 p95 p99 p999; do
    printf "%-45s %10s %10s %10s %10s %10s %10s\n" \
      "$topic" "$rps" "$mbps" "${avg}ms" "${p95}ms" "${p99}ms" "${p999}ms"
  done
  echo ""
  echo "──────────────────────────────────────────────────────────────────────"
  echo "  CONSUMER RESULTS"
  echo "──────────────────────────────────────────────────────────────────────"
  printf "%-45s %10s %10s %12s %10s\n" \
    "TOPIC" "MB/s" "Msg/s" "Rebal(ms)" "Fetch(ms)"
  echo "──────────────────────────────────────────────────────────────────────"
  tail -n +2 "$CONSUMER_CSV" | while IFS=',' read -r _type topic parts payload comp dmb mbps msgs msec rbal ftch; do
    printf "%-45s %10s %10s %12s %10s\n" \
      "$topic" "$mbps" "$msec" "$rbal" "$ftch"
  done
  echo ""
  echo "──────────────────────────────────────────────────────────────────────"
  echo "Raw results : $RAW_DIR"
  echo "CSVs        : $MASTER_CSV"
  echo "            : $CONSUMER_CSV"
  echo "──────────────────────────────────────────────────────────────────────"
} | tee "$REPORT"

log "═══ BENCHMARK COMPLETE ═══"
log "Results: $RESULTS_DIR"
log "Master CSV (producer): $MASTER_CSV"
log "Consumer CSV:          $CONSUMER_CSV"
log "Report:                $REPORT"
echo ""
echo "Next step: Run ./generate-graphs.sh $RESULTS_DIR to produce charts."
