#!/bin/bash

if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as sudo."
  exit 1
fi

ROOT_NET_NS=$(readlink /proc/1/ns/net)
ROOT_MNT_NS=$(readlink /proc/1/ns/mnt)
ROOT_USER_NS=$(readlink /proc/1/ns/user)

echo -e "\n======================================================================================================================="
printf "%-18s %-18s %-18s %-40s\n" "NETWORK NS" "MOUNT NS" "USER NS" "PROCESSES"
echo "======================================================================================================================="

# Collect process data
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ ! -d "/proc/$pid" ] && continue
    
    net_ns=$(readlink /proc/$pid/ns/net 2>/dev/null)
    mnt_ns=$(readlink /proc/$pid/ns/mnt 2>/dev/null)
    usr_ns=$(readlink /proc/$pid/ns/user 2>/dev/null)
    cmd=$(cat /proc/$pid/comm 2>/dev/null)
    
    [ -z "$net_ns" ] || [ -z "$mnt_ns" ] || [ -z "$usr_ns" ] && continue

    # Color Logic
    if [ "$net_ns" == "$ROOT_NET_NS" ]; then
        COLOR="\e[1;32m" # GREEN: Host Network (System)
    else
        COLOR="\e[1;36m" # CYAN: Container Network (App)
    fi

    # Print the row
    printf "${COLOR}%-18s %-18s %-18s %-40s\e[0m\n" "$net_ns" "$mnt_ns" "$usr_ns" "$cmd($pid)"
done | sort | uniq -w 56 # Collapses identical triplets to show unique container types
