# Tracing a Cloud Foundry App Through the Diego Cell

A runbook for following a running app from the CF CLI down to its container
processes, namespaces, and on-disk root filesystem on a Diego cell.

Everything below hangs off one **ID chain**. The same container gets named a few
different ways as you move down the stack, so it helps to fix the terms up front:

```
cf app name
   └─ App GUID ................... 4626fd81-…            (Cloud Controller's id for the app)
        └─ process_instance_id ... fe524340-…            (the containerd container id AND task id)
             ├─ ctr task ls → PID .. 794035              (the container's process id → nsenter, /proc/<PID>)
             │      └─ namespaces (mnt, net, pid, …)
             └─ grootfs image ..... images/<id>/         (the container's rootfs)
                    └─ base volume . volumes/<sha>/       (the STACK — cflinuxfs4 content + version)
```

> ### Terms
> - **`process_instance_id`** — a UUID (`fe524340-…`). This is the container's id
>   in containerd: both the **container id** and the **task id**, and also the
>   grootfs `images/` directory name. It shows up as the **TASK** in `ctr task ls`.
> - **process id (PID)** — the PID that `ctr task ls` returns for that task. This
>   is the container's process id; you use it for `nsenter` and `/proc/<pid>`.

All examples use the real values from a `spring-music` instance so the shapes
are concrete: app GUID `4626fd81-…`, handle `fe524340-e3bb-47ac-4d50-7f2b`,
cell `dec455db-7605-4899-a8d6-d938e60abfa7`.

---

## Step 1 — Get the App GUID

**Goal:** get Cloud Controller's id for the app, which Diego tags every LRP with.

```bash
cf app spring-music --guid
# 4626fd81-712d-457b-8593-42d6bfe37f65
```

**Why it matters:** this GUID is what you filter on to find the app's instances
in Diego — it appears as `app_id` in every actual-LRP's `metric_tags`.

---

## Step 2 — Locate the Instance: which cell, which process_instance_id

**Goal:** turn the app GUID into (a) the cell to SSH into and (b) the
process_instance_id to chase on that cell.

Run from **any** cell (cfdot queries the BBS, not the local cell):

```bash
cfdot actual-lrps | jq -r --arg app "4626fd81-712d-457b-8593-42d6bfe37f65" \
  'select(.metric_tags.app_id == $app) |
   "Diego Cell: diego_cell/\(.cell_id)\nProcess Id: \(.metric_tags.process_instance_id)"'
```

**What you'll see** (one block per instance):

```
Diego Cell: diego_cell/dec455db-7605-4899-a8d6-d938e60abfa7
Process Id: fe524340-e3bb-47ac-4d50-7f2b
```

**Why it matters:** the `Process Id` here is the `process_instance_id` — the
single UUID that identifies this container everywhere downstream. It *is* the
containerd container id and task id (you'll see it as the **TASK** in Step 4) and
the grootfs `images/` directory name (Step 7). You must SSH into the cell it
names; `/proc/<pid>/root` and `nsenter` only work against a container running on
the cell you're on.

> Multi-instance apps print several blocks. Add `.index` if you need to tell
> them apart, and add `and .cell_id == $cell` to the `select` if you only want
> instances on the cell you're already on.

---

## Step 3 — SSH to the Cell

**Goal:** get a root shell on the host that runs the container.

```bash
bosh -d cf-c8014792dcd40134a7b2 ssh diego_cell/dec455db-7605-4899-a8d6-d938e60abfa7
sudo -i
```

**Why it matters:** `cell_id` is also the BOSH instance id, so it drops straight
into `bosh ssh`. From the host you can read into any container's namespaces and
rootfs from the outside — no `cf ssh` required.

---

## Step 4 — Find the Container Task and its PID

**Goal:** resolve the `process_instance_id` to the container's PID.

```bash
cd /var/vcap/packages/containerd/bin
./ctr -a /var/vcap/sys/run/containerd/containerd.sock -n garden task ls
```

**What you'll see:** the `process_instance_id` from Step 2 appears as the
**TASK**, with its **PID** alongside:

```
TASK                                              PID       STATUS
fe524340-e3bb-47ac-4d50-7f2b                      794035    RUNNING
```

That PID is the container's **process id**. You can confirm what it is with:

```bash
ps -aef | grep <PID>
```

which shows it running as `garden-init` — the process that backs the container.

**Why it matters:** the `process_instance_id` you carried from Step 2 *is* the
containerd task id, so the match against the **TASK** column is exact, and this
PID is the one you feed to `nsenter` and `/proc/<pid>` in the following steps.

---

## Step 5 — Examine the Process Namespaces

**Goal:** see the isolation boundaries the container is built from.

```bash
ls -la /proc/<PID>/ns
```

**What you'll see:** links for `cgroup`, `ipc`, `mnt`, `net`, `pid`, `user`,
`uts`. Each is a separate axis of isolation:

| Namespace | Isolates |
|-----------|----------|
| `mnt`     | Filesystem view — the container's own root filesystem |
| `pid`     | Process tree — the container sees only its own processes |
| `net`     | Network stack — own IP, routes, interfaces |
| `ipc`     | System V IPC / POSIX message queues |
| `uts`     | Hostname / domain |
| `user`    | UID/GID mapping between container and host |
| `cgroup`  | The container's view of `/proc/self/cgroup` |

**Why it matters:** these are the primitives; the demos below make them
tangible.

---

## Step 6 — Prove the Isolation (net + pid + mnt)

**Goal:** show the container's view differs from the host's.

**Network** — host sees everything; container sees only `lo` + its veth:

```bash
ifconfig                              # host: physical + virtual interfaces
nsenter -t <PID> -n ifconfig          # container: lo and one veth, its own IP
```

**Processes** — host sees the whole cell; container sees only its own tree:

```bash
ps ax                                 # host: all cell + app + system processes
nsenter -t <PID> -p ps ax             # container: only this app's processes
```

**Mount** — host sees the whole cell; container sees only its own filesystem:

```bash
ls -al                                 # shows files from the host (diego_cell)
nsenter -t <PID> -m /bin/bash          # container: only this app's filesystem
ls -al                                 # shows files from the container, not the host
```

**Why it matters:** this is multi-tenancy in one screen — many apps on a shared
kernel, each with an isolated view, is exactly what these namespaces buy.

---

## Step 7 — The Container's Root Filesystem (grootfs)

**Goal:** find the on-disk rootfs for the container, and read the **stack**
(cflinuxfs4) content and version straight off disk.

```bash
ls -la /var/vcap/data/grootfs/store/unprivileged/images/ | grep <process_instance_id>
```

You'll see three directories — the container is user-namespaced, so it lives in
the `unprivileged/` store:

```
fe524340-e3bb-47ac-4d50-7f2b                      # the app container's rootfs
fe524340-e3bb-47ac-4d50-7f2b-envoy                # envoy sidecar's rootfs (leaner)
fe524340-e3bb-47ac-4d50-7f2b-liveness-healthcheck-0
```

**What an `images/<process_instance_id>/` directory actually is:** an **overlay mount** —
read-only base layer(s) (the **stack**: the cflinuxfs4 content, shared out of
`store/unprivileged/volumes/` and referenced via short `l/` symlinks) plus a
per-container writable upper/`diff` layer. Your **droplet** (the staged app) is
extracted *inside* this filesystem under `/home/vcap`; it is content within the
image, **not** the image itself and not a base layer.

**Resolve the image to its stack volume.** Find this container's overlay mount,
read its lower layer (the short `l/` symlink), then resolve that to the real
volume path:

```bash
mount | grep <process_instance_id> | grep lowerdir          # the overlay; lowerdir = l/xxx
readlink /var/vcap/data/grootfs/store/unprivileged/l/xxx    # -> volumes/<sha>
```

The bare `<process_instance_id>` line is the app container; the `-envoy` and
`-liveness-healthcheck-0` lines are its sidecars' own images.

**Read the stack off the volume.** The volume is the read-only base layer — the
**stack** itself — so you can read it directly, with no running container and no
`nsenter` (the same content you'd see from inside via `cf ssh`):

```bash
V=/var/vcap/data/grootfs/store/unprivileged/volumes/<sha>
grep VERSION $V/etc/os-release                                       # Ubuntu / OS release
cat $V/etc/stack-version                                             # the stack version
dpkg-query --admindir=$V/var/lib/dpkg -W -f='${Package} ${Version}\n' openssl libc6
```

**The application is not on the volume.** The volume carries only the stack, so
`ls $V/home/vcap/app` shows the stack's empty `/home/vcap`, not your droplet.
Your app lives in the container's writable upper layer; to see its files, enter
the container's mount namespace (Step 6), which presents the merged view — the
droplet layered over the stack:

```bash
nsenter -t <PID> -m /bin/bash
ls -al /home/vcap/app                  # the droplet, merged over the stack
```

**List the stack of every container on the cell** — one line per volume that
carries a stack version:

```bash
for V in /var/vcap/data/grootfs/store/unprivileged/volumes/*; do \
  [ -f "$V/etc/stack-version" ] && echo "$(basename "$V") $(cat "$V/etc/stack-version")"; \
done
```

---

## Appendix — Orphaned images

The `images/` directory will usually hold **more** entries than there are live
containers. A leaked image dir is the signature of an **ungraceful teardown**:
normally garden destroys a container and grootfs deletes its image dir, but on a
hard reboot / panic / power loss that destroy path never runs, so the dir is
stranded while its container is gone.

To separate live from orphaned:

```bash
cfdot actual-lrps | jq -r --arg c <cell_id> \
  'select(.cell_id==$c) | .metric_tags.process_instance_id' | sort > /tmp/live
ls /var/vcap/data/grootfs/store/unprivileged/images/ \
  | grep -vE 'envoy|healthcheck' | sort > /tmp/ondisk
comm -13 /tmp/live /tmp/ondisk        # on disk but not live = orphans
```

Orphan **mtimes** date the teardown event that leaked them, and their **shape**
dates the runtime: lone dirs (no `-envoy`/`-healthcheck` siblings) are
old-runtime containers; triples are new-runtime. `grootfs delete <handle>`
removes an orphan and reclaims its writable layer once you're sure it's dead.

---

## Quick reference

| Hop | Command | Yields |
|-----|---------|--------|
| app → GUID | `cf app <name> --guid` | App GUID |
| GUID → cell + id | `cfdot actual-lrps \| jq …` | `cell_id`, `process_instance_id` |
| → cell shell | `bosh ssh diego_cell/<cell_id>` | root on the host |
| id → PID | `ctr … -n garden task ls` | the container's PID |
| PID → namespaces | `ls -la /proc/<PID>/ns` | mnt/net/pid/… |
| isolation demo | `nsenter -t <PID> -m\|-n\|-p …` | container's view |
| id → rootfs | `images/<process_instance_id>/` | overlay: stack + writable layer |
| rootfs → volume | `mount \| grep …` → `readlink l/xxx` | `volumes/<sha>` (the stack) |
| read the stack | `cat $V/etc/stack-version` … | os-release, stack version, pkgs |

---

## Commands I ran in order
From laptop
```bash
  cf app <app_name> --guid 
```
  Capture the guid (app_guid)

From any diego_cell
```bash
  cfdot actual-lrps | jq -r --arg app "<app_guid>" 'select(.metric_tags.app_id == $app) | "Diego Cell: diego_cell/\(.cell_id)\nProcess Id: \(.metric_tags.process_instance_id)"'
```
  Capture the diego_cell (hosting_cell)
  Capture the process_instance_id (process_instance_id)

From the <hosting_cell>
```bash
  cd /var/vcap/packages/containerd/bin
  ./ctr -a /var/vcap/sys/run/containerd/containerd.sock -n garden task ls
```
  Capture the PID (pid) for the process_instance_id

Now that you have the PID, you have reference to the namespaces that are used for this container
```bash
  ls -al /proc/<pid>/ns
  nsenter -t <PID> -m /bin/bash
  ls -al
  cat /etc/stack-version
  exit
```

However, you can also access the data in the mount namespace by looking at the images and volumes
The image is the grootfs image for the container.  The application will be loaded onto this image
```bash
  ls -al /var/vcap/data/grootfs/store/unprivileged/images | grep <process_instance_id>
```

But, to get to the data, you use the "mount" command to find the overlay disk
```bash
  mount | grep <process_instance_id> | grep lowerdir
```
  Capture the lowerdir (lowerdir) - it will be in the format "l/xxx", capture all of that

Then you can find the actual volume based on the lowerdir
```bash
  readlink /var/vcap/data/grootfs/store/unprivileged/<lowerdir>
```
  Capture the volume (volume) - it will be something like "/var/vcap/data/grootfs/store/unprivileged/volumes/xxxx"

Now you can read data off the volume (the same as if you "cf ssh")
```bash
  V=/var/vcap/data/grootfs/store/unprivileged/volumes/f6aecab7978289e7403033758141d2ddfb12bf25c303a42856bf9914a10e368e
  grep VERSION $V/etc/os-release                                                        # To see the os-release version
  grep VERSION $V/etc/stack-version                                                     # To see the stack version
  cat $V/etc/stack-version                                                              # Also to see the stack version
  dpkg-query --admindir=$V/var/lib/dpkg -W -f='${Package} ${Version}\n' openssl libc6    # To see versions of openssl and libc6
  ls -al $V/home/vcap/app                                                               # To see the root directory of the application (this actually does not work, I have to nsenter to see the files)
```

To see the stack-version of all containers on this specific diego_cell
```bash
  for V in /var/vcap/data/grootfs/store/unprivileged/volumes/*; do [ -f "$V/etc/stack-version" ] && echo "$(basename "$V") $(cat "$V/etc/stack-version")"; done
```



