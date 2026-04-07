#!/bin/bash
# Provide the PID of the Java app and the Envoy sidecar
JAVA_PID=$1
ENVOY_PID=$2

if [ -z "$JAVA_PID" ] || [ -z "$ENVOY_PID" ]; then
    echo "Usage: sudo ./deep_dive.sh [JAVA_PID] [ENVOY_PID]"
    exit 1
fi

echo -e "\n=========================================================================="
printf "%-15s %-25s %-25s %-10s\n" "NAMESPACE" "JAVA APP ($JAVA_PID)" "ENVOY ($ENVOY_PID)" "MATCH?"
echo "=========================================================================="

for ns in cgroup ipc mnt net pid user uts; do
    J_NS=$(readlink /proc/$JAVA_PID/ns/$ns)
    E_NS=$(readlink /proc/$ENVOY_PID/ns/$ns)
    
    if [ "$J_NS" == "$E_NS" ]; then
        MATCH="[ YES ]"
        COLOR="\e[1;32m"
    else
        MATCH="[ NO  ]"
        COLOR="\e[1;31m"
    fi
    
    printf "${COLOR}%-15s %-25s %-25s %-10s\e[0m\n" "$ns" "$J_NS" "$E_NS" "$MATCH"
done
echo "=========================================================================="
