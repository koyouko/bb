#!/bin/bash

# Set Kafka broker address
KAFKA_BROKER="localhost:9092"

# Get the full description of all topics
ALL_TOPICS_DESCRIPTION=$(kafka-topics.sh --bootstrap-server $KAFKA_BROKER --describe)

# Filter out the replication factor information and print it out
echo "$ALL_TOPICS_DESCRIPTION" | grep -oE 'Topic: [a-zA-Z0-9_-]+.*ReplicationFactor: [0-9]+' | while read -r line ; do
    TOPIC_NAME=$(echo $line | grep -oE 'Topic: [a-zA-Z0-9_-]+' | cut -d ":" -f 2|sed -r 's/()+//g')
    REPLICATION_FACTOR=$(echo $line | grep -oE 'ReplicationFactor: [0-9]+' | cut -d ":" -f 2|sed -r 's/()+//g')

    # Check if the replication factor is less than 4
    if [ "$REPLICATION_FACTOR" -lt 4 ]
    then
        echo "The topic $TOPIC_NAME has a replication factor of $REPLICATION_FACTOR, which is less than 4." >> topics.txt
    fi
done

# Get all topic configurations at once
ALL_TOPIC_CONFIGS=$(kafka-configs.sh --bootstrap-server $KAFKA_BROKER --entity-type topics --describe)

# Print each topic configuration line by line
echo "$ALL_TOPIC_CONFIGS" | while read -r line
do
    # Check if the line contains min.insync.replicas configuration
    if echo "$line" | grep -q "min.insync.replicas"; then
        TOPIC_NAME=$(echo "$line" | awk -F'\t' '{print $2}')
        MIN_INSYNC_REPLICAS=$(echo "$line" | grep -oE 'min\.insync\.replicas=[0-9]+' | cut -d "=" -f 2)

        # Check if min.insync.replicas is not 2
        if [ "$MIN_INSYNC_REPLICAS" != "2" ]; then
            echo "The topic $TOPIC_NAME does not have min.insync.replicas set to 2. Its min.insync.replicas is $MIN_INSYNC_REPLICAS." >> minInSyncReplicas.txt
        fi
    else
        TOPIC_NAME=$(echo "$line" | awk -F'\t' '{print $2}')
        echo "The topic $TOPIC_NAME does not have min.insync.replicas configured." >> minInSyncReplicas.txt
    fi
done
