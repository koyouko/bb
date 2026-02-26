# Confluent MRC Kafka Benchmark Suite

## Cluster Architecture

| Component | Details |
|-----------|---------|
| Platform | Confluent for Kubernetes (CFK) on OpenShift |
| Architecture | Confluent 2.5 — Multi-Region Cluster (MRC) |
| Data Centers | **slough** (broker.10, .11, .12) · **gloucester** (broker.20, .21, .22) |
| Replication | 4 replicas per topic: 2 sync (1/DC) + 2 observers (1/DC) |
| `min.insync.replicas` | 2 |
| `observerPromotionPolicy` | `under-min-isr` — observers auto-promote to sync when ISR drops below min.insync.replicas |
| `broker.rack` | `slough` / `gloucester` |

### Replica Placement Constraint

Every benchmark topic uses this MRC placement:

```json
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
```

---

## Benchmark Plan

### Test Dimensions

| Dimension | Values |
|-----------|--------|
| **Payload size** | 2 KB, 4 KB, 64 KB, 256 KB, 1 MB |
| **Partitions** | 1, 4, 6, 12, 24, 50 |
| **Compression** | none (baseline), zstd |
| **Producer acks** | `all` (required for MRC sync replication) |
| **Auth** | mTLS (SSL with client certificates) |
| **Tools** | `kafka-producer-perf-test`, `kafka-consumer-perf-test` |

### Total Test Combinations

- 5 payloads × 6 partition counts × 2 compressions (none + zstd) = **60 producer tests + 60 consumer tests**
- Estimated runtime: ~2–3 hours (depending on cluster capacity)

### What We Measure

| Metric | Source |
|--------|--------|
| Throughput (MB/sec) | Producer + Consumer |
| Records/sec | Producer |
| Avg latency (ms) | Producer |
| P50 / P95 / P99 / P99.9 latency | Producer |
| Consumer MB/sec | Consumer |
| Rebalance time | Consumer |
| Fetch time | Consumer |

---

## Files

| File | Purpose |
|------|---------|
| `kafka-mrc-benchmark.sh` | **Full benchmark suite** — creates topics, runs all producer & consumer tests, writes CSV |
| `quick-benchmark.sh` | **Quick validation** — small subset (2 payloads × 2 partitions × 2 compressions) to verify setup |
| `generate-graphs.sh` | **Graph generation** — reads CSVs, produces PNG charts via matplotlib |

---

## Usage

### Step 1: Quick validation

```bash
chmod +x quick-benchmark.sh
./quick-benchmark.sh \
  --bootstrap <broker-bootstrap>:9092 \
  --command-config client.properties
```

### Step 2: Full benchmark

```bash
chmod +x kafka-mrc-benchmark.sh
./kafka-mrc-benchmark.sh \
  --bootstrap <broker-bootstrap>:9092 \
  --command-config client.properties \
  --output-dir ./benchmark-results \
  --num-records 500000
```

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--bootstrap` | `localhost:9092` | Kafka bootstrap server |
| `--output-dir` | `./benchmark-results` | Where to store results |
| `--num-records` | `500000` | Base record count (auto-scaled for large payloads) |
| `--dry-run` | – | Print commands without executing |
| `--skip-topic-create` | – | Skip topic creation |
| `--cleanup` | – | Delete benchmark topics after run |
| `--command-config` | – | Client properties file (SASL/SSL) |

### Step 3: Generate graphs

```bash
pip install matplotlib pandas  # if not already installed
chmod +x generate-graphs.sh
./generate-graphs.sh ./benchmark-results/<timestamp>
```

### Step 4: Review results

```
benchmark-results/<timestamp>/
├── raw/                          # Raw output from each test
├── summary/
│   ├── all_results.csv           # Master producer CSV
│   ├── consumer_results.csv      # Master consumer CSV
│   └── benchmark_report.txt      # ASCII summary table
├── graphs/                       # PNG charts
│   ├── throughput_vs_partitions_*.png
│   ├── latency_vs_partitions_*.png
│   ├── throughput_vs_payload_*.png
│   ├── compression_*.png
│   ├── heatmap_throughput.png
│   ├── heatmap_latency_p99.png
│   ├── consumer_throughput_*.png
│   └── prod_vs_cons_*.png
├── topic-configs/
│   └── mrc-placement.json
├── payloads/                     # Generated test payload files
└── benchmark.log                 # Full execution log
```

---

## Graphs Produced

1. **Throughput vs Partitions** (per payload, all compressions overlaid)
2. **Latency vs Partitions** (avg / P95 / P99 / P99.9, no compression)
3. **Throughput vs Payload Size** (per partition count, bar chart)
4. **Compression Comparison** (throughput + P99 side-by-side horizontal bars)
5. **Throughput Heatmap** (partitions × payload matrix, no compression)
6. **P99 Latency Heatmap** (partitions × payload matrix, no compression)
7. **Consumer Throughput** (bar chart per payload)
8. **Producer vs Consumer** (side-by-side comparison)

---

## Notes for CFK / OpenShift

- The cluster uses **mTLS** authentication. A `client.properties` template is included — update the keystore/truststore paths and passwords for your CFK certificates, then pass with `--command-config client.properties`:

```properties
security.protocol=SSL
ssl.keystore.location=/path/to/client.keystore.p12
ssl.keystore.password=<password>
ssl.keystore.type=PKCS12
ssl.key.password=<password>
ssl.truststore.location=/path/to/truststore.p12
ssl.truststore.password=<password>
ssl.truststore.type=PKCS12
```

- If running inside OpenShift pods, you can exec into a Confluent tools pod:

```bash
oc exec -it <kafka-tools-pod> -- bash
# Then run the scripts from there
```

- Ensure `kafka-producer-perf-test` and `kafka-consumer-perf-test` are on the PATH (they ship with Confluent Platform).

---

## After the Benchmark

Once you have the results and graphs, provide the CSVs and PNGs back and we can compose a Confluence page with:

- Executive summary table
- All comparison charts embedded
- Observations and recommendations
- Cluster tuning suggestions based on bottlenecks found
