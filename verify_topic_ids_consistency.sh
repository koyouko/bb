#!/bin/bash

KAFKABIN=<path_to_kafka_installation>/bin
OUTPUT_FILE="topic_id_mismatch.txt"
declare -A zk_topics

while getopts ":l:z:" opt; do
  case $opt in
    l)
      LOG_DIR=$OPTARG
      ;;
    z)
      ZKSTRING=$OPTARG
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

if [[ -z $LOG_DIR || -z $ZKSTRING ]]; then
  echo "Usage: $0 -l <path_to_kafka_log_dir> -z <zk_ip_and_port_for_connection>"
  exit 1
fi

for metadata in "$LOG_DIR"/logs/*/partition.metadata; do
  topic_partition=$(awk -F'/' '{print $5}' <<< "$metadata")
  topic_name=$(sed 's/-[0-9]\+$//' <<< "$topic_partition")
  topic_id_in_md=$(grep 'topic_id' "$metadata" | awk '{print $2}')

  topic_id_in_zk="${zk_topics[$topic_name]}"
  if [[ -z $topic_id_in_zk ]]; then
    topic_id_in_zk=$("$KAFKABIN/zookeeper-shell.sh" "$ZKSTRING" get "/brokers/topics/$topic_name" | grep 'topic_id' | jq -r '.topic_id')
    zk_topics[$topic_name]=$topic_id_in_zk
  fi

  if [[ $topic_id_in_md != $topic_id_in_zk ]]; then
    echo "Found topic id mismatch for $topic_partition -- in partition metadata: $topic_id_in_md and in zookeeper: $topic_id_in_zk" >> "$OUTPUT_FILE"
  fi
done
