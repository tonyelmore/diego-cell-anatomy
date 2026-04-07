#!/bin/bash

# Check for root privileges to read /proc namespace links
if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as sudo."
  exit 1
fi

# 1. Identify the Root Mount Namespace ID
ROOT_MNT_NS=$(readlink /proc/1/ns/mnt)

# Arrays to store our findings
declare -A ns_processes
declare -A ns_type

echo "Checking all Tanzu-related processes on the Diego Cell..."

# 2. Iterate through all processes from /var/vcap (the BOSH path)
# This captures Garden, Rep, and all BPM-isolated jobs.
for pid in $(pgrep -f "/var/vcap/"); do
    [ ! -d "/proc/$pid" ] && continue
    
    # Get the Namespace ID for this process
    mnt_ns=$(readlink /proc/$pid/ns/mnt 2>/dev/null)
    [ -z "$mnt_ns" ] && continue
    
    # Get the process name
    cmd=$(cat /proc/$pid/comm)

    # Group processes by Namespace ID
    if [ -z "${ns_processes[$mnt_ns]}" ]; then
        ns_processes[$mnt_ns]="$cmd($pid)"
    else
        ns_processes[$mnt_ns]="${ns_processes[$mnt_ns]}, $cmd($pid)"
    fi

    # Determine if this Namespace ID is the Root or a Container
    if [ "$mnt_ns" == "$ROOT_MNT_NS" ]; then
        ns_type[$mnt_ns]="ROOT (Host)"
    else
        ns_type[$mnt_ns]="CONTAINER (BPM/Garden)"
    fi
done

# 3. Print the Consolidated Report
echo -e "\nDetailed Namespace Cross-Reference"
echo "----------------------------------------------------------------------------------------------------"
printf "%-25s %-20s %-50s\n" "NAMESPACE ID" "LOCATION" "PROCESSES IN NAMESPACE"
echo "----------------------------------------------------------------------------------------------------"

for ns in "${!ns_processes[@]}"; do
    # Highlight the ROOT namespace in Green (it should contain 'gdn')
    if [ "${ns_type[$ns]}" == "ROOT (Host)" ]; then
        COLOR="\e[32m"
    else
        COLOR="\e[0m" # Default for containers
    fi

    printf "${COLOR}%-25s %-20s %-50s\e[0m\n" "$ns" "${ns_type[$ns]}" "${ns_processes[$ns]}"
done

echo "----------------------------------------------------------------------------------------------------"
echo "Note: If 'gdn' is in the ROOT namespace, your Diego Cell is architecturally sound."
