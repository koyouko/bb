#!/bin/bash

# Kafka Topic Size Calculation Script
# Purpose:
# This runbook provides step-by-step instructions to execute a script that calculates the sizes of Kafka topics and outputs the results to a CSV file. The script fetches the list of Kafka topics based on a provided pattern or a full topic name and calculates the total size for each topic, appending the results to a CSV file. This is essential for monitoring and managing disk usage and ensuring smooth operation of the Kafka infrastructure.

# Prerequisites:
# jq must be installed on the system.
# kafka-topics.sh and other Kafka binaries must be available in the specified path in the script.
# Proper Kafka Broker address should be set in the script.
# SSH access to the server where the script is located.
# Necessary permissions to execute the script.
# Instructions:
# Login to the Server

# Login to the server where the Kafka script is stored using SSH.
# Navigate to Script Location

# Use cd to navigate to the directory where the script is stored.
# Grant Execution Permission (If Not Already Given)

# Run chmod +x script.sh to make sure the script has execute permission.
# Execute the Script

# Run the script with the required option:
# sh
# Copy code
# ./script.sh -t <topic_pattern_or_full_topic_name>
# Replace <topic_pattern_or_full_topic_name> with the desired topic pattern or full topic name.
# For example, to calculate sizes for all topics:
# sh
# Copy code
# ./script.sh -t '.*'
# Verify the Output

# Once the script has completed execution, verify the output in the CSV file.
# Use cat topic_sizes.csv to view the contents of the output file.
# The file will contain the topic names and their corresponding sizes.
# Handle Errors (If Any)

# If any errors occur during the execution of the script, refer to the error message to identify the issue and resolve it.
# Common errors may include missing prerequisites or incorrect Kafka broker addresses.
# Report

# Once verified, share the CSV file or its contents with the concerned team or individual for further analysis or action.
# Notes:
# The script should be executed by a user with the necessary permissions to access Kafka topics and calculate their sizes.
# Be cautious when using wildcards or broad patterns as this could result in the calculation of many topics, impacting the performance of the system temporarily.
# Regularly review and update the script and this runbook as necessary to accommodate changes in the environment or requirements.


# Define the path to Kafka binaries if not in the PATH
KAFKA_BIN_PATH="/path/to/kafka/bin"
BROKER="<hostname>:<port>"
OUTPUT_FILE="topic_sizes.csv"

# Function to print the usage of the script
print_usage() {
    echo "Usage: $0 -t <topic_pattern_or_full_topic_name>"
    exit 1
}

# Check if jq is available
command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is not installed."
    exit 1
}

# Check if kafka-topics.sh is available
command -v "${KAFKA_BIN_PATH}/kafka-topics.sh" >/dev/null 2>&1 || {
    echo "Error: kafka-topics.sh not found in $KAFKA_BIN_PATH."
    exit 1
}

# Parse the options
while getopts ":t:" opt; do
    case $opt in
    t)
        TOPIC_PATTERN="$OPTARG"
        ;;
    \?)
        echo "Invalid option: -$OPTARG" >&2
        print_usage
        ;;
    :)
        echo "Option -$OPTARG requires an argument." >&2
        print_usage
        ;;
    esac
done

# Check if TOPIC_PATTERN is set
if [[ -z "$TOPIC_PATTERN" ]]; then
    echo "Error: Topic pattern or name is not provided."
    print_usage
fi

# Initialize the CSV file with headers
echo "Topic,Size" >"$OUTPUT_FILE"

# Fetch the list of topics matching the given pattern or topic name
TOPICS=$("${KAFKA_BIN_PATH}/kafka-topics.sh" --bootstrap-server "$BROKER" --list --exclude-internal | grep "$TOPIC_PATTERN")

# Loop through the topics and calculate the size
for TOPIC in $TOPICS; do
    SIZE=$(kafka-log-dirs \
               --bootstrap-server "$BROKER" \
               --topic-list "$TOPIC" \
               --describe | grep '^{' \
               | jq '[ ..|.size? | numbers ] | add') \
               | tr -d '\n' 
    # Append the topic and its total size to the CSV file
    echo "$TOPIC,$SIZE" >>"$OUTPUT_FILE"
done
