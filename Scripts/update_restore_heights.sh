#!/bin/bash

# Fetches block height checkpoints for Monero and Zano and updates:
#   Sources/MoneroKit/RestoreHeight.swift
#   Sources/ZanoKit/RestoreHeight.swift
#
# Reads the last existing entry from each Swift file and only fetches
# months that are missing, then appends them.
#
# Usage: ./update_restore_heights.sh
#
# Override daemon URLs via env vars:
#   MONERO_DAEMON=http://... ZANO_DAEMON=http://... ./update_restore_heights.sh
#
# Requires: curl, jq, python3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MONERO_DAEMON="${MONERO_DAEMON:-http://node.sethforprivacy.com:18089}"
ZANO_DAEMON="${ZANO_DAEMON:-http://37.27.100.59:10500}"

# ── Dependency check ─────────────────────────────────────────────────────────

for dep in curl jq python3; do
    if ! command -v $dep &> /dev/null; then
        echo "Error: $dep is required but not installed."
        [ "$dep" = "jq" ] && echo "  Install with: brew install jq"
        exit 1
    fi
done

# ── RPC helpers ──────────────────────────────────────────────────────────────

get_block_timestamp() {
    local rpc=$1 height=$2 method=$3
    curl -s -X POST "$rpc" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$method\",\"params\":{\"height\":$height}}" \
        | jq -r '.result.block_header.timestamp'
}

get_current_height() {
    local rpc=$1 method=$2
    curl -s -X POST "$rpc" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$method\",\"params\":{}}" \
        | jq -r '.result.count'
}

find_height_for_timestamp() {
    local rpc=$1 target_ts=$2 low=$3 high=$4 method=$5
    while [ $low -lt $high ]; do
        local mid=$(( (low + high) / 2 ))
        local mid_ts
        mid_ts=$(get_block_timestamp "$rpc" $mid "$method")
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

# ── Read last checkpoint from Swift file ─────────────────────────────────────
# Prints "YYYY-MM-DD HEIGHT" or exits non-zero if nothing found.

read_last_checkpoint() {
    local swift_file=$1
    python3 - "$swift_file" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

m = re.search(r'private static let blockHeights: \[String: Int64\] = \[(.*?)\n    \]', content, re.DOTALL)
if not m:
    sys.exit(1)

entries = re.findall(r'"(\d{4}-\d{2}-\d{2})": ([\d_]+)', m.group(1))
if not entries:
    sys.exit(1)

last_date, last_height = sorted(entries)[-1]
print(f"{last_date} {last_height.replace('_', '')}")
PYEOF
}

# ── Checkpoint fetcher ───────────────────────────────────────────────────────
# Fetches only months after start_year/start_month.
# Prints new Swift dictionary entries to stdout; progress goes to stderr.

fetch_checkpoints() {
    local chain=$1 daemon_url=$2 start_year=$3 start_month=$4 prev_height=$5
    local rpc="${daemon_url}/json_rpc"
    local block_time method_height method_header

    case "$chain" in
        monero)
            block_time=120
            method_height="get_block_count"
            method_header="get_block_header_by_height"
            ;;
        zano)
            block_time=60
            method_height="getblockcount"
            method_header="getblockheaderbyheight"
            ;;
    esac

    local blocks_per_month=$(( 30 * 24 * 3600 / block_time ))

    local current_height
    current_height=$(get_current_height "$rpc" "$method_height")
    if [ -z "$current_height" ] || [ "$current_height" = "null" ]; then
        echo "  Error: could not fetch current height from $daemon_url" >&2
        return 1
    fi
    echo "  Current height : $current_height" >&2
    echo "" >&2

    local year=$start_year month=$start_month
    local current_year current_month
    current_year=$(date "+%Y")
    current_month=$(date "+%m" | sed 's/^0//')

    while true; do
        local month_str date_str target_ts
        month_str=$(printf "%02d" $month)
        date_str="$year-$month_str-01"

        if [[ "$OSTYPE" == "darwin"* ]]; then
            target_ts=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$date_str 00:00:00" "+%s" 2>/dev/null)
        else
            target_ts=$(TZ=UTC date -d "$date_str 00:00:00" "+%s" 2>/dev/null)
        fi

        [ -z "$target_ts" ] && { echo "Error parsing $date_str" >&2; break; }

        printf "  %-12s " "$date_str" >&2

        local estimate=$(( prev_height + blocks_per_month ))
        local low=$prev_height
        local high=$(( estimate + 100000 ))
        [ $high -gt $current_height ] && high=$current_height

        local height
        height=$(find_height_for_timestamp "$rpc" $target_ts $low $high "$method_header")

        if [ -z "$height" ]; then
            echo "ERROR" >&2
            month=$((month + 1))
            [ $month -gt 12 ] && { month=1; year=$((year + 1)); }
            continue
        fi

        echo "$height" >&2
        local height_fmt
        height_fmt=$(printf "%'d" $height | tr ',' '_')
        printf '        "%s": %s,\n' "$date_str" "$height_fmt"

        prev_height=$height
        month=$((month + 1))
        [ $month -gt 12 ] && { month=1; year=$((year + 1)); }
        [ $year -gt $current_year ] && break
        [ $year -eq $current_year ] && [ $month -gt $current_month ] && break
    done
}

# ── Swift file updater ───────────────────────────────────────────────────────
# Appends new entries before the closing ] of blockHeights.

append_swift_file() {
    local swift_file=$1 entries_file=$2
    python3 - "$swift_file" "$entries_file" <<'PYEOF'
import sys, re

swift_file   = sys.argv[1]
entries_file = sys.argv[2]

with open(entries_file) as f:
    entries = f.read().rstrip('\n')

with open(swift_file) as f:
    content = f.read()

# Insert new entries before the closing ] of the blockHeights dictionary
pattern = r'(private static let blockHeights: \[String: Int64\] = \[.*?)(\n    \])'
replacement = r'\g<1>' + '\n' + entries + r'\g<2>'
new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

if new_content == content:
    print(f'  Warning: blockHeights pattern not found in {swift_file}')
    sys.exit(1)

with open(swift_file, 'w') as f:
    f.write(new_content)
PYEOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

FAILED=0
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

for chain in monero zano; do
    case "$chain" in
        monero) daemon="$MONERO_DAEMON"; swift_file="$PROJECT_ROOT/Sources/MoneroKit/RestoreHeight.swift" ;;
        zano)   daemon="$ZANO_DAEMON";   swift_file="$PROJECT_ROOT/Sources/ZanoKit/RestoreHeight.swift"   ;;
    esac

    echo "━━━ $chain (${daemon}) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Read the last existing checkpoint to determine where to start
    last_checkpoint=$(read_last_checkpoint "$swift_file")
    if [ -z "$last_checkpoint" ]; then
        echo "  Error: could not read last checkpoint from $swift_file"
        FAILED=1
        continue
    fi

    last_date=$(echo "$last_checkpoint" | cut -d' ' -f1)
    last_height=$(echo "$last_checkpoint" | cut -d' ' -f2)
    echo "  Last checkpoint: $last_date (height $last_height)"

    # Advance one month past the last known entry
    last_year=$(echo "$last_date" | cut -d'-' -f1)
    last_month=$(echo "$last_date" | cut -d'-' -f2 | sed 's/^0//')
    start_month=$((last_month + 1))
    start_year=$last_year
    [ $start_month -gt 12 ] && { start_month=1; start_year=$((start_year + 1)); }

    current_year=$(date "+%Y")
    current_month=$(date "+%m" | sed 's/^0//')

    # Nothing to do if already up to date
    if [ $start_year -gt $current_year ] || \
       { [ $start_year -eq $current_year ] && [ $start_month -gt $current_month ]; }; then
        echo "  Already up to date."
        echo ""
        continue
    fi

    echo "  Fetching from $(printf "%04d-%02d" $start_year $start_month) onwards..."

    fetch_checkpoints "$chain" "$daemon" $start_year $start_month $last_height > "$TMPFILE"
    if [ $? -ne 0 ] || [ ! -s "$TMPFILE" ]; then
        echo "  Error: failed to fetch $chain checkpoints"
        FAILED=1
        continue
    fi

    append_swift_file "$swift_file" "$TMPFILE"
    if [ $? -eq 0 ]; then
        echo "  Updated: $swift_file"
    else
        FAILED=1
    fi
    echo ""
done

[ $FAILED -ne 0 ] && exit 1
echo "Done."
