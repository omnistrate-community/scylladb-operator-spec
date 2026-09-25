---
name: scylla-gcp
description: Use when deploying ScyllaDB as a managed service on Omnistrate in GCP with the ScyllaDB Operator, local SSD storage and backups in Google Cloud Storage — building the ScyllaDB and GCS-bucket services, installing the operator/Manager amenities on a GKE deployment cell, creating instances, and day-2 operations (backup, restore, add/remove members, change machine type, stop/start, restart, replace a member or its VM, delete). For AWS/S3 use scylla-aws.
---

# ScyllaDB on Omnistrate — GCP, local SSD, GCS backups

Everything needed to run ScyllaDB as a hosted Omnistrate service on GCP. Data
lives on the nodes' **local NVMe SSDs** (Omnistrate RAID-0s them and serves them
through the `omnistrate-local-nvme` StorageClass); durability comes from
replication across members plus Scylla Manager backups in GCS.

> **Status: not yet deployed.** This variant shares every workflow and the ops
> script with `scylla-aws`, where all operations were exercised end to end.
> The GCP-specific parts — GCS credentials mounted into the Manager agent,
> `EphemeralStorageLocalSsdConfig`, GKE system-node tolerations, the
> `pd-balanced` class for Manager's store — have **not** run yet: local SSD on
> GCP is gated per organization, and the plan build fails with
> `To enable GCP NVMe Local SSD feature, please contact support@omnistrate.com`
> until Omnistrate enables it. Treat the first deployment as a test.

All commands use `omnistrate-ctl` (alias `omctl`); log in first with
`omnistrate-ctl login`. You also need `gcloud` (logged in to the GCP project),
`jq`, and optionally `kubectl` for verification.

## Files

| File | What it is |
|---|---|
| `spec-operator.yaml` | ScyllaDB ServicePlanSpec: `ScyllaCluster` on local SSD + CQL load balancer + lifecycle workflows. **Generated** — see "Editing" |
| `spec-gcs-bucket.yaml` | Terraform-backed service that creates one GCS bucket + a service account/key scoped to it |
| `terraform/main.tf` | The Terraform module used by `spec-gcs-bucket.yaml` |
| `amenities.yaml` | Deployment-cell config: managed amenities + ScyllaDB Operator, Scylla Manager and the `ScyllaSnapshot` CRD |

How it fits together:

```
gcs-bucket instance ──outputs──► bucketName, bucketLocation, credentialsBase64
                                        │  (passed as instance params)
                                        ▼
ScyllaDB instance ── ScyllaCluster <id>: N members, one per n2 node with 2 local SSDs
   │                   │  Manager agent sidecar ──backups──► gs://<bucket>/backup/...
   │                   └─ ops Jobs (kubectl + sctool) drive backup/restore/stop/start/replace
   └── TCP LB cqllb:9042 → cqlProxy (socat) → <id>-client:9042
cell amenities: scylla-operator · scylla-manager (+ its own 1-node Scylla on pd-balanced) · ScyllaSnapshot CRD
```

Many ScyllaDB instances can share one bucket: Manager separates them by
cluster ID under `backup/`.

## Setup

Run every command from a working copy of this skill folder
(`artifactsLocalPath` in `spec-gcs-bucket.yaml` is resolved from the current
directory).

### 0. One-time: have Omnistrate enable GCP local SSD

Email support@omnistrate.com to enable the GCP NVMe local SSD feature for your
organization. Without it the ScyllaDB plan build fails with `To enable GCP NVMe
Local SSD feature, please contact support@omnistrate.com`.

### 1. One-time: let Omnistrate's Terraform create buckets in your project

Hosted Terraform runs as the service account `omnistrate-tf-<org-id>` in your
project. It has no permissions by default, so grant them yourself:

```bash
PROJECT=<gcp-project-id>
ORG_ID=$(omctl deployment-cell describe-config-template --cloud gcp | awk '/^Organization:/{print tolower($2)}')
TF_SA="omnistrate-tf-${ORG_ID}@${PROJECT}.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$TF_SA" --project "$PROJECT"   # must exist
for r in roles/storage.admin roles/iam.serviceAccountAdmin roles/iam.serviceAccountKeyAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$TF_SA" \
    --role="$r" --condition=None --format=none
done
# Service-account key creation must not be blocked by org policy:
gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation \
  --project "$PROJECT" --effective
```

Without this, the bucket deploy fails with
`omnistrate-tf-…  does not have storage.buckets.create access`.

### 2. Fill in the account placeholders

```bash
omctl account list                        # find your READY GCP account
omctl account describe <account-id> -o json | jq '{gcpProjectID, gcpProjectNumber, gcpServiceAccountEmail}'

sed -i.bak \
  -e "s/<GCP_PROJECT_ID>/<gcpProjectID>/" \
  -e "s/<GCP_PROJECT_NUMBER>/<gcpProjectNumber>/" \
  -e "s/<GCP_BOOTSTRAP_SA_EMAIL>/<gcpServiceAccountEmail>/" \
  spec-operator.yaml spec-gcs-bucket.yaml
grep -n '<GCP' spec-*.yaml || echo "all placeholders filled"
omctl docs validate --file spec-operator.yaml
omctl docs validate --file spec-gcs-bucket.yaml
```

### 3. Build both services

```bash
omctl build -f spec-gcs-bucket.yaml --spec-type ServicePlanSpec \
  --product-name "ScyllaDB GCS Backup" --environment Dev --environment-type dev --release-as-preferred

omctl build -f spec-operator.yaml --spec-type ServicePlanSpec \
  --product-name "ScyllaDB" --environment Dev --environment-type dev --release-as-preferred
```

The plan names come from the specs' `name:` field: `gcs-bucket` and
`ScyllaDB GCP` (the AWS skill builds `ScyllaDB AWS` into the same product).

### 4. Create the backup bucket

```bash
omctl instance create --service "ScyllaDB GCS Backup" --plan gcs-bucket \
  --environment Dev --cloud-provider gcp --region us-central1 \
  --resource gcsbackup --param '{"bucketLocation":"us-central1"}' --output json
omctl instance describe <bucket-instance-id> --deployment-status | jq -r .status   # RUNNING in ~2 min

omctl instance describe <bucket-instance-id> -o json \
  | jq '[.. | objects | select(has("bucketName"))][0]' > gcs-outputs.json
chmod 600 gcs-outputs.json
```

Keep `bucketLocation` the same as the ScyllaDB region.

### 5. Install the amenities on the deployment cell

The ScyllaDB spec does **not** install the operator. Three cluster-scoped
pieces go in once per deployment cell from `amenities.yaml`, and every cell
that hosts ScyllaDB needs them **before** an instance lands on it:

| Amenity | What it is |
|---|---|
| `scylla-operator` | ScyllaDB Operator v1.22 + CRDs + webhook (cert via the managed Cert Manager) |
| `scylla-manager` | Scylla Manager 3.12, the backup/restore engine, plus its own 1-member ScyllaDB on a 10 GiB `pd-balanced` disk. The operator registers every ScyllaCluster with it automatically |
| `scylla-snapshot-crd` | `ScyllaSnapshot` CRD. Workflow outputs can only read a resource's `status`, so the backup Job writes the Scylla Manager snapshot tag there; Omnistrate stores it as snapshot metadata for restore |

All three run on the cell's system nodes (`omnistrate.com/control-plane`;
GKE system nodes also need the `components.gke.io/gke-managed-components`
toleration, which `amenities.yaml` carries; ~1.2 CPU / 1.3 GiB in total).
Don't add `priorityClassName: system-cluster-critical` — GKE only allows it in
`kube-system`.

**The cell must support local NVMe.** Check before anything else:

```bash
omctl deployment-cell update-kubeconfig $CELL --kubeconfig ./cell.kubeconfig --role cluster-admin
kubectl --kubeconfig ./cell.kubeconfig get storageclass omnistrate-local-nvme
kubectl --kubeconfig ./cell.kubeconfig -n omnistrate-local-nvme get deploy local-nvme-provisioner
```

Cells created before Omnistrate's local-NVMe feature have neither (seen on a
~1-year-old EKS cell; the same applies to old GKE cells). Symptom: data PVCs `Pending` with `storageclass
"omnistrate-local-nvme" not found`, and the autoscaler logs `pod didn't trigger
scale-up: ... unbound immediate PersistentVolumeClaims`, so no NVMe node is ever
added. There is no ctl command to retrofit a cell — ask Omnistrate support to
roll the cell, or deploy in a region whose cell is new.

Then install the amenities. **`update-config-template` replaces the cell's
whole config**, so merge into what the cell has now:

```bash
omctl deployment-cell list                   # the gcp cell for your region (hc-xxxxxxxx)
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
jq -n --slurpfile o gcs-outputs.json --arg pw '<strong-password-12+chars>' '{
  adminPassword: $pw,
  memberCount: "3",
  gcpInstanceType: "n2-highmem-4",
  cpuQuantity: "3",
  memoryQuantity: "24Gi",
  storageGiB: "500",
  backupGcsBucketName: $o[0].bucketName,
  backupGcsCredentials: $o[0].credentialsBase64
}' > scylla-params.json && chmod 600 scylla-params.json

omctl instance create --service ScyllaDB --plan "ScyllaDB GCP" \
  --environment Dev --cloud-provider gcp --region us-central1 \
  --resource scylladb --param-file scylla-params.json --output json
omctl instance describe <id> --deployment-status | jq -r .status
```

What create does: Secrets/ConfigMaps + an ops ServiceAccount/Role → the
`ScyllaCluster` (waits for `members == readyMembers == availableMembers ==
memberCount`) → an `auth` Job that creates the CQL superuser. ScyllaDB 2026.x
has **no default `cassandra` superuser**; the Job creates the role through a
member's maintenance socket (`cqlsh /var/lib/scylla/cql.m`), then verifies a
normal password login.

**Sizing.** One member per node (hard anti-affinity), and the Scylla container
is Guaranteed QoS with `cpuQuantity`/`memoryQuantity`. Leave room for the
agent sidecar (200m / 512Mi) and the node's daemonsets. Every machine type is
provisioned with **2 local SSDs (2 × 375 GB, RAID 0)** —
`EphemeralStorageLocalSsdConfig.localSsdCount` under `compute.instanceTypes`
in the spec; raise it if you need more (allowed counts depend on the machine
family, see Google's local SSD docs):

| Machine type | vCPU / RAM | `cpuQuantity` | `memoryQuantity` |
|---|---|---|---|
| `n2-highmem-4` (default) | 4 / 32 GB | `3` | `24Gi` |
| `n2-highmem-8` | 8 / 64 GB | `7` | `52Gi` |
| `n2-standard-8` | 8 / 32 GB | `7` | `24Gi` |

`storageGiB` is advisory: each member can grow to its node's whole array.
Production mode (`developerMode: false`) worked on Omnistrate's NVMe array on
AWS; Scylla runs `iotune` on first boot (~1 min).

**Placement.** Members are pinned to the instance's node pool
(`omnistrate.com/resource`, instance type, region). Omnistrate put all nodes of
a pool in **one AZ** in testing, so the cluster survives node loss, not AZ
loss. ScyllaDB warns that a keyspace with RF 3 on one rack is not
"RF-rack-valid"; that is advisory.

### 7. Connect

```bash
omctl instance list-endpoints <id>
cqlsh cqllb.<id>.<cell>.<region>.gcp.<domain> 9042 -u admin -p '<password>'
```

The CQL load balancer points at a socat proxy in front of the cluster's client
Service. Topology-aware drivers learn the members' private addresses and can't
reach them from outside the VPC: configure the driver to use only the contact
point (e.g. a whitelist/"single host" load-balancing policy), or connect from
inside the VPC.

## Day-2 operations

`$I` is the ScyllaDB instance ID. After any change, wait for
`omctl instance describe $I --deployment-status | jq -r .status` → `RUNNING`.

The workflows are identical to `scylla-aws`, where every row was exercised
against a live cluster (times below are from AWS, small data set). They have
not run on GCP yet.

| Operation | Command | Tested on AWS |
|---|---|---|
| Backup | `omctl instance trigger-backup $I` | ✅ ~40 s |
| Restore (new instance) | `omctl instance restore $I --snapshot-id <snap>` | ✅ ~12 min incl. new nodes |
| Add members (3 → 4) | `omctl instance modify $I --param '{"memberCount":"4"}'` | ✅ ~10 min |
| Remove members (4 → 3) | `omctl instance modify $I --param '{"memberCount":"3"}'` | ✅ ~3 min |
| Change machine type | `omctl instance modify $I --param '{"gcpInstanceType":"n2-highmem-8","cpuQuantity":"7","memoryQuantity":"52Gi"}'` | ✅ ~25 min for 3 members |
| Stop | `omctl instance stop $I` | ✅ ~1.5 min; NVMe nodes gone ~4 min later |
| Start | `omctl instance start $I` | ✅ ~5 min |
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
Scylla Manager backup to `gcs:<bucket>` (schema + SSTables of every member),
then records the snapshot tag on a `ScyllaSnapshot` object; Omnistrate stores
it as snapshot metadata:

```bash
omctl instance describe-snapshot $I <snap> -o json | jq '{status, snapshotMetadata}'
# → {"status":"COMPLETE","snapshotMetadata":{"snapshotTag":"sm_20260925084540UTC","location":"gcs:scylla-backup-…"}}
```

A restore always creates a **new** instance with the source's parameters: it
creates an empty cluster, the CQL superuser, then runs Manager restore
`--restore-schema` and `--restore-tables` for that tag. The data center is
always named `dc1`, so any snapshot restores into any instance.

### Add or remove members

`memberCount` is the number of members (nodes). Adding a member adds a node
and the member streams its share of data. Removing one decommissions the
highest-numbered member first (its data streams to the others). Keep
`memberCount` ≥ the largest replication factor of your keyspaces, or the
decommission fails.

### Change the machine type (scale up / down)

Changing `gcpInstanceType` makes Omnistrate add a node pool of the new type and
the operator roll the members onto it. A local SSD volume can't move between
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
- If a node disappears (VM failure), the operator's
  `automaticOrphanedNodeCleanup` replaces its member automatically.

Both need `memberCount` ≥ 2 and RF ≥ 2.

### Delete

```bash
omctl instance delete $I --yes     # deletes the ScyllaCluster, its Secrets/ConfigMaps and ops RBAC
```

Backups stay in the bucket. Deleting the **bucket** instance deletes every
backup in it (`force_destroy = true`, which also removes its service account).

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
- **Drivers behind the load balancer** must not follow the cluster topology
  (members' addresses are private).

## Parameters (`scylladb` resource)

"Fixed" parameters can't be changed after create.

| Key | Default | Notes |
|---|---|---|
| `adminPassword` | required | 12–128 chars of `A-Za-z0-9!@#%^&*()_+=.-`. Fixed |
| `adminUsername` | `admin` | CQL superuser. Fixed |
| `gcpInstanceType` | `n2-highmem-4` | n2 machine types, each with 2 local SSDs |
| `memberCount` | `3` | Members (1–30), one per node. Not called `replicaCount`: the platform overrides a parameter with that key during `start` |
| `cpuQuantity` / `memoryQuantity` | `3` / `24Gi` | Scylla container, requests = limits |
| `storageGiB` | `500` | Advisory local-NVMe request |
| `scyllaVersion` | `2026.2.5` | Changing it performs a rolling upgrade |
| `developerMode` | `false` | `true` relaxes production checks |
| `backupGcsBucketName` | none | gcs-bucket output `bucketName` |
| `backupGcsCredentials` | none | gcs-bucket output `credentialsBase64` (base64 service-account JSON key), mounted into each member's Manager agent |

The two backup parameters are hidden from end customers (`export: false`) but
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
| Plan build fails: `To enable GCP NVMe Local SSD feature, please contact support@omnistrate.com` | Step 0 |
| Spec validation: `additional properties 'ephemeralStorageLocalSsdConfig' not allowed` | The schema key is PascalCase: `EphemeralStorageLocalSsdConfig` (the docs show lowerCamel) |
| Data PVCs `Pending`: `storageclass "omnistrate-local-nvme" not found` | Cell predates local-NVMe support (step 5) |
| Backup fails with a GCS permission / credentials error | `backupGcsCredentials` must be the gcs-bucket `credentialsBase64` output verbatim (already base64) |
| Manager / operator pods `Pending` on GKE | Missing `components.gke.io/gke-managed-components` toleration |
| One PVC `Pending` for ~2 min: `local-nvme: array not mounted on this node yet` | Normal on a fresh node: the provisioner retries once the RAID is mounted |
| Create fails: `no matches for kind "ScyllaCluster"` / `"ScyllaSnapshot"` | Amenities missing on that cell (step 5). Apply them, delete the failed instance, create again |
| Workflow step `unsupported delete generic CRD flag` | Only `--ignore-not-found=true` is accepted on delete tasks |
| `conflicting operation is already in progress` right after a backup/restart/restore | Omnistrate finalizes those workflows ~10–15 min after their last step (steps show `success`, parent `RUNNING`). Wait; terminating one marks the instance `FAILED` (recover with any `modify`) |
| Extra NVMe nodes appear during create/scale | Operator cleanup Jobs inherit the rack placement; the spec's `matchLabelKeys` anti-affinity keeps them on the members' nodes — if you edit placement, keep it |
| auth Job fails `cannot log in` | Password with characters outside the regex, or the maintenance socket is disabled |
| Backup Job fails `cluster is not registered with Scylla Manager` | `scylla-manager` amenity missing or unhealthy (`kubectl -n scylla-manager get pods`) |
| `kubectl`: `You must be logged in to the server` | The kubeconfig token expired (~1 h). Run `update-kubeconfig` again |

Debug a workflow and its Jobs:

```bash
omctl workflow list -s <service-id> -e <environment-id> -i $I
omctl workflow events <workflow-id> -s <service-id> -e <environment-id> --detail
kubectl --kubeconfig ./cell.kubeconfig -n $I get jobs
kubectl --kubeconfig ./cell.kubeconfig -n $I logs job/<job> -c ops
```
