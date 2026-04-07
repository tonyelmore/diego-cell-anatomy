# Get the Root Namespace ID
ROOT_MNT=$(readlink /proc/1/ns/mnt)

# Find the Garden server process and get its Namespace ID
GARDEN_PID=$(pgrep -f "garden" | head -n 1)
GARDEN_MNT=$(readlink /proc/$GARDEN_PID/ns/mnt)

echo "Root MNT NS:   $ROOT_MNT"
echo "Garden MNT NS: $GARDEN_MNT"

if [ "$ROOT_MNT" == "$GARDEN_MNT" ]; then
    echo "SUCCESS: Garden is running in the ROOT namespace."
else
    echo "FAILED: Garden is isolated."
fi
