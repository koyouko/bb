#!/bin/sh

OUTPUT_FILE="topic_id_mismatch.txt"

while getopts "l:z:p:b:" opt; do
  case $opt in
    l)
      LOG_DIR=$OPTARG
      ;;
    z)
      ZKSTRING=$OPTARG
      ;;
    p)
      PARTITION_PREFIX=$OPTARG
      ;;
    b)
      KAFKABIN=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

if [ -z "$LOG_DIR" ] || [ -z "$ZKSTRING" ] || [ -z "$PARTITION_PREFIX" ] || [ -z "$KAFKABIN" ]; then
  echo "Usage: $0 -l <path_to_kafka_log_dir> -z <zk_ip_and_port_for_connection> -p <partition_prefix> -b <path_to_kafka_bin>"
  exit 1
fi

for metadata in "$LOG_DIR"/logs/*/"$PARTITION_PREFIX"*; do
  topic_partition=$(echo "$metadata" | awk -F'/' '{print $5}')
  topic_name=$(echo "$topic_partition" | sed 's/-[0-9]\+$//')
  topic_id_in_md=$(grep 'topic_id' "$metadata" | awk '{print $2}')

  topic_id_in_zk=""
  for topic_data in $(echo "get /brokers/topics/$topic_name" | "$KAFKABIN/zookeeper-shell.sh" "$ZKSTRING" | grep 'topic_id'); do
    if [ -z "$topic_id_in_zk" ]; then
      topic_id_in_zk=$(echo "$topic_data" | jq -r '.topic_id')
    fi
  done

  if [ "$topic_id_in_md" != "$topic_id_in_zk" ]; then
    echo "Found topic id mismatch for $topic_partition -- in partition metadata: $topic_id_in_md and in zookeeper: $topic_id_in_zk" >> "$OUTPUT_FILE"
  fi
done