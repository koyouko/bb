#!/bin/bash

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
               | jq '[ ..|.size? | numbers ] | add')
    # Append the topic and its total size to the CSV file
    echo "$TOPIC,$SIZE" >>"$OUTPUT_FILE"
done
#!/bin/bash

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
               | jq '[ ..|.size? | numbers ] | add')
    # Append the topic and its total size to the CSV file
    echo "$TOPIC,$SIZE" >>"$OUTPUT_FILE"
done
