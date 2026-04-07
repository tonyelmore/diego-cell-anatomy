#!/bin/bash

if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as sudo."
  exit 1
fi

# 1. Identify the Root Namespace ID
ROOT_MNT_NS=$(readlink /proc/1/ns/mnt)

declare -A ns_processes
declare -A ns_is_app

echo "Analyzing all namespaces (3-Color Tier)..."

# 2. Map every process to its namespace
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ ! -d "/proc/$pid" ] && continue
    
    mnt_ns=$(readlink /proc/$pid/ns/mnt 2>/dev/null)
    [ -z "$mnt_ns" ] && continue
    
    # Get the command name
    cmd=$(cat /proc/$pid/comm 2>/dev/null)
    [ -z "$cmd" ] && cmd="unknown"

    # Group by Namespace ID
    if [ -z "${ns_processes[$mnt_ns]}" ]; then
        ns_processes[$mnt_ns]="$cmd($pid)"
    else
        # Append unique command names and PIDs
        ns_processes[$mnt_ns]="${ns_processes[$mnt_ns]}, $cmd($pid)"
    fi

    # Check specifically for Application marker
    if [[ "$cmd" == "garden-init" ]]; then
        ns_is_app[$mnt_ns]=true
    fi
done

# 3. Print Header
echo -e "\n===================================================================================================="
printf "%-25s %-70s\n" "NAMESPACE ID" "PROCESSES"
echo "===================================================================================================="

# 4. Sort and Display
for ns in $(printf "%s\n" "${!ns_processes[@]}" | sort); do
    
    # Color Logic
    if [ "$ns" == "$ROOT_MNT_NS" ]; then
        COLOR="\e[1;32m" # GREEN: Root
    elif [ "${ns_is_app[$ns]}" = true ]; then
        COLOR="\e[1;36m" # CYAN: App Container
    else
        COLOR="\e[0m"    # DEFAULT: Any other container (BPM, Sidecars, etc)
    fi

    # Output formatting: ID on left, wrapped processes on right
    echo -ne "${COLOR}${ns}\e[0m  "
    echo -e "${COLOR}${ns_processes[$ns]}\e[0m" | fmt -w 80 | sed '2,$s/^/                           /'
    
    echo -e "----------------------------------------------------------------------------------------------------"
done
