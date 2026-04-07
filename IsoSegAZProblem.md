# Multi-Datacenter Isolation Segment Architecture

This document describes a Tanzu Application Service (TAS) deployment pattern that separates the management plane from application workloads using isolation segments deployed across multiple datacenters.

## Architecture Overview

### Base Foundation (Management Plane)
The primary Tanzu foundation serves as the management and control plane:

- **Location**: Single datacenter deployment
- **Infrastructure**: Single Kubernetes cluster
- **Availability Zones**: Utilizes resource pools within the cluster as logical AZs
- **Purpose**: Hosts core TAS components (Cloud Controller, UAA, routing, etc.)
- **Scope**: Management operations, API endpoints, and platform services

### Isolation Segment (Application Plane)
The isolation segment provides true multi-datacenter application deployment:

- **Location**: Spans 3 physical datacenters
- **Infrastructure**: 3 separate Kubernetes clusters (one per datacenter)
- **Availability Zones**: 
  - AZ1 = Datacenter 1 (Cluster 1)
  - AZ2 = Datacenter 2 (Cluster 2) 
  - AZ3 = Datacenter 3 (Cluster 3)
- **Purpose**: Hosts application workloads with true geographic distribution
- **Diego Cells**: Distributed across all 3 datacenters within the isolation segment

## Disaster Recovery with Dual Management Planes

### Second Management Foundation
For complete disaster recovery capability, a second management plane foundation can be deployed:

- **Purpose**: Mirror of the primary management foundation
- **Configuration**: Identical management plane components (Cloud Controller, UAA, routing)
- **Isolation Segment**: References the same multi-datacenter isolation segment
- **State Synchronization**: Database replication or backup/restore processes between management planes
- **Failover**: Applications continue running while management operations switch to DR foundation

### Management Plane Placement Options

The dual management plane foundations offer flexible deployment patterns:

#### Option 1: Co-located with Isolation Segment AZs
```
Datacenter 1 (AZ1)
├── Management Foundation 1 (Primary)
├── Kubernetes Cluster 1
└── Diego Cells (Isolation Segment)

Datacenter 2 (AZ2)  
├── Management Foundation 2 (DR)
├── Kubernetes Cluster 2
└── Diego Cells (Isolation Segment)

Datacenter 3 (AZ3)
├── Kubernetes Cluster 3
└── Diego Cells (Isolation Segment)
```

**Benefits:**
- Efficient resource utilization
- Simplified network topology
- Lower latency for management operations in co-located DC

#### Option 2: Separate Management Datacenters
```
Management DC 1
└── Management Foundation 1 (Primary)

Management DC 2
└── Management Foundation 2 (DR)

Datacenter 1 (AZ1)
├── Kubernetes Cluster 1
└── Diego Cells (Isolation Segment)

Datacenter 2 (AZ2)  
├── Kubernetes Cluster 2
└── Diego Cells (Isolation Segment)

Datacenter 3 (AZ3)
├── Kubernetes Cluster 3
└── Diego Cells (Isolation Segment)
```

**Benefits:**
- Complete separation of management and application planes
- Management plane failures don't affect isolation segment infrastructure
- Independent scaling and maintenance of management vs. application infrastructure

#### Option 3: Distributed Management Planes
```
Datacenter A
└── Management Foundation 1 (Primary)

Datacenter B  
└── Management Foundation 2 (DR)

Datacenter 1 (AZ1)
├── Kubernetes Cluster 1
└── Diego Cells (Isolation Segment)

Datacenter 2 (AZ2)  
├── Kubernetes Cluster 2
└── Diego Cells (Isolation Segment)

Datacenter 3 (AZ3)
├── Kubernetes Cluster 3
└── Diego Cells (Isolation Segment)
```

**Benefits:**
- Maximum geographic distribution
- Independent failure domains for all components
- Optimal for regulatory compliance requiring data/control plane separation

### Shared Isolation Segment Configuration

Both management plane foundations reference the same isolation segment:

```bash
# Primary Management Foundation
cf create-isolation-segment multi-dc-seg

# DR Management Foundation  
cf create-isolation-segment multi-dc-seg
```

**Key Characteristics:**
- **Same Segment Name**: Both foundations use identical isolation segment configuration
- **Shared Diego Cells**: The same physical Diego cells can accept deployments from either management plane
- **Application Continuity**: Applications continue running during management plane failover
- **State Synchronization**: Application metadata must be synchronized between management planes

### Failover Scenarios

#### Management Plane Failure
1. **Detection**: Primary management foundation becomes unavailable
2. **DNS Switch**: Update DNS to point to DR management foundation
3. **Developer Experience**: `cf api https://dr-api.example.com`
4. **Application Impact**: Zero - applications continue running on isolation segment
5. **Recovery Time**: Minutes (DNS propagation + user re-targeting)

#### Isolation Segment Datacenter Failure
1. **Automatic Redistribution**: Diego redistributes instances to remaining 2 AZs
2. **Management Plane**: Continues operating from either foundation
3. **No Manual Intervention**: Built-in resilience handles single DC loss
4. **Capacity Planning**: Remaining DCs must handle 1.5x normal load

#### Multiple Failures
1. **Primary Management + 1 DC**: Switch to DR management, apps run on 2 remaining DCs
2. **Both Management Planes**: Applications continue running, restore management capability
3. **Multiple DCs**: Follow standard disaster recovery procedures for affected datacenters

### Operational Considerations

#### Database Synchronization
- **Option 1**: Real-time replication between management plane databases
- **Option 2**: Regular backup/restore cycles with acceptable RTO
- **Option 3**: Event sourcing pattern for application state reconstruction

#### Certificate Management
- **Shared Certificates**: Both management planes use same SSL certificates
- **DNS-based**: Certificates cover both primary and DR endpoints
- **Rotation**: Coordinate certificate updates across both foundations

#### Network Connectivity
- **Management to Isolation Segment**: Both foundations need connectivity to all 3 AZs
- **Inter-Management**: Secure connection for state synchronization
- **Monitoring**: Health checks and failover automation across all components

This dual management plane architecture provides comprehensive disaster recovery while maintaining the benefits of the isolated application workload deployment pattern.

## Benefits Over Stretch Foundation Architecture

### Eliminates Stretch Foundation Problems

**Split Brain Prevention:**
- Management plane operates independently in a single location
- No risk of network partitions affecting core platform operations
- Isolation segment continues running applications even if management plane connectivity is temporarily lost

**Latency Mitigation:**
- Management operations occur within a single datacenter (low latency)
- Application-to-application communication can be optimized per datacenter
- Cross-datacenter traffic limited to actual business requirements, not platform overhead

**MySQL Quorum Protection:**
- Platform databases remain in single datacenter (no quorum issues)
- Application data can use appropriate cross-datacenter replication strategies
- Eliminates complex distributed database coordination for platform operations

### Communication Patterns

**Management to Isolation Segment:**
- Less frequent, less latency-sensitive communication
- Primarily for application lifecycle events (push, scale, restart)
- Can tolerate brief network interruptions without affecting running applications

**Inter-Application Communication:**
- Applications can be designed for their specific latency and consistency requirements
- No forced cross-datacenter communication for platform operations
- Allows for datacenter-local optimizations

## Diego Cell Distribution

### Physical Placement
```
Datacenter 1 (AZ1)
├── Kubernetes Cluster 1
└── Diego Cells (Isolation Segment Pool)
    ├── Cell 1-1
    ├── Cell 1-2
    └── Cell 1-N

Datacenter 2 (AZ2)  
├── Kubernetes Cluster 2
└── Diego Cells (Isolation Segment Pool)
    ├── Cell 2-1
    ├── Cell 2-2
    └── Cell 2-N

Datacenter 3 (AZ3)
├── Kubernetes Cluster 3
└── Diego Cells (Isolation Segment Pool)
    ├── Cell 3-1
    ├── Cell 3-2
    └── Cell 3-N
```

### Application Distribution
When applications are pushed to the isolation segment:

1. **Target Selection**: `cf push app-name --isolation-segment production-seg`
2. **AZ Distribution**: Diego automatically distributes instances across the 3 AZs
3. **Result**: Application instances run in all 3 datacenters simultaneously
4. **Resilience**: Automatic failover if entire datacenter becomes unavailable

## Application Deployment Flow

### Step-by-Step Process

1. **Application Push**: Developer pushes to isolation segment
   ```bash
   cf target -s production-space
   cf push my-app --isolation-segment multi-dc-seg
   ```

2. **Diego Placement**: 
   - Diego scheduler receives placement request
   - Evaluates available cells across all 3 AZs (datacenters)
   - Places instances according to AZ distribution rules

3. **Instance Distribution**:
   ```
   App Instance 1 → Datacenter 1 (Diego Cell 1-1)
   App Instance 2 → Datacenter 2 (Diego Cell 2-1) 
   App Instance 3 → Datacenter 3 (Diego Cell 3-1)
   ```

4. **Traffic Routing**:
   - GoRouter can route to instances in any datacenter
   - Health checking spans all locations
   - Automatic traffic shifting during datacenter failures

## Operational Benefits

### Disaster Recovery
- **Datacenter Loss**: Applications continue running in remaining 2 datacenters
- **Management Plane Loss**: Applications keep running; management operations restored from backup
- **Network Partition**: Isolated datacenters continue serving application traffic

### Maintenance Windows
- **Rolling Datacenter Maintenance**: Take down 1 datacenter at a time
- **Zero-Downtime Platform Updates**: Update management plane independently
- **Independent Scaling**: Scale Diego cells in each datacenter based on local demand

### Compliance and Data Locality
- **Data Residency**: Applications can be constrained to specific datacenters
- **Regulatory Compliance**: Meet requirements for data location and sovereignty
- **Performance Optimization**: Place application instances closer to users/data

## Key Architectural Decisions

1. **Separation of Concerns**: Management plane isolated from application runtime
2. **True Multi-AZ**: Each AZ is genuinely independent infrastructure
3. **Loose Coupling**: Management and isolation segment communication is resilient
4. **Operational Simplicity**: Avoid complex distributed system coordination
5. **Application Focus**: Let apps handle their own cross-datacenter requirements

This architecture provides the benefits of multi-datacenter deployment while avoiding the operational complexity and failure modes of stretch cluster foundations.