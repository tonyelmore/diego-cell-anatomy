#!/bin/bash

if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as sudo."
  exit 1
fi

# 1. Identify the Root Namespace ID
ROOT_MNT_NS=$(readlink /proc/1/ns/net)

# Using an associative array to store ALL processes for a specific NS
declare -A ns_map
declare -A ns_is_app

echo "Performing Deep Scan of all process namespaces..."

# 2. Walk through every PID
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    [ ! -d "/proc/$pid" ] && continue
    
    # Get the Namespace ID
    mnt_ns=$(readlink /proc/$pid/ns/net 2>/dev/null)
    [ -z "$mnt_ns" ] && continue
    
    # Get the process name
    cmd=$(cat /proc/$pid/comm 2>/dev/null)
    [ -z "$cmd" ] && cmd="unknown"

    # Add this process to the namespace's bucket
    if [ -z "${ns_map[$mnt_ns]}" ]; then
        ns_map[$mnt_ns]="$cmd($pid)"
    else
        # Append to the list
        ns_map[$mnt_ns]="${ns_map[$mnt_ns]}, $cmd($pid)"
    fi

    # Mark if this namespace is a CF App
    if [[ "$cmd" == "garden-init" ]]; then
        ns_is_app[$mnt_ns]=true
    fi
done

# 3. Display the results
echo -e "\n===================================================================================================="
printf "%-25s %-70s\n" "NAMESPACE ID" "PROCESSES SHARING THIS SPACE"
echo "===================================================================================================="

# Sort by Namespace ID
for ns in $(printf "%s\n" "${!ns_map[@]}" | sort); do
    
    # Color Logic
    if [ "$ns" == "$ROOT_MNT_NS" ]; then
        COLOR="\e[1;32m" # GREEN: Root
    elif [ "${ns_is_app[$ns]}" = true ]; then
        COLOR="\e[1;36m" # CYAN: App Container
    else
        COLOR="\e[0m"    # DEFAULT: Everything else
    fi

    # Print the ID and the WRAPPED process list
    echo -ne "${COLOR}${ns}\e[0m  "
    
    # This 'fmt' command ensures the processes stay aligned under the "PROCESSES" column
    echo -e "${COLOR}${ns_map[$ns]}\e[0m" | fmt -w 80 | sed '2,$s/^/                           /'
    
    echo -e "----------------------------------------------------------------------------------------------------"
done
