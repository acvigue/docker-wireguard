#!/bin/ash

set -e

# Check if the unmasked address file exists
if [ ! -f /tmp/unmasked_address ]; then
    echo "ERROR: /tmp/unmasked_address not found" >&2
    exit 1
fi

# Read the original IP
original_ip=$(cat /tmp/unmasked_address)

# Get the current public IP
current_ip=$(curl -s --max-time 5 ifconfig.me)

# Check if we got a response
if [ -z "$current_ip" ]; then
    echo "ERROR: Failed to get current public IP" >&2
    exit 1
fi

# Compare IPs - healthcheck succeeds if they are different
if [ "$current_ip" != "$original_ip" ]; then
    echo "OK: VPN is active (Original: $original_ip, Current: $current_ip)"
    exit 0
else
    echo "ERROR: VPN is NOT active (IP still: $current_ip)" >&2
    exit 1
fi
