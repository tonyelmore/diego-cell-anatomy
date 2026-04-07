
## Tracing an Application Through the Diego Cell

This guide demonstrates how to trace a Cloud Foundry application from the CF CLI down through the container runtime and namespace isolation on a Diego cell. By following these steps, you'll understand how applications are containerized and isolated within the Diego architecture.

### Step 1: Get the Application GUID

Start by identifying your application's unique identifier:

```bash
cf app <app-name> --guid
```

This returns the GUID that Diego uses to track and manage your application instance.

### Step 2: List Container Tasks Using the Container Runtime

On the Diego cell, use the containerd CLI to see running containers:

```bash
cd /var/vcap/packages/containerd/bin
./ctr -a /var/vcap/sys/run/containerd/containerd.sock -n garden task ls
```

This command:
- Uses the containerd socket at `/var/vcap/sys/run/containerd/containerd.sock`
- Queries the `garden` namespace where Diego containers run
- Lists all active container tasks along with a Process ID (PID)

Look for your application's container by matching the GUID.

### Step 3: Find the Application Process ID

The application container has the TASK id that matches the application guid.

Once you've identified the container, the main Process ID (PID) of your application will be for the "/tmp/garden-init" process which is the process used to create the container.

You can see the application process using `ps aux | grep <app-process-name>`

Note: you can run `ps -aef | grep garden-init` and the resulting processes should match the list of processes from the `ctr task list` command.


### Step 4: Examine Process Namespaces

With the application PID, examine the namespace isolation:

```bash
ls -la /proc/<PID>/ns
```

This shows the namespace links for your application process. You'll see entries like:
- `cgroup` - Control group namespace
- `ipc` - Inter-process communication namespace  
- `mnt` - Mount namespace (filesystem isolation)
- `net` - Network namespace (network stack isolation)
- `pid` - Process ID namespace
- `user` - User namespace
- `uts` - Unix Timesharing namespace (hostname/domain)

### Step 5: Understanding Namespace Isolation

Each namespace provides a different type of isolation:

- **Mount namespace**: Isolates the filesystem view, giving each container its own root filesystem
- **PID namespace**: Provides process isolation - containers see only their own processes
- **Network namespace**: Gives each container its own network stack (IP, routing tables, interfaces)
- **IPC namespace**: Isolates System V IPC and POSIX message queues
- **UTS namespace**: Isolates hostname and domain name
- **User namespace**: Maps user and group IDs between container and host
- **Cgroup namespace**: Virtualizes the view of `/proc/self/cgroup`

### Step 6: Network Namespace Demonstration

The network namespace is particularly important for understanding container isolation. Compare network interfaces:

**On the Diego cell (host namespace):**
```bash
ifconfig
```

**Inside the container's network namespace:**
```bash
nsenter -t <PID> -n ifconfig
```

You'll notice:
- The Diego cell shows all physical and virtual interfaces
- The container sees only its isolated network interfaces (typically `lo` and a virtual ethernet interface)
- Different IP addresses and routing tables between host and container

### Step 7: Process Isolation in Action

The PID namespace demonstrates how processes are isolated:

**On the Diego cell:**
```bash
ps ax
```

This shows ALL processes running on the cell - Diego components, other applications, system processes, etc.

**Inside the container's PID namespace:**
```bash
nsenter -t <PID> -p ps ax
```

From inside the container, you'll only see:
- The application's own processes
- Any child processes it has spawned
- The container init process (usually PID 1)

This explains how multiple applications can run on the same Diego cell without interfering with each other, even though they share the same underlying kernel.

### Key Takeaways

- **Garden-runC** provides the container runtime interface for Diego
- **Containerd** manages the actual container lifecycle
- **Linux namespaces** provide the core isolation mechanisms
- **Each application** gets its own isolated view of system resources
- **The Diego cell** can safely run multiple applications through namespace isolation

This layered approach allows Cloud Foundry to provide secure multi-tenancy while maintaining efficiency through shared kernel resources.

## How does application traffic get to the application running in the container?

Understanding how traffic reaches containerized applications on Diego cells requires examining the networking stack, particularly iptables rules that handle NAT (Network Address Translation) and forwarding between containers.

### Traffic Flow Overview

When traffic reaches a Diego cell destined for a containerized application, it follows this path:

1. **External Traffic** → GoRouter → Diego Cell Host Network
2. **Host Network** → iptables NAT rules → Container Network Namespace
3. **Container Network** → Application Process

### Examining iptables NAT Rules

The key to understanding traffic routing is examining the NAT table in iptables, which handles address translation:

```bash
# View all NAT rules
sudo iptables -t nat -L -n -v

# Focus on PREROUTING chain (incoming traffic)
sudo iptables -t nat -L PREROUTING -n -v

# Focus on POSTROUTING chain (outgoing traffic)
sudo iptables -t nat -L POSTROUTING -n -v
```

**Key NAT chains for container traffic:**
- **PREROUTING**: Modifies packets as they arrive (DNAT - Destination NAT)
- **POSTROUTING**: Modifies packets as they leave (SNAT - Source NAT)
- **OUTPUT**: For locally generated packets

### Container-Specific NAT Rules

For each application container, Diego/Garden creates specific NAT rules:

```bash
# Look for rules targeting container IP ranges
sudo iptables -t nat -L -n | grep "10.255"

# Example output shows DNAT rules like:
# DNAT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:61054 to:10.255.29.2:61001
```

This rule means:
- Traffic arriving on host port `61054`
- Gets redirected (DNAT) to container IP `10.255.29.2` port `61001`
- The container sees the traffic as if it arrived directly

### Forward Rules for Same Diego Cell Traffic

The FORWARD chain handles traffic between containers on the same Diego cell:

```bash
# View forward rules
sudo iptables -L FORWARD -n -v

# Look for container-to-container rules
sudo iptables -L FORWARD -n -v | grep "10.255"
```

**Same Cell Container-to-Container Traffic:**
```bash
# Example forward rules for C2C networking
ACCEPT all -- 10.255.0.0/16 10.255.0.0/16 /* allow c2c traffic */
ACCEPT all -- 10.255.29.0/24 10.255.29.0/24 /* same cell container traffic */
```

These rules allow:
- Direct communication between containers in the same subnet (`10.255.29.0/24`)
- Bypassing NAT for local container-to-container calls
- Efficient routing without leaving the host network namespace

### Forward Rules for Different Diego Cell Traffic

When using container-to-container networking across Diego cells, additional routing occurs:

```bash
# Check for cross-cell routing rules
sudo iptables -L FORWARD -n -v | grep -A5 -B5 "c2c"

# Look for VXLAN or overlay network rules
ip route show | grep "10.255"
```

**Cross-Cell Container Traffic Flow:**
1. **Container A** (Cell 1) → **Host Network** (Cell 1)
2. **FORWARD rule** allows traffic to leave via overlay network
3. **Overlay Network** (VXLAN) → **Host Network** (Cell 2)
4. **FORWARD rule** on Cell 2 allows traffic to **Container B**

**Example cross-cell forward rules:**
```bash
# Allow traffic to remote container subnets via overlay
ACCEPT all -- 10.255.0.0/16 10.255.0.0/16 /* cross-cell c2c via overlay */
ACCEPT all -- 0.0.0.0/0 10.255.0.0/16 i:silk-vtep /* overlay interface traffic */
```

### VXLAN Overlay Network

Container-to-container networking across cells uses VXLAN tunneling:

```bash
# View VXLAN interfaces
ip link show type vxlan

# Example output:
# silk-vtep: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1410 qdisc noqueue state UNKNOWN
```

**Overlay Network Components:**
- **silk-vtep**: VXLAN Tunnel End Point for cross-cell communication
- **Encapsulation**: Container traffic wrapped in VXLAN headers
- **Routing**: Each cell knows routes to remote container subnets

### Practical Investigation Commands

**To trace traffic flow for a specific application:**

1. **Find the container IP:**
```bash
nsenter -t <PID> -n ip addr show
```

2. **Check NAT rules for that IP:**
```bash
sudo iptables -t nat -L -n | grep "<container-ip>"
```

3. **Verify forward rules:**
```bash
sudo iptables -L FORWARD -n -v | grep "<container-subnet>"
```

4. **Test connectivity:**
```bash
# From host to container
curl http://<container-ip>:8080

# From container to container (same cell)
nsenter -t <PID> -n curl http://<other-container-ip>:8080
```

### Security Policies

Diego also implements security group rules through iptables:

```bash
# Check for security group chains
sudo iptables -L -n | grep -i security
sudo iptables -L -n | grep -i asg

# Example security group rules:
# DROP all -- 10.255.29.2 0.0.0.0/0 /* deny external access */
# ACCEPT tcp -- 10.255.29.2 10.244.0.0/16 tcp dpt:5432 /* allow db access */
```

This iptables-based networking approach allows Diego to:
- **Isolate containers** while enabling controlled communication
- **Route traffic efficiently** both within and across Diego cells
- **Enforce security policies** at the network level
- **Scale networking** without requiring external load balancers for container-to-container traffic

The combination of namespaces for isolation and iptables for routing provides Diego with a powerful, flexible networking foundation that supports both application isolation and inter-application communication patterns.
