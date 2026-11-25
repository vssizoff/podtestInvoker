#!/usr/bin/env bash
set -euo pipefail
check=$1
shift
# Two simultaneous owners per round. Keep the total finite on shared hosts.
for ((round=1; round<=8; round++)); do
    bash "$check" "$@"
done
printf '%s\n' '8 recovery rounds completed: 16 processes, 48 owned resources'
