# Managed ScyllaDB on Omnistrate (ScyllaDB Operator, local NVMe)

Omnistrate ServicePlanSpecs that turn the [ScyllaDB Operator](https://operator.docs.scylladb.com)
into a managed ScyllaDB SaaS offering on **local NVMe** storage. Omnistrate
provides the Kubernetes substrate (node pools, local-NVMe RAID and
StorageClass, per-instance namespace, load balancers, DNS). The ScyllaDB
Operator runs ScyllaDB, and Scylla Manager takes backups to the cloud's object
store.

Home: [omnistrate-community/scylladb-operator-spec](https://github.com/omnistrate-community/scylladb-operator-spec).

There's one ready-to-deploy folder per cloud, packaged as an
[agent skill](https://agentskills.io) with step-by-step `omnistrate-ctl`
instructions:

| Skill | Backups | Status | Contents |
|---|---|---|---|
| [`skills/scylla-aws/`](skills/scylla-aws/SKILL.md) | Amazon S3 | Deployed; every operation tested | `spec-operator.yaml` + `terraform-nlb-sg/`, `spec-s3-bucket.yaml` + `terraform/`, `amenities.yaml` |
| [`skills/scylla-gcp/`](skills/scylla-gcp/SKILL.md) | Google Cloud Storage | Deployed; every operation tested (GCP local SSD must be enabled for your org by Omnistrate support) | `spec-operator.yaml` + `terraform-nlb-fw/`, `spec-gcs-bucket.yaml` + `terraform/`, `amenities.yaml` |

Each `SKILL.md` covers:
- the one-time IAM grant for Omnistrate's Terraform identity
- filling in the account placeholders
- building the bucket and ScyllaDB services
- installing the operator, Scylla Manager and `ScyllaSnapshot` CRD amenities on
  the deployment cell (and checking the cell supports local NVMe)
- creating an instance and connecting
- day-2 operations: backup, restore, adding and removing members, changing the
  instance type, stop/start, rolling restart, replacing a member or its VM,
  delete

## Install

With the [`skills` CLI](https://github.com/vercel-labs/skills), which detects
your agents (Claude Code, Codex, Copilot, …):

```bash
npx skills add omnistrate-community/scylladb-operator-spec                   # both skills
npx skills add omnistrate-community/scylladb-operator-spec -s scylla-aws     # just one
npx skills add omnistrate-community/scylladb-operator-spec --list            # list without installing
```

To use the specs without an agent:

```bash
git clone https://github.com/omnistrate-community/scylladb-operator-spec
cd scylladb-operator-spec/skills/scylla-aws     # or scylla-gcp; then follow SKILL.md
```

## What you get

| Area | Details |
|---|---|
| Deployment model | Hosted (runs in your cloud account), `CUSTOM_TENANCY` |
| ScyllaDB | 2026.2.5 via ScyllaDB Operator v1.22, production mode, 1–30 members (default 3) |
| Storage | Node-local NVMe (`omnistrate-local-nvme`, RAID 0 of the instance-store disks); local-NVMe instance types only |
| Placement | One member per node (hard rule), pinned to the instance's node pool |
| Endpoints | One internet-facing load balancer per member (AWS: NLB; GCP: external passthrough LB), so token/shard-aware drivers work from outside the VPC; a published contact point plus `node-<n>` names (external-dns); only CQL 9042/19042 and the token-protected Manager agent 10001 reachable (AWS: a security group; GCP: VPC firewall rules). Password auth |
| Lifecycle | create, modify (members, instance type, CPU/memory, version), stop / start, restart, delete, backup, restore, deleteBackup |
| Custom actions | **Replace Member** (fresh local volume, data re-streamed) and **Replace Member VM** (move a member to a different node) |
| Backups | Scylla Manager 3.12, 24h schedule, 7-day retention |
| Monitoring | Per instance: Prometheus + Grafana from the ScyllaDB Operator (`ScyllaDBMonitoring`) with the ScyllaDB dashboards and alert rules; Grafana at `grafana.<endpoint>` behind the cell's NGINX Ingress, public TLS, password-protected (`grafanaPassword`). Omnistrate's built-in logs/metrics are off |

## Architecture

AWS:

```
 client ──► contact point (list-endpoints) ─┐   then, driver-routed, straight to every member:
                                             ▼
   ┌── NLB member 0 ──┐ ┌── NLB member 1 ──┐ ┌── NLB member 2 ──┐   node-<n>.<instance zone>
   │  SG: 9042 19042  │ │  SG: 9042 19042  │ │  SG: 9042 19042  │   (external-dns)
   │      10001       │ │      10001       │ │      10001       │
   └────────┬─────────┘ └────────┬─────────┘ └────────┬─────────┘
   ScyllaCluster <instanceId>: dc1/rack1, one member per local-NVMe node (pod IPs between members)
     └─ Manager agent sidecar ──backups──► s3://<bucket>/backup/...   ◄── bucket service (Terraform)
   nlbSecurityGroup (Terraform) ── creates the NLBs' security group in the cell's VPC
   ops Jobs (kubectl + sctool, on system nodes): auth, backup, restore, stop, start,
   reconcile, restart, replace, delete-backup
```

GCP: the same layout, with external passthrough load balancers (`externalTrafficPolicy: Local`) and an
`nlbFirewall` Terraform resource whose VPC firewall rules keep the members' internal ports closed to the internet.

Each ScyllaDB spec defines two resources:

- **`scylladb`**: the customer-facing resource. Its workflows apply and delete
  the `ScyllaCluster`, its Secrets/ConfigMaps and a small ops RBAC, and run
  short-lived Jobs that drive Scylla Manager (`sctool`) and `kubectl` for
  backup, restore, stop/start, member replacement and instance-type changes.
- **`nlbSecurityGroup` (AWS) / `nlbFirewall` (GCP)**, an internal Terraform
  resource that restricts the per-member load balancers to the client ports:
  a security group on AWS, VPC firewall rules on GCP.

Local NVMe doesn't survive releasing its VM, so **stop** takes a backup and
releases the nodes, and **start** re-creates the cluster and restores that
backup.

The ScyllaDB Operator, Scylla Manager and the `ScyllaSnapshot` CRD are **not**
in the specs. They're cluster-scoped, so they're installed once per deployment
cell from `amenities.yaml`.

## Performance

`cassandra-stress` (ScyllaDB's `scylladb/cassandra-stress:3.21.1`) from three
client pods in the same Kubernetes cluster (a separate Omnistrate plan, its own
namespace and nodes: 3 × `c7i.2xlarge` / 3 × `n2-standard-8`), 256 threads each,
against 3 members with 3 cores and 24 GiB for ScyllaDB each. 1 KiB rows,
replication factor 3, `CL=QUORUM` for every operation. Clients connect like
external ones: contact point, then each member's own load balancer. Prefill:
15 M rows; write, read and mixed (1 write : 3 reads) ran 10 min each. Totals
over the three clients; latencies are the worst client's. No errors in any phase.

| Phase | AWS 3 × `i4i.xlarge` op/s | p50 / p99 / p99.9 (ms) | GCP 3 × `n2-highmem-4` op/s | p50 / p99 / p99.9 (ms) |
|---|---|---|---|---|
| Prefill (write) | 70,805 | 3.9 / 87 / 107 | 56,904 | 2.8 / 113 / 146 |
| Write | 63,084 | 4.4 / 88 / 111 | 48,570 | 2.9 / 127 / 159 |
| Read | 80,646 | 5.0 / 41 / 50 | 50,857 | 3.1 / 109 / 122 |
| Mixed | 64,711 | 4.9 / 66 / 89 | 46,608 | 3.5 / 100 / 127 |

These are saturation numbers (768 requests in flight): tail latencies reflect
queueing at full load, not latency at a moderate rate.

## Screenshots

The managed service running on Omnistrate: a 3-member cluster on each cloud
(AWS: 3 × `i4i.xlarge` in `us-east-1`; GCP: 3 × `n2-highmem-4` in `us-east1`)
under a `cassandra-stress` load. Account, project, subscription and org
details are blurred.

### Omnistrate portal

The two plans, one per cloud:

![The ScyllaDB AWS and ScyllaDB GCP plans in the Omnistrate portal](docs/images/portal-plans.png)

Plan blueprint: the `scylladb` operator resource and its Terraform-managed load-balancer security group (AWS) or firewall (GCP). The red `cqlProxy` card is the CQL proxy of earlier plan versions, which Omnistrate keeps as deprecated after it was removed from the spec:

| AWS | GCP |
|---|---|
| ![AWS plan blueprint](docs/images/portal-architecture-aws.png) | ![GCP plan blueprint](docs/images/portal-architecture-gcp.png) |

Workflows for the service, and one successful workflow with its steps (AWS: create; GCP: start, which re-creates the cluster and restores the stop backup):

![Workflow list for the ScyllaDB service](docs/images/portal-workflows.png)

| AWS | GCP |
|---|---|
| ![AWS create workflow with its steps](docs/images/portal-workflow-aws.png) | ![GCP start workflow with its steps](docs/images/portal-workflow-gcp.png) |

Instance details: status, instance type, members and parameters (secrets masked):

| AWS | GCP |
|---|---|
| ![AWS instance details](docs/images/portal-instance-aws.png) | ![GCP instance details](docs/images/portal-instance-gcp.png) |

Endpoints: the CQL contact point (9042 and shard-aware 19042) and Grafana:

| AWS | GCP |
|---|---|
| ![AWS instance endpoints](docs/images/portal-endpoints-aws.png) | ![GCP instance endpoints](docs/images/portal-endpoints-gcp.png) |

Nodes: the ScyllaDB members, monitoring pods and completed ops Jobs:

| AWS | GCP |
|---|---|
| ![AWS instance nodes](docs/images/portal-nodes-aws.png) | ![GCP instance nodes](docs/images/portal-nodes-gcp.png) |

Backups taken by Scylla Manager (24 h RPO, 7-day retention):

| AWS | GCP |
|---|---|
| ![AWS instance backups](docs/images/portal-backups-aws.png) | ![GCP instance backups](docs/images/portal-backups-gcp.png) |

### Monitoring (Grafana)

The ScyllaDB dashboards, one folder per ScyllaDB release (the same on both clouds):

![Grafana dashboard list with the scylladb-* folders](docs/images/grafana-dashboards.png)

Overview (`scylladb-2026.2`) during the load: requests/s, latencies, nodes up:

| AWS | GCP |
|---|---|
| ![AWS Grafana Overview dashboard under load](docs/images/grafana-overview-aws.png) | ![GCP Grafana Overview dashboard under load](docs/images/grafana-overview-gcp.png) |

Detailed: load, requests and reads/writes per member, tablets per member:

| AWS | GCP |
|---|---|
| ![AWS Grafana Detailed dashboard](docs/images/grafana-detailed-aws.png) | ![GCP Grafana Detailed dashboard](docs/images/grafana-detailed-gcp.png) |
