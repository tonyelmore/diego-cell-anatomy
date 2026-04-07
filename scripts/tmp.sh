#!/bin/bash

if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as sudo."
  exit 1
fi

HOST_NET=$(readlink /proc/1/ns/net)
HOST_MNT=$(readlink /proc/1/ns/mnt)

echo -e "\n======================================================================================================================="
printf "%-15s %-18s %-18s %-18s %-30s\n" "PROFILE" "NETWORK NS" "MOUNT NS" "USER NS" "PROCESS"
echo "======================================================================================================================="

# We remove 'sort | uniq' so we see EVERYTHING
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ ! -d "/proc/$pid" ] && continue
    
    NET=$(readlink /proc/$pid/ns/net 2>/dev/null)
    MNT=$(readlink /proc/$pid/ns/mnt 2>/dev/null)
    USR=$(readlink /proc/$pid/ns/user 2>/dev/null)
    CGRP=$(readlink /proc/$pid/ns/cgroup 2>/dev/null)
    PID=$(readlink /proc/$pid/ns/pid 2>/dev/null)
    TIME=$(readlink /proc/$pid/ns/time 2>/dev/null)
    IPC=$(readlink /proc/$pid/ns/ipc 2>/dev/null)
    UTS=$(readlink /proc/$pid/ns/uts 2>/dev/null)
    CMD=$(cat /proc/$pid/comm 2>/dev/null)
    
    [ -z "$NET" ] || [ -z "$MNT" ] || [ -z "$USR" ] || [ -z "$CGRP" ] || [ -z "$PID" ] || [ -z "$TIME" ] || [ -z "$IPC" ] || [ -z "$UTS" ] && continue

    if [ "$NET" == "$HOST_NET" ] && [ "$MNT" == "$HOST_MNT" ]; then
        PROFILE="HOST_ROOT"
        COLOR="\e[1;32m" # Green
    elif [ "$NET" == "$HOST_NET" ] && [ "$MNT" != "$HOST_MNT" ]; then
        PROFILE="SYSTEM_JOB"
        COLOR="\e[0m"    # White (BPM)
    else
        PROFILE="APP_INSTANCE"
        COLOR="\e[1;36m" # Cyan (Garden)
    fi

    # Explicitly highlight gdn if we find it
    if [[ "$CMD" == "gdn" ]] || [[ "$CMD" == "garden" ]]; then
        printf "\e[1;33m%-15s %-18s %-18s %-18s %-18s %-18s %-18s %-18s %-30s (FOUND GARDEN!)\e[0m\n" "$PROFILE" "$NET" "$MNT" "$USR" "$CGRP" "$PID" "$TIME" "$IPC" "$UTS" "$CMD($pid)"
    else
        printf "${COLOR}%-15s %-18s %-18s %-18s %-18s %-18s %-18s %-18s %-30s\e[0m\n" "$PROFILE" "$NET" "$MNT" "$USR" "$CGRP" "$PID" "$TIME" "$IPC" "$UTS" "$CMD($pid)"
    fi
done | sort -k 2 # Sort by Network ID to group them
