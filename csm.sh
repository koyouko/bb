#!/bin/bash
#
# generate-jaas.sh
# Generates or updates JAAS configuration files for Zookeeper and Kafka with
# SASL_MD5 authentication, using credentials fetched from CSM vault.
#
# Improvements over previous version:
#   * Retry with exponential backoff on the CSM vault fetch (transient
#     "system not responding" / fetch errors no longer kill the restart).
#   * JSON validation is part of the retry loop — a garbled response is
#     treated as a failed attempt and retried.
#   * Atomic file writes (temp file + mv) so a crash mid-write can never
#     leave a partial/empty JAAS file behind.
#   * Distinct, meaningful exit codes so the caller (systemd / restart
#     wrapper) can tell exactly what failed.
#   * Post-write verification that all three JAAS files exist and are
#     non-empty before exiting 0.
#
# Exit codes:
#   0  success (files created/updated or already current)
#   2  jq not installed
#   3  CSM vault fetch failed after all retries
#   4  fetched data is not valid JSON after all retries
#   5  could not extract username/password from JSON
#   6  failed to write one or more JAAS files
#   7  post-write verification failed (file missing or empty)


# ---------------------------------------------------------------------------
# Config (override via environment if needed)
# ---------------------------------------------------------------------------
MAX_RETRIES="${JAAS_FETCH_MAX_RETRIES:-5}"
RETRY_BASE_DELAY="${JAAS_FETCH_BASE_DELAY:-2}"    # seconds; doubles each attempt
RETRY_MAX_DELAY="${JAAS_FETCH_MAX_DELAY:-30}"     # cap on backoff

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [generate-jaas] $*" >&2
}

die() {
    local code=$1; shift
    log "FATAL: $* (exit $code)"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v jq &> /dev/null; then
    die 2 "jq is not installed. Please install jq and try again."
fi

# Declare all variables that define the active environment.
[[ -z "${BSP_BASE_DIR:-}" ]] && source "$(cd "$(dirname "$0")"/.. && pwd)/bin/env.sh"

# ---------------------------------------------------------------------------
# Fetch credentials from CSM vault with retry + backoff.
# A successful attempt requires BOTH: csm-kv.sh exits 0 AND output is valid,
# non-empty JSON. Anything else counts as a failed attempt and is retried.
# ---------------------------------------------------------------------------
fetch_credentials() {
    local attempt=1
    local delay="$RETRY_BASE_DELAY"
    local output err_output json rc
    local err_file
    err_file=$(mktemp)

    while (( attempt <= MAX_RETRIES )); do
        log "Fetching secret from CSM vault (attempt $attempt/$MAX_RETRIES)..."
        # stdout -> $output (the JSON payload), stderr -> $err_file (progress
        # messages like "Getting machine token for ..." and error details).
        output=$("$BSP_BIN_DIR/csm-kv.sh" "$BSP_ENV/zk_sasl_md5" 2>"$err_file")
        rc=$?
        err_output=$(cat "$err_file")

        # Defensive: if any informational lines ever leak onto stdout, keep
        # only the JSON portion (from the first line starting with '{').
        json=$(printf '%s\n' "$output" | sed -n '/^[[:space:]]*{/,$p')

        if (( rc == 0 )) && [[ -n "$json" ]] && echo "$json" | jq -e . &> /dev/null; then
            DATA="$json"
            log "Secret fetched and validated on attempt $attempt."
            rm -f "$err_file"
            return 0
        fi

        if (( rc != 0 )); then
            log "csm-kv.sh failed (rc=$rc): ${err_output:0:200}"
        else
            log "csm-kv.sh returned invalid or empty JSON on stdout: ${output:0:200}"
        fi

        if (( attempt < MAX_RETRIES )); then
            log "Retrying in ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))
            (( delay > RETRY_MAX_DELAY )) && delay="$RETRY_MAX_DELAY"
        fi
        (( attempt++ ))
    done

    rm -f "$err_file"

    # Distinguish the two failure modes for the exit code.
    if (( rc != 0 )); then
        die 3 "CSM vault fetch failed after $MAX_RETRIES attempts."
    else
        die 4 "CSM vault returned invalid JSON after $MAX_RETRIES attempts."
    fi
}

fetch_credentials

# ---------------------------------------------------------------------------
# Extract username and password
# ---------------------------------------------------------------------------
# Vault returns a single key/value pair: { "<username>": "<password>" }
USERNAME=$(echo "$DATA" | jq -r 'keys[0] // empty')
PASSWORD=$(echo "$DATA" | jq -r --arg u "$USERNAME" '.[$u] // empty')

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    die 5 "Could not extract username or password from the JSON data."
fi
log "Credentials extracted for user '$USERNAME'."

# ---------------------------------------------------------------------------
# Define JAAS file paths
# ---------------------------------------------------------------------------
ZOOKEEPER_JAAS_FILE="$BSP_BASE_DIR/etc/zookeeper-jaas.conf"
KAFKA_JAAS_FILE="$BSP_BASE_DIR/etc/kafka-jaas.conf"
KAFKA_JAAS_CLIENT_FILE="$BSP_BASE_DIR/etc/kafka-client-jaas.conf"

# ---------------------------------------------------------------------------
# Content to be written to the JAAS files
# ---------------------------------------------------------------------------
ZOOKEEPER_JAAS_CONTENT=$(cat <<EOF
Server {
    org.apache.zookeeper.server.auth.DigestLoginModule required
    user_$USERNAME="$PASSWORD";
};
EOF
)

KAFKA_JAAS_CONTENT=$(cat <<EOF
client.KafkaServer {
    org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;
};

secure.KafkaServer {
    org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;
};

temp.KafkaServer {
    org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;
};

KafkaClient {
    org.apache.zookeeper.server.auth.DigestLoginModule required
    username="$USERNAME"
    password="$PASSWORD";
};

Client {
    org.apache.zookeeper.server.auth.DigestLoginModule required
    username="$USERNAME"
    password="$PASSWORD";
};
EOF
)

KAFKA_JAAS_CLIENT_CONTENT=$(cat <<EOF
KafkaClient {
    org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;
};

Client {
    org.apache.zookeeper.server.auth.DigestLoginModule required
    username="$USERNAME"
    password="$PASSWORD";
};
EOF
)

# ---------------------------------------------------------------------------
# Atomic compare-and-write.
# Writes to a temp file in the same directory, then mv (atomic on the same
# filesystem). A crash or restart mid-write can never leave a truncated or
# empty JAAS file — the old file stays intact until the mv completes.
# ---------------------------------------------------------------------------
compare_and_write_file() {
    local file_path=$1
    local new_content=$2
    local dir tmp

    # Refuse to write empty content — better to fail loudly than to blank
    # out a working JAAS file.
    if [[ -z "$new_content" ]]; then
        log "Refusing to write empty content to $file_path"
        return 1
    fi

    dir=$(dirname "$file_path")
    if ! mkdir -p "$dir"; then
        log "Failed to create directory $dir"
        return 1
    fi

    # No-op if content is already identical (printf keeps trailing-newline
    # handling consistent with what we write below).
    if [[ -f "$file_path" ]] && [[ "$(cat "$file_path")" == "$new_content" ]]; then
        log "$file_path already exists with the same content. No changes made."
        return 0
    fi

    tmp=$(mktemp "$dir/.$(basename "$file_path").XXXXXX") || {
        log "Failed to create temp file in $dir"
        return 1
    }

    if ! printf '%s\n' "$new_content" > "$tmp"; then
        log "Failed to write temp file for $file_path"
        rm -f "$tmp"
        return 1
    fi

    # Credentials inside: readable by owner+group only, no execute bit.
    chmod 640 "$tmp"

    if ! mv -f "$tmp" "$file_path"; then
        log "Failed to move temp file into place for $file_path"
        rm -f "$tmp"
        return 1
    fi

    log "$file_path has been created/updated."
    return 0
}

# ---------------------------------------------------------------------------
# Generate/Update JAAS files — attempt all three, then fail once if any
# failed (so one bad file doesn't hide the status of the others).
# ---------------------------------------------------------------------------
write_failures=0
compare_and_write_file "$ZOOKEEPER_JAAS_FILE"     "$ZOOKEEPER_JAAS_CONTENT"     || (( write_failures++ ))
compare_and_write_file "$KAFKA_JAAS_FILE"         "$KAFKA_JAAS_CONTENT"         || (( write_failures++ ))
compare_and_write_file "$KAFKA_JAAS_CLIENT_FILE"  "$KAFKA_JAAS_CLIENT_CONTENT"  || (( write_failures++ ))

if (( write_failures > 0 )); then
    die 6 "$write_failures JAAS file(s) failed to write."
fi

# ---------------------------------------------------------------------------
# Post-write verification — the whole point of this script is that these
# three files exist and are non-empty after a restart. Prove it before
# exiting 0.
# ---------------------------------------------------------------------------
for f in "$ZOOKEEPER_JAAS_FILE" "$KAFKA_JAAS_FILE" "$KAFKA_JAAS_CLIENT_FILE"; do
    if [[ ! -s "$f" ]]; then
        die 7 "Verification failed: $f is missing or empty."
    fi
done

log "All JAAS files verified present and non-empty. Done."
exit 0
