#!/bin/bash

if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as sudo."
  exit 1
fi

# 1. Capture the Host "Source of Truth"
HOST_NET=$(readlink /proc/1/ns/net)
HOST_MNT=$(readlink /proc/1/ns/mnt)
HOST_USR=$(readlink /proc/1/ns/user)

echo -e "\n======================================================================================================================="
printf "%-15s %-18s %-18s %-18s %-30s\n" "PROFILE" "NETWORK NS" "MOUNT NS" "USER NS" "PROCESS"
echo "======================================================================================================================="

for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ ! -d "/proc/$pid" ] && continue
    
    NET=$(readlink /proc/$pid/ns/net 2>/dev/null)
    MNT=$(readlink /proc/$pid/ns/mnt 2>/dev/null)
    USR=$(readlink /proc/$pid/ns/user 2>/dev/null)
    CMD=$(cat /proc/$pid/comm 2>/dev/null)
    
    [ -z "$NET" ] || [ -z "$MNT" ] || [ -z "$USR" ] && continue

    # LOGIC ENGINE
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

    printf "${COLOR}%-15s %-18s %-18s %-18s %-30s\e[0m\n" "$PROFILE" "$NET" "$MNT" "$USR" "$CMD($pid)"
done | sort | uniq -w 70
