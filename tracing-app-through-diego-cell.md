# Tracing a Cloud Foundry App Through the Diego Cell

A runbook for following a running app from the CF CLI down to its container
processes, namespaces, and on-disk root filesystem on a Diego cell.

Everything below hangs off one **ID chain**. Almost all the confusion in this
process comes from three different things being loosely called "the process
id," so the chain names each hop explicitly:

```
cf app name
   └─ App GUID ................... 4626fd81-…            (Cloud Controller's id for the app)
        └─ process_instance_id ... fe524340-…            (the container HANDLE; a UUID, NOT a PID)
             ├─ containerd task ... PID of garden-init   (the container's PID 1 — a real host PID)
             │      └─ app PID .... PID of your process  (a child of garden-init)
             │           └─ namespaces (mnt, net, pid, …)
             └─ grootfs image ..... images/<handle>/     (the container's rootfs)
                    └─ base volume . volumes/<sha>/       (the STACK — cflinuxfs4 content + version)
```

> ### The three things called "process id"
> - **`process_instance_id`** — a UUID (`fe524340-…`). The container **handle**.
>   Doubles as the containerd container/task id **and** the grootfs `images/`
>   directory name. It is *not* a Linux PID.
> - **containerd task PID** — a real host PID. This is **garden-init**, the
>   container's PID 1 — *not* your application.
> - **app PID** — your actual application process, a descendant of garden-init.
>
> Steps 1→4→5 are just "resolve UUID → task PID → app PID."

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

## Step 2 — Locate the Instance: which cell, which handle

**Goal:** turn the app GUID into (a) the cell to SSH into and (b) the container
handle to chase on that cell.

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

**Why it matters:** the `Process Id` here is the **handle** — the single UUID
that identifies this container everywhere downstream (containerd, grootfs,
garden depot). You must SSH into the cell it names; `/proc/<pid>/root` and
`nsenter` only work against a container running on the cell you're on.

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

## Step 4 — Find the Container Task and its PID (garden-init)

**Goal:** resolve the handle to the container's PID 1.

```bash
cd /var/vcap/packages/containerd/bin
./ctr -a /var/vcap/sys/run/containerd/containerd.sock -n garden container ls
./ctr -a /var/vcap/sys/run/containerd/containerd.sock -n garden task ls
```

**What you'll see:** the `container ls` output lists **three** containers per app
instance — the app plus its sidecars, each a real container:

```
CONTAINER                                        IMAGE   RUNTIME
fe524340-e3bb-47ac-4d50-7f2b                     -       io.containerd.runc.v2
fe524340-e3bb-47ac-4d50-7f2b-envoy               -       io.containerd.runc.v2
fe524340-e3bb-47ac-4d50-7f2b-liveness-healthcheck-0   -  io.containerd.runc.v2
```

`task ls` gives each a **PID**. The PID for the bare `<handle>` task is
**garden-init**, the container's PID 1.

**Why it matters:** the handle you carried from Step 2 *is* the containerd id, so
the match is exact. The sidecars (envoy proxy, liveness/readiness healthcheck)
run as **separate containers that share the app's network namespace** — which is
why they show up here and get their own rootfs (Step 8). Note this is the
newer-runtime shape; older containers ran these as in-container processes with no
separate container or image.

> The task PID is **garden-init, not your app.** Do not stop here.

---

## Step 5 — Find the Application PID

**Goal:** walk from garden-init down to the actual app process.

```bash
pstree -p <garden-init-pid>            # see the whole tree under the container init
ps --ppid <garden-init-pid> -f         # direct children (your start command)
```

**Why it matters:** garden-init execs your droplet's start command as a child, so
your app (and anything it forks) hangs beneath the task PID. This app PID is the
one you point `nsenter` and `/proc/<pid>/` at in the next steps.

---

## Step 6 — Examine the Process Namespaces

**Goal:** see the isolation boundaries the container is built from.

```bash
ls -la /proc/<app-pid>/ns
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

**Why it matters:** these are the primitives; the two demos below make them
tangible.

---

## Step 7 — Prove the Isolation (net + pid)

**Goal:** show the container's view differs from the host's.

**Network** — host sees everything; container sees only `lo` + its veth:

```bash
ifconfig                              # host: physical + virtual interfaces
nsenter -t <app-pid> -n ifconfig      # container: lo and one veth, its own IP
```

**Processes** — host sees the whole cell; container sees only its own tree:

```bash
ps ax                                 # host: all cell + app + system processes
nsenter -t <app-pid> -p ps ax         # container: only this app's processes
```

**Mount** — host sees the whole cell; container sees only its own filesystem:

```bash
ls al                                 # host: all cell + app + system processes
nsenter -t <app-pid> -m /bin/bash     # container: only this app's filesystem
```

**Why it matters:** this is multi-tenancy in one screen — many apps on a shared
kernel, each with an isolated view, is exactly what these namespaces buy.

---

## Step 8 — The Container's Root Filesystem (grootfs)

**Goal:** find the on-disk rootfs for the container, and read the **stack**
(cflinuxfs4) content and version straight off disk.

```bash
ls -la /var/vcap/data/grootfs/store/unprivileged/images/ | grep <handle>
```

You'll see three directories — the container is user-namespaced, so it lives in
the `unprivileged/` store:

```
fe524340-e3bb-47ac-4d50-7f2b                      # the app container's rootfs
fe524340-e3bb-47ac-4d50-7f2b-envoy                # envoy sidecar's rootfs (leaner)
fe524340-e3bb-47ac-4d50-7f2b-liveness-healthcheck-0
```

**What an `images/<handle>/` directory actually is:** an **overlay mount** —
read-only base layer(s) (the **stack**: the cflinuxfs4 content, shared out of
`store/unprivileged/volumes/` and referenced via short `l/` symlinks) plus a
per-container writable upper/`diff` layer. Your **droplet** (the staged app) is
extracted *inside* this filesystem under `/home/vcap`; it is content within the
image, **not** the image itself and not a base layer.

**Resolve the image to its stack volume:**

```bash
mount | grep <handle>                                   # overlay … lowerdir=…/l/XXXX
readlink /var/vcap/data/grootfs/store/unprivileged/l/XXXX   # -> volumes/<sha>
```

**Fingerprint the stack straight out of the volume** (no container, no nsenter):

```bash
V=/var/vcap/data/grootfs/store/unprivileged/volumes/<sha>
grep VERSION $V/etc/os-release
dpkg-query --admindir=$V/var/lib/dpkg -W -f='${Package} ${Version}\n' openssl libc6
```

**Why it matters — two timestamps, two facts:**

- **`images/<handle>/` mtime ≈ when the container was built** (≈ this instance's
  start). The "when."
- **`volumes/<sha>/` mtime ≈ when the stack was imported from the rootfs tar.**
  The "what." grootfs keys the preloaded base volume on the tar's path + mtime,
  so when a new stack tar is placed, the next container create unpacks a **new**
  base volume, and every container built afterward shares it.

So the **count of distinct cflinuxfs4 base volumes** tells you the whole story:
one = every container on the same stack content; two = you're straddling old and
new. List them and map live handles to volumes to see exactly which instances
are on which stack:

```bash
ls -lat --time-style=full-iso /var/vcap/data/grootfs/store/unprivileged/volumes/
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
| GUID → cell + handle | `cfdot actual-lrps \| jq …` | `cell_id`, `process_instance_id` |
| → cell shell | `bosh ssh diego_cell/<cell_id>` | root on the host |
| handle → task PID | `ctr … -n garden task ls` | garden-init PID |
| task PID → app PID | `pstree -p <task-pid>` | app PID |
| app PID → namespaces | `ls -la /proc/<app-pid>/ns` | mnt/net/pid/… |
| isolation demo | `nsenter -t <app-pid> -n\|-p …` | container's view |
| handle → rootfs | `images/<handle>/` | overlay: stack + writable layer |
| rootfs → stack | `l/` symlink → `volumes/<sha>/` | cflinuxfs4 content + version |
