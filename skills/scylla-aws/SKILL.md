---
name: scylla-aws
description: Use when deploying ScyllaDB as a managed service on Omnistrate in AWS with the ScyllaDB Operator, local NVMe storage and backups in Amazon S3 — building the ScyllaDB and S3-bucket services, installing the operator/Manager amenities on an EKS deployment cell, creating instances, and day-2 operations (backup, restore, add/remove members, change instance type, stop/start, restart, replace a member or its VM, delete). For GCP/GCS use scylla-gcp.
---

# ScyllaDB on Omnistrate — AWS, local NVMe, S3 backups

Everything needed to run ScyllaDB as a hosted Omnistrate service on AWS. Data
lives on the nodes' **local NVMe** (Omnistrate RAID-0s the instance-store
disks and serves them through the `omnistrate-local-nvme` StorageClass);
durability comes from replication across members plus Scylla Manager backups
in S3.

All commands use `omnistrate-ctl` (alias `omctl`); log in first with
`omnistrate-ctl login`. You also need `jq`, and optionally the `aws` CLI and
`kubectl` for verification.

## Files

| File | What it is |
|---|---|
| `spec-operator.yaml` | ScyllaDB ServicePlanSpec: `ScyllaCluster` on local NVMe with one internet-facing load balancer per member, lifecycle workflows, and the `nlbSecurityGroup` Terraform resource |
| `spec-s3-bucket.yaml` | Terraform-backed service that creates one S3 bucket + an IAM user/access key scoped to it |
| `terraform/main.tf` | The Terraform module used by `spec-s3-bucket.yaml` |
| `terraform-nlb-sg/main.tf` | Terraform module of the `nlbSecurityGroup` resource: the load balancers' security group, one per instance |
| `amenities.yaml` | Deployment-cell config: managed amenities + ScyllaDB Operator, Scylla Manager and the `ScyllaSnapshot` CRD |

How it fits together:

```
s3-bucket instance ──outputs──► bucketName, bucketRegion, accessKeyId, secretAccessKey
                                        │  (passed as instance params)
                                        ▼
ScyllaDB instance ── ScyllaCluster <id>: N members, one per i4i/i3en/... node, data on local NVMe
   │                   │  Manager agent sidecar ──backups──► s3://<bucket>/backup/...
   │                   ├─ ops Jobs (kubectl + sctool) drive backup/restore/stop/start/replace
   │                   └─ one internet-facing NLB per member (security group: 9042, 19042, 10001)
   │                        node-<n>.<instance zone> ──► member n   (external-dns)
   │                        <endpoint> (list-endpoints) ──► member 0   = contact point
   └── nlbSecurityGroup (Terraform) ── creates that security group in the cell's VPC
cell amenities: scylla-operator · scylla-manager (+ its own 1-node Scylla on EBS) · ScyllaSnapshot CRD
```

Many ScyllaDB instances can share one bucket: Manager separates them by
cluster ID under `backup/`.

## Setup

Run every command from a working copy of this skill folder
(`artifactsLocalPath` in `spec-s3-bucket.yaml` is resolved from the current
directory).

### 1. One-time: let Omnistrate's Terraform create buckets, IAM users and security groups

Hosted Terraform runs as the IAM role `omnistrate-terraform-execution-role` in
your AWS account. If that role doesn't already have broad permissions
(`aws iam list-attached-role-policies --role-name omnistrate-terraform-execution-role`),
grant it S3 and IAM-user permissions scoped to the `scylla-backup-*` names the
bucket module uses, plus security-group permissions for the load balancers'
security group:

```bash
ACCOUNT=<aws-account-id>
cat > scylla-backup-tf-policy.json <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:*",
      "Resource": ["arn:aws:s3:::scylla-backup-*", "arn:aws:s3:::scylla-backup-*/*"] },
    { "Effect": "Allow",
      "Action": ["iam:CreateUser", "iam:DeleteUser", "iam:GetUser", "iam:TagUser", "iam:UntagUser",
                 "iam:ListUserTags", "iam:PutUserPolicy", "iam:GetUserPolicy", "iam:DeleteUserPolicy",
                 "iam:ListUserPolicies", "iam:ListAttachedUserPolicies", "iam:ListGroupsForUser",
                 "iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:ListAccessKeys"],
      "Resource": "arn:aws:iam::${ACCOUNT}:user/scylla-backup-*" },
    { "Effect": "Allow",
      "Action": ["ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:DescribeSecurityGroups",
                 "ec2:DescribeSecurityGroupRules", "ec2:AuthorizeSecurityGroupIngress",
                 "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
                 "ec2:RevokeSecurityGroupEgress", "ec2:CreateTags", "ec2:DescribeVpcs",
                 "ec2:DescribeNetworkInterfaces"],
      "Resource": "*" }
  ]
}
POLICY
aws iam put-role-policy --role-name omnistrate-terraform-execution-role \
  --policy-name scylla-backup-bucket --policy-document file://scylla-backup-tf-policy.json
```

> Tested in an account where the role already had `AdministratorAccess`; the
> scoped policy above is not verified to be minimal.

### 2. Fill in the account placeholders

```bash
omctl account list                        # find your READY AWS account
omctl account describe <account-id> -o json | jq '{awsAccountID, awsBootstrapRoleARN}'

sed -i.bak -e "s/<AWS_ACCOUNT_ID>/<awsAccountID>/g" spec-operator.yaml spec-s3-bucket.yaml
grep -n '<AWS' spec-*.yaml || echo "all placeholders filled"
omctl docs validate --file spec-operator.yaml
omctl docs validate --file spec-s3-bucket.yaml
```

### 3. Build both services

```bash
omctl build -f spec-s3-bucket.yaml --spec-type ServicePlanSpec \
  --product-name "ScyllaDB S3 Backup" --environment Dev --environment-type dev --release-as-preferred

omctl build -f spec-operator.yaml --spec-type ServicePlanSpec \
  --product-name "ScyllaDB" --environment Dev --environment-type dev --release-as-preferred
```

Build from the skill folder: both specs name their Terraform modules by
`artifactsLocalPath` (`terraform`, `terraform-nlb-sg`) relative to the current
directory. The plan names come from the specs' `name:` field: `s3-bucket` and
`ScyllaDB AWS` (the GCP skill builds `ScyllaDB GCP` into the same product).

### 4. Create the backup bucket

```bash
omctl instance create --service "ScyllaDB S3 Backup" --plan s3-bucket \
  --environment Dev --cloud-provider aws --region us-east-1 \
  --resource s3backup --param '{"bucketRegion":"us-east-1"}' --output json
omctl instance describe <bucket-instance-id> --deployment-status | jq -r .status   # RUNNING in ~2 min

omctl instance describe <bucket-instance-id> -o json \
  | jq '[.. | objects | select(has("bucketName"))][0]' > s3-outputs.json
chmod 600 s3-outputs.json
```

Keep `bucketRegion` the same as the ScyllaDB region.

### 5. Install the amenities on the deployment cell

The ScyllaDB spec does **not** install the operator. Three cluster-scoped
pieces go in once per deployment cell from `amenities.yaml`, and every cell
that hosts ScyllaDB needs them **before** an instance lands on it:

| Amenity | What it is |
|---|---|
| `scylla-operator` | ScyllaDB Operator v1.22 + CRDs + webhook (cert via the managed Cert Manager) |
| `scylla-manager` | Scylla Manager 3.12, the backup/restore engine, plus its own 1-member ScyllaDB on a 10 GiB `gp3` volume. The operator registers every ScyllaCluster with it automatically |
| `scylla-snapshot-crd` | `ScyllaSnapshot` CRD. Workflow outputs can only read a resource's `status`, so the backup Job writes the Scylla Manager snapshot tag there; Omnistrate stores it as snapshot metadata for restore |

All three run on the cell's system nodes (`omnistrate.com/control-plane`,
`CriticalAddonsOnly` toleration; ~1.2 CPU / 1.3 GiB in total).

**The cell must support local NVMe.** Check before anything else:

```bash
omctl deployment-cell update-kubeconfig $CELL --kubeconfig ./cell.kubeconfig --role cluster-admin
kubectl --kubeconfig ./cell.kubeconfig get storageclass omnistrate-local-nvme
kubectl --kubeconfig ./cell.kubeconfig -n omnistrate-local-nvme get deploy local-nvme-provisioner
```

Cells created before Omnistrate's local-NVMe feature have neither (seen on a
~1-year-old EKS cell). Symptom: data PVCs `Pending` with `storageclass
"omnistrate-local-nvme" not found`, and the autoscaler logs `pod didn't trigger
scale-up: ... unbound immediate PersistentVolumeClaims`, so no NVMe node is ever
added. There is no ctl command to retrofit a cell — ask Omnistrate support to
roll the cell, or deploy in a region whose cell is new.

Then install the amenities. **`update-config-template` replaces the cell's
whole config**, so merge into what the cell has now:

```bash
omctl deployment-cell list                   # the aws cell for your region (hc-xxxxxxxx)
CELL=<cell-id>
omctl deployment-cell describe-config-template --id $CELL > cell-current.yaml
python3 - <<'EOF'
import yaml
cur = yaml.safe_load(open("cell-current.yaml"))
ours = yaml.safe_load(open("amenities.yaml"))["customAmenities"]
names = {a["name"] for a in cur.get("customAmenities") or []}
cur["customAmenities"] = (cur.get("customAmenities") or []) + [a for a in ours if a["name"] not in names]
yaml.safe_dump(cur, open("cell-merged.yaml", "w"), sort_keys=False)
EOF
omctl deployment-cell update-config-template --id $CELL -f cell-merged.yaml
omctl deployment-cell apply-pending-changes -i $CELL --force

kubectl --kubeconfig ./cell.kubeconfig get crd scyllaclusters.scylla.scylladb.com scyllasnapshots.scylla.omnistrate.io
kubectl --kubeconfig ./cell.kubeconfig -n scylla-operator get pods     # operator + 2 webhook pods Running
kubectl --kubeconfig ./cell.kubeconfig -n scylla-manager get pods      # manager + manager-dc-manager-rack-0 (4/4)
```

Rules:
- **A cell is shared by every service deployed into it.** Check first that it
  doesn't already run a ScyllaDB Operator (`kubectl get crd | grep scylla`).
- **Don't rename an amenity or change its `ReleaseName` on a live cell.** A
  rename installs a second Helm release that fights the first. To change the
  amenities, apply the config without them (Omnistrate uninstalls them), then
  apply the new version.

### 6. Create a ScyllaDB instance

```bash
jq -n --slurpfile o s3-outputs.json --arg pw '<strong-password-12+chars>' '{
  adminPassword: $pw,
  memberCount: "3",
  awsInstanceType: "i4i.xlarge",
  cpuQuantity: "3",
  memoryQuantity: "24Gi",
  storageGiB: "500",
  backupS3BucketName: $o[0].bucketName,
  backupS3BucketRegion: $o[0].bucketRegion,
  backupS3AccessKeyId: $o[0].accessKeyId,
  backupS3SecretAccessKey: $o[0].secretAccessKey
}' > scylla-params.json && chmod 600 scylla-params.json

omctl instance create --service ScyllaDB --plan "ScyllaDB AWS" \
  --environment Dev --cloud-provider aws --region us-east-1 \
  --resource scylladb --param-file scylla-params.json --output json
omctl instance describe <id> --deployment-status | jq -r .status    # RUNNING in ~10 min
```

What create does: Secrets/ConfigMaps + an ops ServiceAccount/Role → the
`ScyllaCluster` (waits for `members == readyMembers == availableMembers ==
memberCount`) → an `auth` Job that creates the CQL superuser. ScyllaDB 2026.x
has **no default `cassandra` superuser**; the Job creates the role through a
member's maintenance socket (`cqlsh /var/lib/scylla/cql.m`), then verifies a
normal password login.

**Sizing.** One member per node (hard anti-affinity), and the Scylla container
is Guaranteed QoS with `cpuQuantity`/`memoryQuantity`. Leave room for the
agent sidecar (200m / 512Mi) and the node's daemonsets:

| Instance type | vCPU / RAM / NVMe | `cpuQuantity` | `memoryQuantity` |
|---|---|---|---|
| `i4i.large` | 2 / 16 GiB / 468 GB | `1` | `10Gi` (tested) |
| `i4i.xlarge` (default) | 4 / 32 GiB / 937 GB | `3` | `24Gi` |
| `i4i.2xlarge` | 8 / 64 GiB / 1.9 TB | `7` | `52Gi` |

`storageGiB` is advisory: each member can grow to its node's whole array.
Production mode (`developerMode: false`) works on Omnistrate's NVMe array —
Scylla runs `iotune` on first boot (~1 min).

**Placement.** Members are pinned to this plan's `scylladb` node pool by the
node labels `omnistrate.com/resource-alias: scylladb` and
`omnistrate.com/product-tier-id` (plus instance type and region). Not by
`omnistrate.com/resource`: a restore target renders `$sys.deployment.resourceID`
as another resource's ID (here `nlbSecurityGroup`'s), and its members would
never schedule. Omnistrate put all nodes of
a pool in **one AZ** in testing, so the cluster survives node loss, not AZ
loss. ScyllaDB warns that a keyspace with RF 3 on one rack is not
"RF-rack-valid"; that is advisory.

### 7. Connect

```bash
omctl instance list-endpoints <id>      # → cql: r-<resource>.<id>.<cell>.<region>.aws.<domain> :9042, :19042
cqlsh r-<resource>.<id>.<cell>.<region>.aws.<domain> 9042 -u admin -p '<password>'
```

Every member has its **own internet-facing NLB** (the operator's
`exposeOptions`) and advertises that load balancer's address to clients, so
token- and shard-aware drivers work from anywhere: give the driver the
endpoint above as contact point and it discovers every member (tested with the
Python `scylla-driver` from outside AWS: all members found, requests
coordinated by the token owners). Members talk to each other on private pod
IPs. Each member also gets a stable name, `node-<n>.<id>.<cell>.<region>.aws.<domain>`
— use a few of them as extra contact points.

- **Only CQL (9042, 19042) and the Manager agent (10001) are reachable.** The
  operator's member Service carries every ScyllaDB port and the NLB gets a
  listener for each; the `nlbSecurityGroup` security group and the nodes'
  security group (`network.ports`) admit only those three. 10001 has to be
  reachable because the operator's own cleanup Jobs call each member through
  its public address; the agent serves only HTTPS and rejects requests
  without the cluster's random token (verified: 401).
- **Client IPs are not preserved** (the operator's in-cell calls couldn't
  hairpin through the NLB otherwise), so ScyllaDB sees the NLB's address.
- The NLBs balance **cross-zone**, because ScyllaDB advertises one of each
  NLB's per-AZ addresses, and members may live in any AZ.
- A stop/start re-creates the load balancers: members get new addresses, the
  names follow (60 s TTL).

## Day-2 operations

`$I` is the ScyllaDB instance ID. After any change, wait for
`omctl instance describe $I --deployment-status | jq -r .status` → `RUNNING`.

All rows were exercised against live 3-member clusters (`i4i.large` →
`i4i.xlarge`) with an RF-3 test table read back at `CONSISTENCY ALL` after every
step — with the per-member load balancers, from outside AWS through the
published endpoint with the Python `scylla-driver`, which found and used every
member each time. Times are for that small data set; data-moving operations
(restore, start, member/VM replace, instance-type change) scale with data size.

| Operation | Command | Tested |
|---|---|---|
| Backup | `omctl instance trigger-backup $I` | ✅ ~40 s |
| Restore (new instance) | `omctl instance restore $I --snapshot-id <snap>` | ✅ ~12 min incl. new nodes (see below: may end `FAILED` although it worked) |
| Add members (3 → 4) | `omctl instance modify $I --param '{"memberCount":"4"}'` | ✅ ~6.5 min, new member gets its own NLB and `node-3` name |
| Remove members (4 → 3) | `omctl instance modify $I --param '{"memberCount":"3"}'` | ✅ ~3 min |
| Change instance type | `omctl instance modify $I --param '{"awsInstanceType":"i4i.xlarge","cpuQuantity":"3","memoryQuantity":"24Gi"}'` | ✅ ~25 min for 3 members |
| Stop | `omctl instance stop $I` | ✅ ~1.5 min; NVMe nodes gone ~4 min later |
| Start | `omctl instance start $I` | ✅ ~7 min; new NLBs, names follow |
| Rolling restart | `omctl instance restart $I` | ✅ ~4 min (pod by pod) |
| Replace a member | `omctl instance operation trigger $I replaceMember --param '{"member":"<id>-dc1-rack1-2"}' -y` | ✅ ~3.5 min |
| Replace a member's VM | `omctl instance operation trigger $I replaceMemberVM --param '{"member":"<id>-dc1-rack1-1"}' -y` | ✅ ~6.5 min; old VM removed by the autoscaler |
| Delete a snapshot | automatic, when a snapshot expires (7 days) | ✅ files removed (see Known limits) |
| Delete | `omctl instance delete $I --yes` | ✅ namespace, cluster RBAC and local PVs gone |

Member names are `<instance-id>-dc1-rack1-<n>`
(`kubectl -n $I get pods -l scylla/cluster=$I`). Custom operations (the two
replaces) run in the background and the instance stays `RUNNING`; follow them
with `omctl workflow list … -i $I` or the Job's logs
(`kubectl -n $I logs job/$I-replace -c ops`, `job/$I-replace-vm`).

### Backup and restore

Scheduled backups run every 24 h and are kept 7 days; `trigger-backup` takes
one on demand. The backup workflow runs a Job (kubectl + `sctool`) that starts a
Scylla Manager backup to `s3:<bucket>` (schema + SSTables of every member),
then records the snapshot tag on a `ScyllaSnapshot` object; Omnistrate stores
it as snapshot metadata:

```bash
omctl instance describe-snapshot $I <snap> -o json | jq '{status, snapshotMetadata}'
# → {"status":"COMPLETE","snapshotMetadata":{"snapshotTag":"sm_20260925084540UTC","location":"s3:scylla-backup-…"}}
```

A restore always creates a **new** instance with the source's parameters: it
creates an empty cluster, the CQL superuser, then runs Manager restore
`--restore-schema` and `--restore-tables` for that tag. The data center is
always named `dc1`, so any snapshot restores into any instance.

- **The target is created from the plan version the snapshot was taken on**,
  not the source's current version. A snapshot from a version with a bug in
  its restore workflow keeps that bug; take a fresh snapshot after upgrading.
- **The target may end `FAILED` although the restore succeeded**
  (`scylladb workflow failed. Reason: child workflow execution already
  started` — the platform re-starts the workflow it is already running).
  Check the data and the endpoint, then run any `modify` (e.g. the same
  `memberCount`) to bring the instance to `RUNNING`.
- The target's workflow inputs are rendered before its endpoint exists, so the
  ops Job derives the contact-point name itself
  (`r-<resource>.<instance>.<cell zone>`, the zone read from the cell's
  external-dns, through a Role in `external-dns-ns` that delete removes).

### Add or remove members

`memberCount` is the number of members (nodes). Adding a member adds a node
and the member streams its share of data. Removing one decommissions the
highest-numbered member first (its data streams to the others). Keep
`memberCount` ≥ the largest replication factor of your keyspaces, or the
decommission fails.

### Change the instance type (scale up / down)

Changing `awsInstanceType` makes Omnistrate add a node pool of the new type and
the operator roll the members onto it. A local NVMe volume can't move between
nodes, so the modify workflow's reconcile Job **replaces** each member whose
re-created pod can't reach its old volume: fresh volume on the new node, data
re-streamed from the other replicas, one member at a time. Change
`cpuQuantity`/`memoryQuantity` in the same modify to fit the new type.
The Job detects a stranded member from its PV: the node it is pinned to is
of the old type, cordoned for scale-down, or gone. This needs `memberCount` ≥ 2
and keyspaces with RF ≥ 2; a 1-member cluster refuses (take a backup and
restore into a new instance instead). Nodes of the old type are removed by the
autoscaler once empty.

### Stop and start

Local NVMe does not survive releasing its VM, so **stop = backup + release**:
the stop Job takes a Scylla Manager backup, records its tag in the
`scylla-stop-snapshot` ConfigMap, then deletes the ScyllaCluster and its local
volumes; the nodes scale away. **Start** re-creates the cluster, the CQL
superuser, and restores that snapshot. Start takes as long as a restore of your
data set. Stop refuses to delete anything if the backup fails, and a start that
fails part-way can be retried (leftovers of the failed schema restore are
dropped first — the cluster was created empty by the same workflow).
`trigger-backup` on a stopped instance records the stop snapshot itself.

### Restart

Rolling restart, one member pod at a time (highest first), each waiting for
the cluster to be healthy again; members come back on the same node with their
local data. (`spec.forceRedeploymentReason` is deliberately not used: the next
modify re-applies the ScyllaCluster without it and would restart every member
a second time.)

### Replace a member / replace its VM

- `replaceMember` wipes one member's local volume and re-creates it; the
  member rejoins with a new host ID and streams its data back (the operator's
  `scylla/replace` procedure). Use it for a member with a corrupted disk.
- `replaceMemberVM` first cordons the member's node, so the replacement lands
  on a different VM; the cordoned node is removed by the autoscaler once empty.
- If a node disappears (EC2 failure), the operator's
  `automaticOrphanedNodeCleanup` replaces its member automatically.

Both need `memberCount` ≥ 2 and RF ≥ 2.

### Delete

```bash
omctl instance delete $I --yes     # deletes the ScyllaCluster (and so its load balancers), its Secrets/ConfigMaps, ops RBAC and the security group
```

Backups stay in the bucket. Deleting the **bucket** instance deletes every
backup in it (`force_destroy = true`).

## Known limits

- **One rack, one AZ.** Members are spread over nodes, not zones (Omnistrate
  placed each node pool in one AZ in testing). Zone-aware racks would need one
  node pool and rack per AZ.
- **Snapshots taken before a stop/start can't be deleted.** Every start
  re-creates the cluster, and Scylla Manager registers it under a new cluster
  ID; Manager only deletes snapshots of the cluster it is running. When such a
  snapshot expires, the deleteBackup Job logs a warning and succeeds (so it
  never blocks instance deletion); its files stay in the bucket — still
  restorable — until the bucket instance is deleted. Deleting them by hand is
  unsafe: Manager de-duplicates SSTables across snapshots.
- **Only manual snapshots can be deleted on demand** (`omctl snapshot delete`
  rejects `AutomatedSnapshot`s, which includes `trigger-backup` ones); the
  others expire after `backupRetentionInDays`.
- **Workflow finalization lags.** Backup, restart and restore workflows show
  every step `success` but stay `RUNNING` for ~10–15 min; the instance is
  locked (`conflicting operation is already in progress`) until then.
- **One NLB per member**, each billed by AWS (hourly + LCU).
- **The network setup is fixed at create** (`exposeOptions` and the load
  balancer class are immutable).

## Parameters (`scylladb` resource)

"Fixed" parameters can't be changed after create.

| Key | Default | Notes |
|---|---|---|
| `adminPassword` | required | 12–128 chars of `A-Za-z0-9!@#%^&*()_+=.-`. Fixed |
| `adminUsername` | `admin` | CQL superuser. Fixed |
| `awsInstanceType` | `i4i.xlarge` | Local-NVMe types only (i4i, i3en, i7ie, i4g, m6id, r6id) |
| `memberCount` | `3` | Members (1–30), one per node. Not called `replicaCount`: the platform overrides a parameter with that key during `start` |
| `cpuQuantity` / `memoryQuantity` | `3` / `24Gi` | Scylla container, requests = limits |
| `storageGiB` | `500` | Advisory local-NVMe request |
| `scyllaVersion` | `2026.2.5` | Changing it performs a rolling upgrade |
| `developerMode` | `false` | `true` relaxes production checks |
| `backupS3BucketName` / `backupS3BucketRegion` | none | s3-bucket outputs `bucketName` / `bucketRegion` |
| `backupS3AccessKeyId` / `backupS3SecretAccessKey` | none | s3-bucket outputs `accessKeyId` / `secretAccessKey` |

The four backup parameters are hidden from end customers (`export: false`) but
every create and restore needs them.

## Editing the spec

`spec-operator.yaml` is long because every value is threaded explicitly
through workflow args → DAG task args → leaf-template inputs, and because the
ops script (`ops.sh` in the `<id>-ops-scripts` ConfigMap — one POSIX-sh script,
selected by `$OP`, run by every Job-based verb) is embedded in each workflow
that installs it: `create`, `modify`, `start` and `restore`. Keep those four
copies identical when you change it. Validate with
`omctl docs validate --file spec-operator.yaml` before every build.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Data PVCs `Pending`: `storageclass "omnistrate-local-nvme" not found` | Cell predates local-NVMe support (step 5) |
| One PVC `Pending` for ~2 min: `local-nvme: array not mounted on this node yet` | Normal on a fresh node: the provisioner retries once the RAID is mounted |
| Create fails: `no matches for kind "ScyllaCluster"` / `"ScyllaSnapshot"` | Amenities missing on that cell (step 5). Apply them, delete the failed instance, create again |
| Workflow step `unsupported delete generic CRD flag` | Only `--ignore-not-found=true` is accepted on delete tasks |
| `conflicting operation is already in progress` right after a backup/restart/restore | Omnistrate finalizes those workflows ~10–15 min after their last step (steps show `success`, parent `RUNNING`). Wait; terminating one marks the instance `FAILED` (recover with any `modify`) |
| Extra NVMe nodes appear during create/scale | Operator cleanup Jobs inherit the rack placement; the spec's `matchLabelKeys` anti-affinity keeps them on the members' nodes — if you edit placement, keep it |
| auth Job fails `cannot log in` | Password with characters outside the regex, or the maintenance socket is disabled |
| Backup Job fails `cluster is not registered with Scylla Manager` | `scylla-manager` amenity missing or unhealthy (`kubectl -n scylla-manager get pods`) |
| ScyllaCluster `Degraded`: `spec.loadBalancerClass: Invalid value: null: may not change once set` | The AWS Load Balancer Controller sets `service.k8s.aws/nlb`; `exposeOptions.nodeService.loadBalancerClass` must declare the same value (the spec does). Immutable: re-create the instance |
| Operator `cleanup-…` Jobs fail `Post "https://magic.host/compaction_manager/…": timeout`, instance stuck in create | They call each member's agent (10001) through its load balancer: 10001 must be open in both `network.ports` and the `nlbSecurityGroup` group, and client-IP preservation off. Failed cleanup Jobs are not retried — delete them and the operator re-creates them |
| Restore target members `Pending`: `didn't match Pod's node affinity` | Placement pinned by `omnistrate.com/resource` — in a restore that renders another resource's ID. Pin by `resource-alias` + `product-tier-id` (the spec does) |
| Restore fails at once: `unresolved workflow input parameters: [$sys.compute.node.instanceType $sys.network.externalClusterEndpoint]` | Neither renders for a restore target; the spec uses `$var.awsInstanceType` and derives the endpoint name. If you still see it, the snapshot is from an older plan version — take a new one |
| Nothing but 9042 answers on a member address from outside | Expected for 7000/7001/7199/9180/10000; 19042 and 10001 must answer (`nc -z <node-n name> 19042`) |
| `kubectl`: `You must be logged in to the server` | The kubeconfig token expired (~1 h). Run `update-kubeconfig` again |

Debug a workflow and its Jobs:

```bash
omctl workflow list -s <service-id> -e <environment-id> -i $I
omctl workflow events <workflow-id> -s <service-id> -e <environment-id> --detail
kubectl --kubeconfig ./cell.kubeconfig -n $I get jobs
kubectl --kubeconfig ./cell.kubeconfig -n $I logs job/<job> -c ops
```
