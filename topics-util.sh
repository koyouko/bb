#!/bin/bash

# Set Kafka broker address and output file
KAFKA_BROKER="localhost:9092"
OUTPUT_FILE="replication_factor_output.txt"

# Get the full description of all topics
ALL_TOPICS_DESCRIPTION=$(kafka-topics.sh --bootstrap-server $KAFKA_BROKER --describe)

# Filter out the replication factor information
echo "$ALL_TOPICS_DESCRIPTION" | grep -oE 'Topic:[a-zA-Z0-9_-]+.*ReplicationFactor:[0-9]+' | while read -r line ; do
    TOPIC_NAME=$(echo $line | grep -oE 'Topic:[a-zA-Z0-9_-]+' | cut -d ":" -f 2)
    REPLICATION_FACTOR=$(echo $line | grep -oE 'ReplicationFactor:[0-9]+' | cut -d ":" -f 2)

    # Check if the replication factor is 4 or less
    if [ "$REPLICATION_FACTOR" -le 4 ]
    then
        echo "The topic $TOPIC_NAME has a replication factor of $REPLICATION_FACTOR." >> $OUTPUT_FILE
    fi
done

echo "Results are saved in $OUTPUT_FILE"
