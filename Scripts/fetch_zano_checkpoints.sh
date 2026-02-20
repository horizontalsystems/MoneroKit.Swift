#!/bin/bash

# Fetch Zano blockchain checkpoints for RestoreHeight.swift
# Usage: ./fetch_zano_checkpoints.sh [daemon_url]
# Example: ./fetch_zano_checkpoints.sh http://37.27.100.59:10500
#
# Requires: curl, jq

DAEMON_URL="${1:-http://37.27.100.59:10500}"
RPC_ENDPOINT="${DAEMON_URL}/json_rpc"

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed."
    echo "Install with: brew install jq"
    exit 1
fi

echo "Using daemon: $DAEMON_URL"
echo ""

# Function to get block header by height
get_block_timestamp() {
    local height=$1
    curl -s -X POST "$RPC_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"getblockheaderbyheight\",\"params\":{\"height\":$height}}" \
        | jq -r '.result.block_header.timestamp'
}

# Function to get current blockchain height
get_current_height() {
    curl -s -X POST "$RPC_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":"0","method":"getblockcount","params":{}}' \
        | jq -r '.result.count'
}

# Binary search to find block height for a given timestamp
find_height_for_timestamp() {
    local target_ts=$1
    local low=$2
    local high=$3

    while [ $low -lt $high ]; do
        local mid=$(( (low + high) / 2 ))
        local mid_ts=$(get_block_timestamp $mid)

        if [ -z "$mid_ts" ] || [ "$mid_ts" = "null" ]; then
            echo "Error fetching block $mid" >&2
            return 1
        fi

        if [ "$mid_ts" -lt "$target_ts" ]; then
            low=$((mid + 1))
        else
            high=$mid
        fi
    done

    echo $low
}

# Get current height
echo "Fetching current blockchain height..."
CURRENT_HEIGHT=$(get_current_height)
if [ -z "$CURRENT_HEIGHT" ] || [ "$CURRENT_HEIGHT" = "null" ]; then
    echo "Error: Could not fetch current height"
    exit 1
fi
echo "Current height: $CURRENT_HEIGHT"
echo ""

# Get block 1 timestamp (block 0 has timestamp 0)
echo "Fetching block 1 timestamp..."
BLOCK1_TS=$(get_block_timestamp 1)
BLOCK1_DATE=$(date -r $BLOCK1_TS "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "@$BLOCK1_TS" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
echo "Block 1 timestamp: $BLOCK1_TS ($BLOCK1_DATE)"
echo ""

# Generate list of first-of-month dates from May 2019 to now
echo "Fetching block heights for each month..."
echo "This may take several minutes due to binary search..."
echo ""

# Output file
OUTPUT=""

# Start from May 2019 (Zano genesis month)
YEAR=2019
MONTH=5

# Get current year and month
CURRENT_YEAR=$(date "+%Y")
CURRENT_MONTH=$(date "+%m" | sed 's/^0//')

# Track previous height for estimation
PREV_HEIGHT=0

OUTPUT+="// Generated on $(date '+%Y-%m-%d') from $DAEMON_URL\n"
OUTPUT+="// Block 1 timestamp: $BLOCK1_TS ($BLOCK1_DATE)\n"
OUTPUT+="private static let blockHeights: [String: Int64] = [\n"

while true; do
    # Format month with leading zero
    MONTH_STR=$(printf "%02d" $MONTH)
    DATE_STR="$YEAR-$MONTH_STR-01"

    # Convert date to Unix timestamp (UTC midnight)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        TARGET_TS=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$DATE_STR 00:00:00" "+%s" 2>/dev/null)
    else
        TARGET_TS=$(TZ=UTC date -d "$DATE_STR 00:00:00" "+%s" 2>/dev/null)
    fi

    if [ -z "$TARGET_TS" ]; then
        echo "Error parsing date $DATE_STR" >&2
        break
    fi

    echo -n "  $DATE_STR: "

    # For genesis month (before block 1), height is 0
    if [ "$TARGET_TS" -lt "$BLOCK1_TS" ]; then
        HEIGHT=0
        echo "0 (before genesis)"
        OUTPUT+="    \"$DATE_STR\": 0,        // Before genesis\n"
    else
        # Estimate starting point for binary search
        # Use ~1440 blocks per day (1 block per minute)
        if [ $PREV_HEIGHT -eq 0 ]; then
            # First search after genesis - estimate based on days since block 1
            DAYS_SINCE=$(( (TARGET_TS - BLOCK1_TS) / 86400 ))
            ESTIMATE=$((DAYS_SINCE * 1440))
        else
            # Estimate based on ~30 days * 1440 blocks
            ESTIMATE=$((PREV_HEIGHT + 43200))
        fi

        # Set search bounds
        LOW=$PREV_HEIGHT
        HIGH=$((ESTIMATE + 100000))
        if [ $HIGH -gt $CURRENT_HEIGHT ]; then
            HIGH=$CURRENT_HEIGHT
        fi

        # Binary search for the height
        HEIGHT=$(find_height_for_timestamp $TARGET_TS $LOW $HIGH)

        if [ -z "$HEIGHT" ]; then
            echo "ERROR"
            OUTPUT+="    // Error fetching height for $DATE_STR\n"
            MONTH=$((MONTH + 1))
            if [ $MONTH -gt 12 ]; then
                MONTH=1
                YEAR=$((YEAR + 1))
            fi
            continue
        fi

        # Verify the height
        ACTUAL_TS=$(get_block_timestamp $HEIGHT)

        echo "$HEIGHT (block timestamp: $ACTUAL_TS)"

        # Format with underscores for readability
        HEIGHT_FORMATTED=$(printf "%'d" $HEIGHT | tr ',' '_')

        OUTPUT+="    \"$DATE_STR\": $HEIGHT_FORMATTED,\n"
    fi

    PREV_HEIGHT=$HEIGHT

    # Move to next month
    MONTH=$((MONTH + 1))
    if [ $MONTH -gt 12 ]; then
        MONTH=1
        YEAR=$((YEAR + 1))
    fi

    # Stop if we've gone past current month
    if [ $YEAR -gt $CURRENT_YEAR ]; then
        break
    fi
    if [ $YEAR -eq $CURRENT_YEAR ] && [ $MONTH -gt $CURRENT_MONTH ]; then
        break
    fi
done

OUTPUT+="]"

echo ""
echo "========================================="
echo "SWIFT CODE OUTPUT:"
echo "========================================="
echo ""
echo -e "$OUTPUT"
