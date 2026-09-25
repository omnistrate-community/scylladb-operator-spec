# Managed ScyllaDB on Omnistrate (ScyllaDB Operator, local NVMe)

Omnistrate ServicePlanSpecs that turn the [ScyllaDB Operator](https://operator.docs.scylladb.com)
into a managed ScyllaDB SaaS offering on **local NVMe** storage. Omnistrate
provides the Kubernetes substrate (node pools, local-NVMe RAID and
StorageClass, per-instance namespace, load balancers, DNS). The ScyllaDB
Operator runs ScyllaDB, and Scylla Manager takes backups to the cloud's object
store.

There's one ready-to-deploy folder per cloud, packaged as an
[agent skill](https://agentskills.io) with step-by-step `omnistrate-ctl`
instructions:

| Skill | Backups | Status | Contents |
|---|---|---|---|
| [`skills/scylla-aws/`](skills/scylla-aws/SKILL.md) | Amazon S3 | Deployed; every operation tested | `spec-operator.yaml` + `terraform-nlb-sg/`, `spec-s3-bucket.yaml` + `terraform/`, `amenities.yaml` |
| [`skills/scylla-gcp/`](skills/scylla-gcp/SKILL.md) | Google Cloud Storage | Not deployed yet (GCP local SSD must be enabled for your org by Omnistrate support) | `spec-operator.yaml`, `spec-gcs-bucket.yaml` + `terraform/`, `amenities.yaml` |

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
npx skills add <owner>/<repo>                    # both skills
npx skills add <owner>/<repo> -s scylla-aws      # just one
npx skills add <owner>/<repo> --list             # list without installing
```

To use the specs without an agent:

```bash
git clone https://github.com/<owner>/<repo>
cd <repo>/skills/scylla-aws     # or scylla-gcp; then follow SKILL.md
```

## What you get

| Area | Details |
|---|---|
| Deployment model | Hosted (runs in your cloud account), `CUSTOM_TENANCY` |
| ScyllaDB | 2026.2.5 via ScyllaDB Operator v1.22, production mode, 1–30 members (default 3) |
| Storage | Node-local NVMe (`omnistrate-local-nvme`, RAID 0 of the instance-store disks); local-NVMe instance types only |
| Placement | One member per node (hard rule), pinned to the instance's node pool |
| Endpoints | **AWS:** one internet-facing NLB per member, so token/shard-aware drivers work from outside the VPC; a published contact point plus `node-<n>` names (external-dns); only CQL 9042/19042 and the token-protected Manager agent 10001 reachable. **GCP:** a public TCP load balancer to a proxy (`:9042`). Password auth on both |
| Lifecycle | create, modify (members, instance type, CPU/memory, version), stop / start, restart, delete, backup, restore, deleteBackup |
| Custom actions | **Replace Member** (fresh local volume, data re-streamed) and **Replace Member VM** (move a member to a different node) |
| Backups | Scylla Manager 3.12, 24h schedule, 7-day retention |
| Logs | Pod and database logs in the Omnistrate console |

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

GCP: the same cluster behind `cqllb :9042 → cqlProxy (socat) → <id>-client :9042`.

Each ScyllaDB spec defines two resources:

- **`scylladb`**: the customer-facing resource. Its workflows apply and delete
  the `ScyllaCluster`, its Secrets/ConfigMaps and a small ops RBAC, and run
  short-lived Jobs that drive Scylla Manager (`sctool`) and `kubectl` for
  backup, restore, stop/start, member replacement and instance-type changes.
- **AWS: `nlbSecurityGroup`**, an internal Terraform resource that creates the
  per-member load balancers' security group. **GCP: `cqlProxy`**, an internal
  `alpine/socat` pod that bridges the load-balancer port to the cluster's
  client Service.

Local NVMe doesn't survive releasing its VM, so **stop** takes a backup and
releases the nodes, and **start** re-creates the cluster and restores that
backup.

The ScyllaDB Operator, Scylla Manager and the `ScyllaSnapshot` CRD are **not**
in the specs. They're cluster-scoped, so they're installed once per deployment
cell from `amenities.yaml`.
