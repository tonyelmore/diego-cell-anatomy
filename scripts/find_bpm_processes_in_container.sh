#!/bin/bash

# Ensure we are root to read /proc namespace links
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root (sudo)."
  exit 1
fi

# 1. Identify the 'Root' Namespace ID from PID 1 (systemd/init)
ROOT_MNT_NS=$(readlink /proc/1/ns/mnt)

echo "Auditing Tanzu Processes (Diego Cell)"
echo "Root Namespace ID: $ROOT_MNT_NS"
echo "------------------------------------------------------------------------------------------------"
printf "%-8s %-15s %-20s %-25s\n" "PID" "STATUS" "NAMESPACE ID" "COMPONENT/COMMAND"
echo "------------------------------------------------------------------------------------------------"

# 2. Find all processes running from /var/vcap (the BOSH directory)
# This includes Garden, Rep, Silk, and all BPM-wrapped jobs.
pgrep -f "/var/vcap/" | while read -r pid; do
    # Skip if process vanished
    [ ! -d "/proc/$pid" ] && continue

    # Get the namespace of the process
    PROC_MNT_NS=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)
    [ -z "$PROC_MNT_NS" ] && continue

    # Get the command name (short version)
    CMD=$(cat "/proc/$pid/comm")
    
    # Check if it's the root namespace or an isolated one
    if [ "$PROC_MNT_NS" == "$ROOT_MNT_NS" ]; then
        STATUS="ROOT"
        # Color coding: Green for Root
        COLOR="\e[32m"
    else
        STATUS="CONTAINER"
        # Color coding: Yellow for Isolated/BPM
        COLOR="\e[33m"
    fi

    # Print the result
    printf "${COLOR}%-8s %-15s %-20s %-25s\e[0m\n" "$pid" "$STATUS" "$PROC_MNT_NS" "$CMD"
done
