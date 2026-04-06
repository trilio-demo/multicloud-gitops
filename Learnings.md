# Learnings and Key Insights

## Trilio Status Writes Cause Perpetual ArgoCD OutOfSync

**Problem:** Trilio writes extensively to `.status` on its CRs (Target, TrilioVaultManager, etc.) after creation. ArgoCD detects these status fields as drift from the Helm chart (which defines no status), and reports the resource as `OutOfSync` indefinitely — even though the spec is correct and the resource is healthy.

**Why it's serious:** ArgoCD with automated sync will repeatedly attempt to reconcile the resource, and any human looking at the dashboard sees a permanently red app. This can mask real sync problems.

**Wrong fixes:**
- Manually editing `argocd-cm` — ArgoCD reconciles it back within minutes
- Patching the Application CR directly — the hub app-of-apps reconciles it back

**Correct fix:** Add the `ServerSideDiff` compare option annotation to the Trilio CR template in the Helm chart. This tells ArgoCD to use server-side diff, which only compares fields ArgoCD manages (via `managedFields`), ignoring everything Trilio writes post-creation:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/compare-options: "ServerSideDiff=true"
```

This is already applied to `backup-target.yaml`. Apply the same annotation to any other Trilio CR that shows persistent OutOfSync.

**Alternative (global):** Add a `resourceCustomizations` entry to the `ArgoCD` CR spec (not `argocd-cm`) for each Trilio CRD. But this is harder to manage in a VP GitOps context since the ArgoCD CR is also reconciled.

## OLM vs. Helm for Operator and Operand Management
- **OLM (Operator Lifecycle Manager)** is the OpenShift-recommended way to install and manage operators. It provides lifecycle, upgrade, and security management for operators.
- **Helm** is best used for deploying operands (the custom resources managed by operators) and other application resources, not for installing operators themselves on OpenShift.
- **Validated Patterns Best Practice:** Use OLM for operator installation and Helm for operand/application management. This approach aligns with both OpenShift and Validated Pattern methodologies, ensuring GitOps compliance and supportability.

## OLM Object Model: Subscription vs CSV vs Operator Pods

These three objects are often confused. They are distinct and deleting one does **not** cascade to the others:

```
Subscription  →  InstallPlan  →  CSV (ClusterServiceVersion)  →  Operator pods
   (watches)       (applies)       (owns)                          (runs)
```

| Object | What it is | Effect of deleting |
|--------|-----------|-------------------|
| **Subscription** | Tells OLM to watch a channel and keep the operator installed | Removes the watch only — operator keeps running |
| **InstallPlan** | One-time record of what was applied | Safe to ignore during teardown |
| **CSV** | The installed operator itself; owns the Deployments | Deleting this stops the operator pods |

**To fully remove an operator:** delete both the Subscription and the CSV. Deleting only the Subscription leaves the operator running indefinitely.

## Trilio CR Finalizers Must Be Removed Before Deleting the CSV

Trilio CRs (BackupPlan, Backup, Target, Restore, etc.) have **finalizers**. The operator processes these on deletion — running cleanup logic against S3, releasing locks — then removes the finalizer, allowing the object to be garbage collected.

**If you delete the CSV before clearing finalizers:** the operator pods die, nothing processes the finalizers, and all Trilio CRs get stuck in `Terminating` forever.

**Correct teardown order:**
1. Patch finalizers off all Trilio CRs (`--type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`)
2. Delete Subscription
3. Delete CSV → operator pods terminate cleanly

The actual backup data in S3 is unaffected — deleting Trilio CR objects on the cluster does not touch the S3 bucket contents.

## General Pattern Development
- All resources should be managed declaratively and stored in Git.
- ArgoCD is recommended for GitOps-driven continuous delivery.
- Use External Secrets Operator for secure secret and license management from Vault.
- Ansible is recommended for imperative actions and validation.

---

## Adding a DR Cluster to ACM (group-one Onboarding Flow)

This is the end-to-end chain of events that occurs when a new cluster is attached to ACM and labelled as `group-one`. No manual installation steps are required on the spoke after the label is applied.

### Pre-requisites (manual, on the new cluster before labelling)
1. ODF installed and a CSI StorageClass set as the cluster default (Trilio requires the CSI snapshot API)
2. Vault on the hub is already populated (`secret/global/trilio-license`, `secret/global/trilio-s3`) — this was done at hub bootstrap and persists for all future spokes

<!-- TODO: Replace the ASCII flow below with a Mermaid flowchart diagram.
     Mermaid renders natively on GitHub (```mermaid fenced block).
     Suggested diagram: flowchart TD covering the 10-step onboarding sequence,
     with a subgraph for the sync-wave split (trilio-secrets wave -1 →
     trilio-operand wave 0) and a red/dashed path for the Layer 0/1/2 failure
     modes that SkipDryRunOnMissingResource now handles.

     Annotate each step with observed elapsed times (validated 2026-03-13):
       label applied        → ACM PlacementRule match:        ~1 min
       ACM match            → ArgoCD bootstrap on spoke:      ~2-3 min
       ArgoCD bootstrap     → app-of-apps sync:               ~1-2 min
       app-of-apps sync     → OLM CSV Succeeded (Trilio):     ~3-5 min
       app-of-apps sync     → Vault Kubernetes auth ready:    ~5-10 min (async,
                              hub imperative framework registers spoke cluster;
                              ESO shows InvalidProviderConfig until this completes —
                              this is expected, not an error)
       Vault auth ready     → ESO SecretSynced (S3 creds):    up to 5 min (refresh interval)
       TVM applied          → child CRDs registered:          ~2-3 min
       Secrets present      → BackupTarget Available:         ~1-2 min
       Total cold-start:    ~15-25 min end-to-end with no manual intervention -->

### The Onboarding Sequence

```
1. Import cluster into ACM
   oc label managedcluster <name> clusterGroup=group-one
         │
         ▼
2. ACM PlacementRule matches the new cluster
   (PlacementRule was generated by the VP acm chart from managedClusterGroups in values-hub.yaml)
         │
         ▼
3. ACM Policy: GitOps bootstrap
   Installs OpenShift GitOps operator (ArgoCD) on the spoke via OLM Subscription
         │
         ▼
4. ACM Policy: ArgoCD configuration
   Configures the spoke ArgoCD with:
     - This Git repo URL + branch (dallas)
     - Instruction to use values-group-one.yaml as app-of-apps
         │
         ▼
5. Spoke ArgoCD syncs values-group-one.yaml — creates ArgoCD Applications:
     ├── golang-external-secrets  → installs ESO operator (Helm chart from VP framework)
     ├── trilio-operand           → deploys TVM CR, BackupTarget, ESO ExternalSecrets, License Job
     ├── wordpress-restore        → creates wordpress-restore NS, Hook CR, SA, RBAC
     ├── config-demo              → demo config app
     └── hello-world              → demo hello-world app

   ⚠️  KNOWN RACE CONDITION (Req 10): ArgoCD syncs trilio-operand immediately.
   The TrilioVaultManager and BackupTarget CRs require Trilio CRDs, but OLM
   is still installing the operator. First sync fails → app shows OutOfSync / Missing.
   See workaround below.
         │
         ▼
6. OLM Subscription (from values-group-one.yaml) installs Trilio operator
   Channel: 5.2.x  →  CSV k8s-triliovault-stable.5.2.0 reaches Succeeded
         │
         ▼
7. ESO ExternalSecrets sync from Vault (hub):
     - trilio-license  Secret  ← secret/global/trilio-license
     - aws-s3-login    Secret  ← secret/global/trilio-s3
         │
         ▼
8. trilio-license-job runs: reads trilio-license Secret → applies License CR
         │
         ▼
9. TrilioVaultManager CR reconciles → status: Deployed
   BackupTarget CR reaches Available (S3 reachable, credentials valid)
         │
         ▼
10. wordpress-restore namespace is live with:
      - wordpress-restore-hook Hook CR (URL pre-rendered for this cluster's ingress domain)
      - wordpress-sa ServiceAccount + anyuid RoleBinding
    → DR restore can be triggered immediately, no manual prep required
```

### Known Issue: trilio-operand Three-Layer Ordering Problem (Req 10)

`trilio-operand` will show `OutOfSync / Missing` after initial onboard. The root cause is a
**confirmed three-layer ordering failure** (validated 2026-03-13 by live cluster debugging):

**Layer 0 — ArgoCD sync plan validation aborts on unknown CRD (confirmed root cause)**

ArgoCD validates *all* resources in the sync plan before applying *any* of them. The `trilio-operand`
chart includes a `Target` CR (`targets.triliovault.trilio.io`). At first sync, this CRD does not
exist — only `triliovaultmanagers.triliovault.trilio.io` exists (installed by OLM CSV).
ArgoCD cannot build a valid sync task for an unknown resource type and aborts with:

```
Failed sync attempt ...: one or more synchronization tasks are not valid
```

Because the entire sync is aborted at the planning phase, **nothing** in the chart gets applied —
including the TrilioVaultManager CR itself. TVM never reconciles, so its child CRDs
(`targets`, `backupplans`, `backups`, `restores`, etc.) never get registered. ArgoCD retries and
hits the same wall every time. Retry count climbs indefinitely without self-recovery.

**Why only `triliovaultmanagers.triliovault.trilio.io` at CSV Succeeded:**
The OLM CSV installs the Trilio *operator* and registers the TVM CRD. The operator then
installs all other Trilio CRDs (Target, BackupPlan, Backup, Restore, Hook, Policy) only after a
TrilioVaultManager CR is applied and the operator reconciles it. This creates a mandatory
two-step sequence that ArgoCD's single-app, single-wave model cannot satisfy.

**Layer 1 — Trilio admission webhook rejects Target if credential Secret is missing**

Once TVM has been applied and its child CRDs registered, the next sync will attempt to apply the
`Target` CR. The Trilio admission webhook (`tvk-mutation.trilio.io`) validates that the
credential Secret (`aws-s3-login`) exists at apply time. If it doesn't, the webhook rejects the
apply and the sync fails.

**Layer 2 — ExternalSecret chicken-and-egg**

`aws-s3-login` is created by ESO from an ExternalSecret in the `trilio-operand` chart. If the
Target CR rejection causes the sync to fail early, the ExternalSecret may not get applied —
so ESO never creates the secret — so the webhook keeps rejecting.

### Step-by-Step Debugging Runbook

Run in order — each result tells you which layer is blocking.

```bash
# 1. Is the Trilio operator installed?
oc get csv -n trilio-system
# Expect: k8s-triliovault-stable.5.2.0   Succeeded
# If Pending/Installing: OLM still working — wait and retry

# 2. Is ESO reachable?
oc get clustersecretstore vault-backend
# Expect: READY=True   STATUS=Valid

# 3. Which Trilio CRDs exist? (KEY diagnostic for Layer 0)
oc get crd | grep trilio
# Layer 0 confirmed if only this row appears:
#   triliovaultmanagers.triliovault.trilio.io
# Healthy state would include: targets, backupplans, backups, restores, hooks, policies

# 4. Which ArgoCD resources are Missing vs Healthy?
ARGO_NS=$(oc get application -A --no-headers | head -1 | awk '{print $1}')
oc get application trilio-operand -n $ARGO_NS \
  -o jsonpath='{range .status.resources[*]}{.kind}{"\t"}{.name}{"\t"}{.status}{"\t"}{.health.status}{"\n"}{end}'
# Layer 0: TrilioVaultManager Missing AND Target Missing (ArgoCD aborted before applying anything)
# Layer 1: TrilioVaultManager present, Target Missing (webhook blocking)
# Layer 2: ExternalSecrets Missing (secrets never created)

# 5. What is the exact sync error?
oc get application trilio-operand -n $ARGO_NS \
  -o jsonpath='{.status.operationState.message}'
# Layer 0: "one or more synchronization tasks are not valid"
# Layer 1: message contains "tvk-mutation.trilio.io" and "aws-s3-login not found"

# 6. Retry count (confirms self-recovery is not happening)
oc get application trilio-operand -n $ARGO_NS \
  -o jsonpath='{.status.operationState.retryCount}'
# >3 and climbing = no self-recovery, proceed to workaround

# 7. Confirm secrets state
oc get secret trilio-license aws-s3-login -n trilio-system
oc get externalsecret -n trilio-system
```

**Decision table:**

| `oc get crd \| grep trilio` | ExternalSecrets | Secrets | Layer |
|-----------------------------|-----------------|---------|-------|
| Only `triliovaultmanagers` | Missing | Missing | **0 — apply TVM manually** |
| All CRDs present | Missing | Missing | **1+2 — apply ExternalSecrets manually** |
| All CRDs present | Present | Missing | **1 — ESO can't reach Vault** |
| All CRDs present | Present | Present | **Check TVM/Target status directly** |

### Workaround — Layer 0 (CRD gap, TVM never applied)

```bash
# Step 1: Apply TVM CR manually to bootstrap child CRDs
helm template trilio-operand charts/all/trilio-operand \
  --set global.localClusterName=dr-spoke \
  -s templates/triliovaultmanager.yaml \
  | oc apply -f -

# Step 2: Wait for TVM to reconcile and register child CRDs (~2-3 min)
watch oc get triliovaultmanager -n trilio-system
# Wait for status: Deployed

# Step 3: Confirm child CRDs now exist
oc get crd | grep trilio
# Should now show: targets, backupplans, backups, restores, hooks, policies

# Step 4: Force ArgoCD sync — plan validation will now succeed
oc patch application trilio-operand -n $ARGO_NS \
  --type merge -p '{"operation":{"sync":{}}}'
```

### Workaround — Layer 1/2 (webhook or ExternalSecret gap, TVM already applied)

```bash
# Apply ExternalSecrets manually to break the chicken-and-egg
helm template trilio-operand charts/all/trilio-operand \
  --set backupTarget.bucketName=sa-demo-2 \
  --set global.localClusterName=dr-spoke \
  -s templates/backup-target-secret.yaml \
  -s templates/trilio-license-external-secret.yaml \
  | oc apply -f -

# Wait for ESO to sync (30-60s), verify secrets exist
oc get secret trilio-license aws-s3-login -n trilio-system

# Force ArgoCD sync
oc patch application trilio-operand -n $ARGO_NS \
  --type merge -p '{"operation":{"sync":{}}}'
```

**Permanent fix (Req 10):** Split the chart into ordered ArgoCD Applications using sync-waves:
- `trilio-tvm` (wave -2): TrilioVaultManager CR only; ArgoCD waits for it to be Healthy before proceeding
- `trilio-secrets` (wave -1): ExternalSecrets only; ESO creates Secrets before Target is applied
- `trilio-operand` (wave 0): Target, BackupPlan, License Job

Add `syncOptions: ["SkipDryRunOnMissingResource=true"]` to handle any residual CRD timing gaps.
See Req 10 in PRD.md for implementation plan.

---

### Spoke Reset: Full Teardown for Re-Onboarding

Use this runbook to cleanly remove the VP stack from a group-one spoke so you can re-add it to
ACM and observe the full onboarding sequence from scratch. (Validated 2026-03-13 on dr-cluster.)

#### ACM delivery mechanisms (critical to understand before teardown)

ACM uses **two distinct mechanisms** to configure spoke clusters. Resources applied by each
survive teardown differently:

| Resource | Applied by | Survives app-of-apps deletion? | Removed by |
|----------|-----------|-------------------------------|------------|
| OpenShift GitOps operator Subscription | ACM ConfigurationPolicy | **Yes** | Delete Subscription explicitly |
| Trilio operator Subscription | ACM ConfigurationPolicy | **Yes** | Delete Subscription explicitly |
| ESO operator Subscription | ACM ConfigurationPolicy | **Yes** | Delete Subscription explicitly |
| app-of-apps Application in `openshift-gitops` | ACM GitOpsCluster | — | Delete Application + remove ACM label |
| All `applications:` in values-group-one.yaml | ArgoCD (via app-of-apps) | No | Cascade delete from app-of-apps |

**Key insight:** OLM Subscriptions (including Trilio) are applied directly by ACM's work agent
as `ConfigurationPolicy` objects — they do not go through ArgoCD. This is why the Trilio
operator Subscription survived deleting the ArgoCD apps and required explicit cleanup.
Removing the `clusterGroup` label stops ACM from *enforcing* its policies but does not
delete what was already installed.

#### ArgoCD topology on the spoke (critical to understand before teardown)

Two ArgoCD instances exist on the spoke after onboarding:

```
openshift-gitops (namespace)
  └── Application: dallas-multicloudops-group-one   ← app-of-apps, created by ACM
        │  watches Git repo, renders values-group-one.yaml, generates child apps
        │  ⚠ NO automated sync — ACM owns this Application and does not set
        │    syncPolicy: automated. Goes OutOfSync on Git changes but does NOT
        │    self-heal. Requires a manual sync trigger to re-render child apps.
        ▼
dallas-multicloudops-group-one (namespace — separate ArgoCD instance)
  ├── config-demo              ← automated sync (from values-group-one.yaml)
  ├── golang-external-secrets  ← automated sync
  ├── hello-world              ← automated sync
  ├── trilio-operand           ← automated sync
  └── wordpress-restore        ← automated sync
```

ACM creates the app-of-apps in `openshift-gitops`. Once deployed, the app-of-apps is
**self-sufficient** — it regenerates children continuously regardless of the ACM label.
Deleting child apps without first removing the app-of-apps causes them to immediately reappear.

#### Step 1 — Hub: remove the ACM cluster label

```bash
# On hub cluster context — must be done FIRST
oc label managedcluster dr-cluster clusterGroup-
# Trailing dash removes the label. Stops ACM from re-pushing policies.
```

#### Step 2 — Spoke: delete the app-of-apps (stops child app regeneration)

```bash
# On spoke context
oc delete application dallas-multicloudops-group-one -n openshift-gitops
```

ArgoCD's cascade-delete finalizer (`resources-finalizer.argocd.argoproj.io`) will attempt to
delete all child apps automatically. Monitor progress:

```bash
watch oc get application -n dallas-multicloudops-group-one
```

If the app-of-apps or any child app is stuck in Terminating (common with Trilio finalizers),
force-remove the finalizer:

```bash
# Force-complete app-of-apps deletion if stuck
oc patch application dallas-multicloudops-group-one -n openshift-gitops \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'

# Force-complete any stuck child apps
oc patch application trilio-operand -n dallas-multicloudops-group-one \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
oc patch application wordpress-restore -n dallas-multicloudops-group-one \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
oc patch application hello-world -n dallas-multicloudops-group-one \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'

# Then delete any remaining child apps
oc delete application --all -n dallas-multicloudops-group-one --ignore-not-found
```

#### Step 3 — Spoke: delete Trilio and wordpress-restore namespaces

```bash
# If TVM has a finalizer blocking namespace deletion:
oc patch triliovaultmanager triliovault-manager -n trilio-system \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

oc delete namespace trilio-system --wait=false
oc delete namespace wordpress-restore --wait=false
```

#### Step 4 — Spoke: remove OLM Subscription and CSV

> Use `subscription.operators.coreos.com` — not `subscriptions.apps.open-cluster-management.io`
> (that is ACM's channel subscription, unrelated to OLM).

```bash
oc delete subscription.operators.coreos.com k8s-triliovault \
  -n openshift-operators --ignore-not-found
oc delete csv k8s-triliovault-stable.5.2.0 \
  -n openshift-operators --ignore-not-found
```

#### Step 5 — Spoke: delete Trilio CRDs (required for clean re-onboard)

Trilio CRDs survive namespace deletion and must be explicitly removed so OLM re-registers them
fresh on the next install.

```bash
oc get crd | grep trilio | awk '{print $1}' | xargs oc delete crd --ignore-not-found
```

#### Step 6 — (Optional) Remove ESO if testing full stack

Keeping ESO saves ~5 minutes on re-onboard. Skip unless you need to test ESO installation.

```bash
oc delete subscription.operators.coreos.com golang-external-secrets \
  -n openshift-operators --ignore-not-found
```

#### Step 6b — (Optional) Full teardown: remove ArgoCD operator itself

The OpenShift GitOps operator (ArgoCD) was installed by ACM ConfigurationPolicy, not by
ArgoCD, so it survives app-of-apps deletion. For a truly clean cluster state:

```bash
# Remove the ArgoCD operator
oc delete subscription.operators.coreos.com openshift-gitops-operator \
  -n openshift-operators --ignore-not-found

# Remove the ArgoCD namespace (contains the openshift-gitops instance)
oc delete namespace openshift-gitops --wait=false

# Remove the group-one ArgoCD namespace
oc delete namespace dallas-multicloudops-group-one --wait=false
```

> Only do this if you want to test ACM re-installing ArgoCD from scratch. For most re-onboard
> tests, leaving ArgoCD in place is fine — ACM will re-create the app-of-apps in the existing
> `openshift-gitops` instance when the label is re-applied.

#### Step 7 — Hub: re-add the cluster label to trigger fresh onboarding

```bash
# On hub cluster context
oc label managedcluster dr-cluster clusterGroup=group-one
```

ACM immediately re-pushes the app-of-apps to `openshift-gitops` on the spoke. The spoke ArgoCD
then generates all child apps and the onboarding sequence begins.

Monitor:
```bash
# On spoke context
watch oc get application -n dallas-multicloudops-group-one
watch oc get csv -n trilio-system
```

**What to observe during re-onboarding:**
1. `dallas-multicloudops-group-one` app-of-apps appears in `openshift-gitops`
2. Child apps appear in `dallas-multicloudops-group-one` namespace
3. `oc get csv -n trilio-system` transitions: `Pending → Installing → Succeeded`
4. `trilio-operand` shows `OutOfSync / Missing` (Layer 0 — expected, CRDs not yet registered)
5. After workaround: TVM applied → child CRDs registered → ArgoCD sync succeeds
6. `oc get triliovaultmanager -n trilio-system` → `Deployed`
7. `oc get target trilio-s3-target -n trilio-system` → `Available`

### Why the App-of-Apps Goes OutOfSync After a Git Push

When you push a change to `values-group-one.yaml` (e.g. adding a new imperative job), the child
apps in `dallas-multicloudops-group-one` do **not** automatically pick up the change. Here's why:

The app-of-apps (`dallas-multicloudops-group-one` in `openshift-gitops`) is created and managed
by ACM's GitOpsCluster mechanism. ACM places it on the spoke but does **not** configure
`syncPolicy: automated` on it. So it detects the Git drift and shows `OutOfSync`, but waits for
a manual trigger rather than self-healing.

The child apps *do* have `syncPolicy: automated`, but they only get updated resource templates
when the app-of-apps re-renders `values-group-one.yaml` and regenerates them. Until the
app-of-apps syncs, the child apps are reconciling against the **old** templates.

**The fix:**
```bash
oc patch application dallas-multicloudops-group-one -n openshift-gitops \
  --type merge -p '{"operation":{"sync":{}}}'
```

After this, the app-of-apps re-renders `values-group-one.yaml`, the child apps receive updated
templates, and their automated sync applies the changes within seconds.

**When this matters:** Any time you add/change an imperative job, add a new application, or
modify sync settings in `values-group-one.yaml`. Changes to chart content inside
`charts/all/trilio-operand/` are picked up by the child `trilio-operand` app directly (automated
sync) and do not require the app-of-apps trigger.

---

### Talking Points
- **One label, full stack.** The only action needed on the spoke after ODF is `oc label managedcluster`. ACM and ArgoCD do the rest — operator, operand, secrets, restore prerequisites.
- **Vault is the secret distribution mechanism across clusters.** ESO on the spoke reaches back to Vault on the hub. No secrets are replicated manually or stored in Git.
- **The spoke ArgoCD is autonomous.** Once configured by ACM, it reconciles against Git continuously — if a pod crashes or a resource is deleted, it self-heals without hub involvement.
- **Adding a third cluster** is identical: import, label, done.

---

## Architecture: How the Components Fit Together

The pattern is built on a layered delivery model, where each layer has a distinct responsibility:

```
Git (source of truth)
  └── ArgoCD (continuous delivery engine)
        ├── OLM Subscription → installs Trilio operator (cluster-level lifecycle)
        ├── Helm chart (trilio-operand)
        │     ├── TrilioVaultManager CR  → configures Trilio services
        │     ├── ExternalSecret CR      → pulls license from Vault into a Secret
        │     ├── ServiceAccount/Role/RoleBinding  → RBAC for the License Job
        │     └── Job (trilio-license-job) → reads Secret, creates License CR
        └── Helm chart (golang-external-secrets) → ESO itself
```

**Talking points:**
- **Git is the only source of truth.** Nothing is configured manually on the cluster; every resource has a corresponding file in the repository that ArgoCD reconciles continuously.
- **Separation of concerns:** The operator (installed via OLM) provides the controller and CRDs. The operand (deployed via Helm) provides the configuration telling the controller what to do. These are deployed independently so upgrades to either don't couple to the other.
- **The hub-spoke topology** allows ACM to propagate the Trilio OLM Subscription to every managed spoke cluster from a single place, so adding a new cluster automatically gets Trilio installed.
- **Secret zero problem:** The only secret not managed declaratively is the initial Vault token in `values-secret.yaml` (which is never committed). Everything downstream — including the Trilio license — flows through ESO from Vault, so no secrets live in Git.

## Ansible: Imperative Glue for Declarative Systems

**The core insight:** Kubernetes is excellent at declaring *desired state*, but it has no native way to express *workflows* — sequences like "wait for X, then do Y, then verify Z". Ansible fills this gap.

In this pattern, Ansible is used for two distinct purposes:

### 1. Validation (read-only assertions)
`validate-trilio.yaml` checks that the declarative resources ArgoCD deployed have actually reached healthy runtime state:
- The CSV (ClusterServiceVersion) reached `Succeeded` — meaning the operator binary is running
- The TrilioVaultManager CR reached `Deployed` — meaning the operand is configured and serving
- The License CR exists — meaning Trilio accepted the key and is activated
- All pods in `trilio-system` are `Running` or `Succeeded`

**Status:** Validated against a real cluster (2026-03-03). Key findings:
- Ansible `vars` block self-referential defaults (e.g. `foo: "{{ foo | default('x') }}"`) cause infinite recursion — use literal defaults instead
- TrilioVaultManager uses `status.status: Deployed` (not `Ready`) as its healthy state

**Talking point:** ArgoCD can tell you that a resource *was applied*. Ansible tells you the resource *is working*. These are different things — a Deployment can be synced but have all pods crash-looping. Validation playbooks close that gap.

### 2. Workflow orchestration (stateful sequences)
`dr-backup.yaml` and `dr-restore.yaml` drive multi-step DR operations:

**Status:** Not yet tested against a real cluster.

```
dr-backup.yaml
  1. Pre-flight: is Trilio healthy? (fail fast)
  2. Verify the Target CR is Available (storage is reachable)
  3. Create BackupPlan CR  (defines what to protect)
  4. Poll until BackupPlan is Available
  5. Create Backup CR      (triggers the actual backup run)
  6. Poll until Backup is Available (success) or Failed
  7. Assert and report outcome

dr-restore.yaml
  1. Pre-flight: is Trilio healthy? (fail fast)
  2. Verify source Backup is Available (data exists)
  3. Create Restore CR      (instructs Trilio to recreate namespace state)
  4. Poll until Restore is Completed or Failed
  5. (Optional) Poll until all pods in namespace are Running
  6. Assert and report outcome
```

**Talking point:** Ansible doesn't perform the backup or restore — Trilio does. Ansible's role is to *drive the Kubernetes API* (create CRs, poll `.status` fields, assert outcomes). The `kubernetes.core.k8s` and `kubernetes.core.k8s_info` modules are used throughout — these are effectively `kubectl apply` and `kubectl get` wrapped in Python, with retry/until logic built in. This makes the playbooks readable, auditable, and easy to integrate into CI pipelines or runbooks.

### Why not use a Kubernetes Job for DR workflows?
A Job can run a script that calls `kubectl`, but it lacks:
- Human-readable pass/fail output suitable for runbooks and presentations
- Easy parameterization (you'd need ConfigMaps or env vars for every variable)
- Ansible's built-in retry, until, and assert primitives
- Integration with CI/CD systems that consume JUnit/structured output

Ansible gives you all of these while remaining infrastructure-agnostic.

## Validated Patterns Utility Container

All pattern tooling runs inside `quay.io/validatedpatterns/utility-container`, invoked by `pattern.sh`. It includes `oc`, `helm`, `ansible`, `kubernetes.core` collection, `git`, `make`, `python3`, `jq`, and `yq` — no local toolchain required.

**Key point:** You do not need a custom container image. If additional Ansible collections are needed, add `ansible/requirements.yml` and the framework installs them automatically at runtime.

This is what makes the pattern portable across developer laptops, CI/CD pipelines, and RHPDS demo clusters without any environment-specific setup.

## License Management: The ESO-to-CR Workaround

Helm cannot create a Kubernetes CR whose value depends on a Secret that is itself created by another Helm resource (ESO ExternalSecret) in the same release, because Helm renders all templates at once — there is no runtime dependency ordering.

**Solution:** A one-time Kubernetes `Job` bridges the gap:
1. ESO creates the `trilio-license` Secret from Vault (declarative, async)
2. The Job waits (`until kubectl get secret ...`) for that Secret to exist
3. The Job reads the license key from the Secret and applies the `License` CR

**Talking point:** This is an accepted pattern for "declarative systems with runtime dependencies". The Job runs once, is idempotent (uses `kubectl apply`), and is RBAC-scoped to only the resources it needs (`get` secrets, `create/patch` License CRs). Once the License CR exists, the Job's work is done — Trilio's operator reconciles the CR and activates the license.

---

## Pre-Requisite: `make install` Must Be Run Before ArgoCD Sync

### The Dependency Chain

This pattern has secrets that must exist in Vault before ArgoCD deploys the dependent resources:

| Secret in Vault | Consumed By | Consequence If Missing at Sync Time |
|----------------|-------------|--------------------------------------|
| `secret/global/trilio-license` | ESO ExternalSecret → `trilio-license` Secret → License Job | License CR never created; Trilio operates unlicensed |
| `secret/global/trilio-s3` | ESO ExternalSecret → `aws-s3-login` Secret → BackupTarget CR | Target stays in `Failed` state; no backups possible |

### Why `make install` Solves This

The VP framework's `make install` (invoked via `pattern.sh`) runs the Vault bootstrap Ansible role **before** ArgoCD begins reconciling applications. It reads `values-secret.yaml` (the operator-populated, never-committed file) and writes all secrets to Vault. By the time ArgoCD syncs the `trilio-operand` application, Vault is already populated and ESO can immediately create the required Secrets.

**This is the standard VP deployment contract:** populate `values-secret.yaml`, then run `make install`. Skipping either step breaks the ESO → Secret → dependent resource chain.

### Recovery If Vault Is Populated Late

If Vault is populated *after* ArgoCD has already synced:
- **ESO** will re-sync within 5 minutes (refreshInterval on S3 ExternalSecret) and create the missing Secret
- **Trilio Target CR** will automatically re-reconcile once `aws-s3-login` exists (Trilio watches Secrets) and transition from `Failed` to `Available`
- **License Job** is a one-shot Job — if it ran before the Secret existed, re-trigger it by deleting the completed/failed Job pod; the Job controller will recreate it

No manual CR patching is needed in any case — just populate Vault and wait.

### Forcing Immediate ESO Re-Sync (Without Waiting for refreshInterval)

After populating Vault, annotate the ExternalSecret to trigger an immediate reconcile:

```bash
oc annotate externalsecret trilio-s3-credentials \
  -n trilio-system \
  force-sync=$(date +%s) --overwrite
```

The `date +%s` (Unix timestamp) ensures the annotation value always changes, which ESO detects as a mutation and immediately triggers a sync. Watch the result:

```bash
oc get externalsecret trilio-s3-credentials -n trilio-system -w
```

The `READY` column will flip from `False` to `True` within seconds. Once the `aws-s3-login` Secret exists, Trilio automatically re-reconciles the Target CR from `Failed` to `Available` — no further action needed.

This same technique works for any ExternalSecret in the pattern (e.g., `trilio-license`).

---

## Extracting the Vault Root Token from the Pattern Secret

The VP framework stores Vault init data (including the root token) in a Secret named `vaultkeys` in the `imperative` namespace. The secret has a single key `vault_data_json` containing a base64-encoded JSON blob — not a flat key like `root_token`.

**Correct extraction command:**

```bash
VAULT_TOKEN=$(oc get secret vaultkeys -n imperative \
  -o jsonpath='{.data.vault_data_json}' | \
  base64 -d | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
echo $VAULT_TOKEN
```

**Why not `jsonpath='{.data.root_token}'`?** That path doesn't exist. The entire JSON payload is nested inside a single base64 field, so you must decode the field first, then parse the JSON.

---

## Updating Vault Secrets via `oc exec` (No Local Vault CLI Required)

Once you have the root token (see above), write plain text secrets directly into Vault using `oc exec` against the `vault-0` pod:

```bash
oc exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_TOKEN \
  vault kv put secret/global/trilio-s3 \
    accessKey="AKIAXXXXXXXXXXXXXXXX" \
    secretKey="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

**Plain text only — do not base64-encode the values.** ESO reads raw Vault values and handles the Kubernetes Secret base64 encoding itself. If you store base64-encoded values (e.g. keys ending in `==`), ESO double-encodes them and Trilio receives garbled credentials, causing the Target CR to stay in `Failed` state.

After updating Vault, force an immediate ESO re-sync (see "Forcing Immediate ESO Re-Sync" above) rather than waiting the full 5 minutes.

---

## ArgoCD Uses `helm template`, Not `helm install` — Impact on Trilio App Discovery

ArgoCD's default behavior is to render Helm charts using `helm template` and apply the resulting YAML via `kubectl apply`. It does **not** run `helm install`, so no Helm release Secret (`sh.helm.release.v1.*`) is ever created in the namespace.

Trilio's Helm application discovery works by scanning for these release Secrets. Because ArgoCD never creates them, ArgoCD-managed apps will not appear as "Helm applications" in the Trilio UI — even if they were deployed from a Helm chart.

**This does not affect backup protection.** The `BackupPlan` with `backupPlanComponents: {}` protects the entire namespace regardless of how the resources were deployed. Trilio backs up PVCs, Deployments, Services, and all other resources directly — the "Helm app" grouping in the Trilio UI is only a discovery convenience, not a protection requirement.

**Talking point:** This is a natural consequence of GitOps — ArgoCD owns the desired state, not Helm. The Helm chart is just a templating mechanism; the resulting Kubernetes objects are what matter, and Trilio protects those directly.

---

## ArgoCD: Sync Status vs. Last Sync Result

These are two independent indicators that are frequently confused:

| Field | What it measures | Example values |
|-------|-----------------|----------------|
| **Sync Status** | Is the live cluster state currently **equal to** what the chart renders from Git? | `Synced`, `OutOfSync` |
| **Last Sync Result** | Did the most recent **sync operation** (apply) complete without error? | `Sync OK`, `Sync Failed` |

**They can disagree — and that's meaningful:**

- `OutOfSync` + `Sync OK` (what we saw): ArgoCD successfully applied the chart the last time it ran, but the live cluster has since **drifted** from the desired state. Common causes: a manual `oc patch`, an operator mutating a field, or a new commit that rendered a different value (our case — `tvkInstanceName` was empty in the last-applied annotation, but the cluster had `tvk-instance` from a prior manual patch).

- `Synced` + `Sync Failed`: The apply operation errored (e.g. RBAC denied, CRD missing), but a previous successful sync left the cluster in a state that still matches an older desired state.

**Talking point:** "Sync OK" only means the last *operation* worked — it says nothing about whether the cluster matches Git *right now*. Always check **Sync Status** to know the true reconciliation state. In a GitOps system, `OutOfSync` is the signal that something has deviated from source of truth, regardless of when the last apply ran.

**In this pattern:** The `tvkInstanceName` OutOfSync was caused by `global.clusterName` (undefined in the VP framework) rendering as an empty string in the last-applied annotation, while a prior manual `oc patch` had set the live value to `tvk-instance`. ArgoCD's sync policy is to apply the desired state — it does not silently ignore live mutations. The fix (using `global.localClusterName`) produced a non-empty desired value that ArgoCD could authoritatively apply, resolving the drift.

---

## TrilioVaultManager Healthy States: `Deployed` and `Updated`

TVM has two terminal healthy states:

| Status | Meaning |
|--------|---------|
| `Deployed` | Initial deployment completed successfully |
| `Updated` | A spec change was applied and reconciled successfully |

Both indicate the operator is running and Trilio is fully functional. `Updated` appears after any spec change (e.g. `tvkInstanceName` change) and persists until the next spec change — it does not revert to `Deployed`.

**Impact:** Validation playbooks that only check for `Deployed` will loop indefinitely on a healthy but recently-updated TVM. Both `_validate_trilio_ready.yaml` and `validate-trilio.yaml` accept either state using `in ['Deployed', 'Updated']`.

---

## Trilio Restore CR: Spec Structure and Gotchas

### Correct field locations (validated 2026-03-06)

| Field | Location | Notes |
|-------|----------|-------|
| `skipIfAlreadyExists` | `spec.restoreFlags.skipIfAlreadyExists` | NOT at `spec` level — unknown field warning if placed there |
| `restoreNamespace` | Not a valid field | Restore namespace is determined by `metadata.namespace` |
| `actionFlags` | `spec.actionFlags: {}` | Required as empty map; omit causes validation warning |
| `hookConfig` | `spec.hookConfig` | Same structure as BackupPlan hookConfig |
| `transformComponents` | `spec.transformComponents` | Inline Route hostname rewrite — no separate Transform CR needed |

### Location-based restore source spec (validated 2026-03-10)

The `source` block for `type: Location` is flat (not nested under `location:`):
```yaml
source:
  type: Location
  location: "<backupplan-uid>/<backup-uid>"   # status.location from Backup CR
  target:
    apiVersion: triliovault.trilio.io/v1
    kind: Target
    name: trilio-s3-target
    namespace: trilio-system                  # MUST be trilio-system — NOT restore_namespace
```

**Critical:** The Target namespace in the location source spec must be `trilio-system` (where the Target CR actually lives), not the restore namespace. Trilio's admission webhook (`tvk-mutation.trilio.io`) validates the Target exists at the specified namespace at CR creation time — if you specify the restore namespace, the webhook returns HTTP 400: `targets.triliovault.trilio.io "trilio-s3-target" not found`.

The `status.location` path from a Backup CR = `<backupplan-uid>/<backup-uid>`. Retrieve with:
```bash
kubectl get backup <name> -n <ns> -o jsonpath='{.status.location}'
```

**End-to-end validation (2026-03-10):** Location method restore completed successfully with manual `backup_location_path`. Route transform applied correctly, post-restore MySQL Hook ran and updated `wp_options` siteurl/home, all pods Running.

### Route hostname construction

Auto-discover the ingress domain from the restore cluster (no manual input):
```bash
oc get ingresses.config cluster -o jsonpath='{.spec.domain}'
# → apps.ocp-dc6.demo.presales.trilio.io   (already includes "apps.")
```
Route hostname = `{{ restore_namespace }}.{{ ingress_domain }}` (NOT `.apps.` — it's already in the domain).

### Restore Hook pre-condition

The restore Hook CR (`wordpress-restore-hook`) must **already exist** in the restore namespace before the Restore CR is created. Trilio does not create it — it only references it by name in `hookConfig`. The playbook detects its presence and includes `hookConfig` conditionally; if absent, restore proceeds without it (demo-safe with a warning).

### Kubernetes resource collision: `restore` kind

`kubectl explain restore.spec` returns ACM's `Restore` CRD by default. Always qualify:
```bash
kubectl explain restore.spec --api-version=triliovault.trilio.io/v1
```

---

## Hub Rebuild While Spoke Remains Active

When the hub cluster is torn down and rebuilt (e.g. to test a full pattern reinstall), a spoke
cluster that was previously onboarded (`clusterGroup=group-one`) continues to operate normally.

### What survives on the spoke

| Resource | Fate during hub rebuild | Notes |
|----------|------------------------|-------|
| Trilio operator (OLM) | **Survives** — installed locally via OLM | OLM is self-managed on the spoke |
| TrilioVaultManager CR | **Survives** | Deployed by spoke ArgoCD |
| BackupTarget CR | **Survives** — stays `Available` | No hub dependency at runtime |
| Kubernetes Secrets (`aws-s3-login`, `trilio-license`) | **Survive** | Already in etcd; ESO can't refresh but they're still there |
| Spoke ArgoCD apps | **Survive and keep syncing** | Spoke ArgoCD has its own Git repo URL/branch; hub outage is irrelevant |
| ESO ClusterSecretStore | Goes `InvalidProviderConfig` | Vault on hub is gone; ESO can't authenticate |

### ESO behaviour during hub outage

ESO will fail to refresh secrets on its next refresh cycle (5m for S3, 1h for license). The
existing Secrets remain in the cluster — Trilio uses them from etcd, not by calling ESO directly.
No Trilio disruption occurs unless the Secrets are explicitly deleted.

### Re-importing the spoke after hub rebuild

```
Hub make install completes (Vault rebuilt, ACM rebuilt)
      │
      ▼
Vault Kubernetes auth backends start empty
      │
      ▼
oc label managedcluster <spoke-name> clusterGroup=group-one
      │
      ▼
ACM policies reconcile (idempotent):
  - GitOps bootstrap: ArgoCD already exists on spoke → no-op
  - ArgoCD configuration: repo URL/branch already set → no-op
  - Spoke ArgoCD apps: already Synced → no drift detected
      │
      ▼
Hub imperative framework registers spoke with Vault (~5-10 min)
      │
      ▼
ESO vault-backend: InvalidProviderConfig → Valid (self-heals)
ESO refreshes Secrets (no disruption — existing values are the same)
      │
      ▼
Full steady state restored — no manual steps on the spoke required
```

### Key insight

The spoke is **self-sufficient** once bootstrapped. Hub connectivity is only required for:
- Initial Vault secret sync (bootstrap)
- Periodic ESO secret refresh (operational)

Hub downtime does not affect Trilio backup/restore operations already running on the spoke.
*Update this file as new insights are discovered or existing patterns are refined.*

---

## Imperative Framework: How Jobs Become CronJobs

### Overview

The Validated Patterns (VP) *imperative framework* provides a structured way to run scheduled
Ansible playbooks on a cluster managed by ArgoCD. It bridges the gap between declarative GitOps
(ArgoCD applies desired state) and imperative workflows (Ansible drives Kubernetes API sequences
that have ordering and timing requirements).

Everything is triggered by entries in `imperative.jobs` inside `values-hub.yaml`. That YAML
block ends up as a **Kubernetes CronJob** running on a schedule. This section explains how the
pieces connect end to end.

---

### Data-Flow Diagram

The diagram below traces the path from a Git commit to a running Ansible playbook.

```mermaid
flowchart TD
    A[Developer commits\nvalues-hub.yaml\nimperative.jobs] --> B[ArgoCD syncs\nhub cluster]
    B --> C[VP framework\ngenerates ArgoCD\nApplication:\nimperative-setup]
    C --> D[Kubernetes CronJob\nimperative-cronjob-HASH\nschedule: every 10 min]

    D --> E[CronJob fires\ncreates a Pod]

    subgraph pod [Pod: imperative-cronjob-HASH-XXXXX]
        direction TB
        IC0[init-container 0\nfetch-ca\npull cluster CA cert]
        IC1[init-container 1\ngit-init\nclone Git repo into\nshared emptyDir volume]
        IC2[init-container 2\nhello-world\nplaybook: rhvp.cluster_utils.hello_world]
        IC3[init-container 3\ntrilio-enable-cr\nplaybook: imperative-enable-cr.yaml]
        IC4[init-container 4\ntrilio-backup\nplaybook: imperative-backup.yaml]
        IC5[init-container 5\ntrilio-restore-standard\nplaybook: imperative-restore-standard.yaml]
        IC6[init-container 6\ntrilio-e2e-status\nplaybook: imperative-e2e-status.yaml]
        IC7[container: done\nlong-running pause\nkeeps pod alive for log inspection]

        IC0 --> IC1 --> IC2 --> IC3 --> IC4 --> IC5 --> IC6 --> IC7
    end

    E --> pod

    IC3 -- "skip: CR BackupPlan\nalready Available" --> IC4
    IC4 -- "skip: Available\nbackup already exists" --> IC5
    IC5 -- "skip: Completed\nrestore already exists" --> IC6
    IC6 -- "fail: phases not\nyet all PASS" --> FAIL[Pod shows\nInit:Error\nVP logs alert]
    IC6 -- "all phases PASS" --> IC7

    IC6 --> CM[ConfigMap\ntrilio-dr-status\nin imperative ns]
```

**Key rules:**
- Init containers run **sequentially**. If one exits non-zero, the pod enters `Init:Error` and all subsequent init containers never run.
- The `trilio-e2e-status` job is **intentionally last** and **intentionally fails** until all DR phases are complete. Once all phases pass, the job exits 0 and the pod completes successfully. The framework stops retrying until something changes.
- Every playbook is **idempotent**. If work is already done, the playbook calls `meta: end_play` and exits 0 — it does not re-run the operation. This means the jobs can fire every 10 minutes without side effects.

---

### Phase-by-Phase Breakdown

| Init Container | Playbook | Skip Condition | What It Does |
|---|---|---|---|
| `trilio-enable-cr` | `imperative-enable-cr.yaml` | CR BackupPlan already `Available` | Discovers group-one DR clusters from ACM; matches to Target `availableContinuousRestoreInstances`; creates ContinuousRestore Policy + CR BackupPlan |
| `trilio-backup` | `imperative-backup.yaml` | `Available` Backup already exists | Creates a Backup CR from `wordpress-backup-plan`; waits for it to reach `Available` |
| `trilio-restore-standard` | `imperative-restore-standard.yaml` | `Completed` Restore already exists in `wordpress-restore` | Restores latest Available backup to `wordpress-restore` with Route hostname transform |
| `trilio-e2e-status` | `imperative-e2e-status.yaml` | None (always runs) | Checks all four phases; writes `trilio-dr-status` ConfigMap; **fails job** until all phases pass |

---

### RBAC: Why imperative-sa Needs a ClusterRole

The VP framework creates a `ServiceAccount` named `imperative-sa` in the `imperative` namespace.
All Ansible playbooks run as this service account inside the CronJob pod.

By default, `imperative-sa` has no permissions beyond reading its own namespace. Any Kubernetes
API call that touches Trilio CRs (BackupPlan, Backup, Restore, Policy, Target, etc.) will return
`403 Forbidden` unless explicit RBAC is granted.

**What was granted** (in `charts/all/trilio-operand/templates/imperative-sa-rbac.yaml`):

| Resource | Verbs | Reason |
|---|---|---|
| Trilio CRs (BackupPlan, Backup, Restore, Hook, Policy, Target, TVM) | get/list/watch/create/patch/update | Create and monitor DR objects |
| ConsistentSet (cluster-scoped) | get/list/watch | Read-only; CR pipeline status |
| OLM ClusterServiceVersions | get/list | Trilio health check (CSV phase) |
| ACM ManagedClusters | get/list | Discover group-one DR clusters |
| OpenShift Ingress config | get/list | Auto-discover route hostname for restore |
| ConfigMaps | get/list/create/patch/update | Write `trilio-dr-status` status summary |

A **ClusterRole** is used (rather than a namespaced Role) because the permissions span multiple
namespaces (`wordpress`, `wordpress-restore`, `trilio-system`) and include cluster-scoped
resources (ManagedCluster, Ingress config, ConsistentSet).

**To add permissions for a new playbook**, edit the `imperative-trilio-operator` ClusterRole
in that file and commit. ArgoCD will apply the updated RBAC on the next sync.

#### The Trilio Webhook Secret Clone

When any ServiceAccount submits a Restore CR, the Trilio admission webhook
(`tvk-mutation.trilio.io`) does more than validate the request — it **clones the Target's
credential Secret into the restore namespace** so that the restore job can reach S3 storage
from that namespace.

This means the SA creating the Restore CR must have `secrets: create/patch/update` across
**all restore target namespaces**, not just `trilio-system` where the original Secret lives.

**Why it's hard to diagnose:** the webhook returns HTTP `400 Bad Request` with the error buried
inside the message body:

```
admission webhook "tvk-mutation.trilio.io" denied the request:
  error creating clone: error creating Target object:
    admission webhook "tvk-mutation.trilio.io" denied the request:
      error creating clone: error creating Secret object:
        secrets is forbidden: User "system:serviceaccount:imperative:imperative-sa"
        cannot create resource "secrets" in API group "" in the namespace "wordpress-restore"
```

A `400` from a webhook is not what you expect for an RBAC failure — you'd normally look for a
`403 Forbidden`. The nested structure (webhook calling webhook) also obscures the actual cause.

**The fix:** add `secrets` to the ClusterRole covering all namespaces. Since the Target's
credential Secret could be cloned to any restore namespace, a ClusterRole (rather than
namespace-scoped Roles) is the right scope.

---

### Monitoring the Imperative Framework

#### Find the latest CronJob pod

```bash
# List all imperative pods, newest first
oc get pods -n imperative --sort-by=.metadata.creationTimestamp | grep imperative-cronjob

# Or get just the latest one
oc get pods -n imperative -l job-name --sort-by=.metadata.creationTimestamp \
  --no-headers | tail -1
```

#### Check which init container failed

```bash
POD=<pod-name-from-above>

# See all init container statuses at a glance
oc get pod $POD -n imperative \
  -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{"\t"}{.state}{"\n"}{end}'

# Get logs from a specific init container
oc logs $POD -n imperative -c trilio-e2e-status
oc logs $POD -n imperative -c trilio-restore-standard
```

#### Read the E2E status ConfigMap

```bash
oc get configmap trilio-dr-status -n imperative -o yaml
```

Example output when all phases pass:
```yaml
data:
  overall: PASS
  phase1_backup: "PASS — wordpress-backup-20260331-10h00"
  phase2_restore_standard: "PASS — imperative-restore-20260331-10h05"
  phase3a_cr_backupplan: "PASS — Available"
  phase3b_cr_backup: "PASS — wordpress-backup-cr-20260331-10h10"
```

#### Verify RBAC is in place

```bash
oc get clusterrole imperative-trilio-operator
oc get clusterrolebinding imperative-trilio-operator

# Test a specific permission (replace verb/resource as needed)
oc auth can-i create restores.triliovault.trilio.io \
  --as=system:serviceaccount:imperative:imperative-sa \
  --all-namespaces
```

---

### Talking Points

- **No operator needed.** The imperative framework uses standard Kubernetes primitives — CronJob, init containers, ServiceAccount — not a custom operator. This makes it auditable, debuggable with standard `oc` commands, and easy to extend.
- **The job order is significant.** `trilio-e2e-status` must be last. If it is placed before any other phase, its intentional `fail` will prevent later phases from running.
- **Idempotency is built in, not bolted on.** Each playbook checks for completion before doing any work. Re-running the framework 100 times does not create 100 backups — it creates one, then skips on every subsequent run.
- **The ConfigMap is the status API.** External monitoring tools, dashboards, or CI pipelines can read `trilio-dr-status` in the `imperative` namespace to check DR health without parsing pod logs.
- **RBAC lives in the trilio-operand chart.** This means the ClusterRole is applied to every cluster that has the trilio-operand ArgoCD Application — currently the hub only. If a spoke ever runs imperative jobs, the chart already covers it.

---

## Req 13 — Full Pattern Teardown Runbook

Use this runbook to completely remove the Trilio GitOps Validated Pattern from both clusters.
The order matters: **spoke first, then hub**. If you tear down the hub first, ACM loses the
ability to clean up spoke-side resources it placed there.

**Goal of this runbook:** leave both clusters in a state where `make install` + `make onboard-spoke`
returns them to full operation from scratch. ODF on the spoke is intentionally preserved.

---

### Inventory (validated 2026-04-04)

**Hub (ocp-dc6):**
```
ArgoCD app-of-apps:  openshift-gitops/dallas-multicloudops-hub
Child apps (ns dallas-multicloudops-hub): acm, vault, golang-external-secrets,
  trilio-secrets, trilio-operand, wordpress, wordpress-restore, config-demo, hello-world
ACM ManagedClusters: local-cluster, dr-cluster
OLM Subscriptions (ACM-placed, survive ArgoCD): patterns-operator, k8s-triliovault
Namespaces owned by pattern: vault, trilio-system, wordpress, wordpress-restore,
  imperative, golang-external-secrets, config-demo, hello-world, dallas-multicloudops-hub
```

**Spoke (ocp-dc12 / dr-cluster):**
```
ArgoCD app-of-apps:  openshift-gitops/dallas-multicloudops-group-one
Child apps (ns dallas-multicloudops-group-one): trilio-operand, trilio-secrets,
  golang-external-secrets, wordpress-restore, config-demo, hello-world
OLM Subscriptions (ACM-placed, survive ArgoCD): openshift-gitops-operator, k8s-triliovault
Namespaces owned by pattern: trilio-system, wordpress-restore, imperative,
  golang-external-secrets, config-demo, hello-world, dallas-multicloudops-group-one
Do NOT remove: openshift-storage (ODF — pre-req, not pattern-owned)
```

---

### Phase 1 — Spoke Teardown (context: ocp-dc12)

#### Step 1 — Remove the ACM cluster label to stop re-provisioning

Before deleting anything, remove the label that causes ACM to re-push the stack.
Without this, ACM will re-create resources as fast as you delete them.

```bash
# On hub context
oc label managedcluster dr-cluster clusterGroup-
# The trailing '-' removes the label (standard kubectl/oc syntax)
```

#### Step 2 — Delete the app-of-apps (cascade-deletes all child apps and their resources)

```bash
# On spoke context
oc delete applications.argoproj.io dallas-multicloudops-group-one \
  -n openshift-gitops --wait
# ArgoCD cascade-deletes all child apps and the resources they manage
# (trilio-operand, trilio-secrets, wordpress-restore, etc.)
```

#### Step 3 — Remove Trilio finalizers if namespace deletion stalls

Trilio CRs carry finalizers that can block namespace deletion if the operator
is removed before the CRs are cleaned up.

```bash
oc patch triliovaultmanager triliovault-manager -n trilio-system \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

oc delete namespace trilio-system --wait=false
oc delete namespace wordpress-restore --wait=false
```

#### Step 4 — Remove ACM-placed OLM Subscriptions

These were placed by ACM's ConfigurationPolicy and survive ArgoCD deletion.

```bash
oc delete subscription.operators.coreos.com k8s-triliovault \
  -n trilio-system --ignore-not-found
oc delete csv k8s-triliovault-stable.5.2.0 \
  -n openshift-operators --ignore-not-found
```

#### Step 5 — Remove Trilio CRDs (required for clean re-install)

CRDs survive namespace deletion. Remove them so OLM re-registers fresh on next install.

```bash
oc get crd | grep trilio | awk '{print $1}' | xargs oc delete crd --ignore-not-found
```

#### Step 6 — (Optional) Remove ESO

Skip this to save ~5 min on re-install. ESO is stateless — leaving it causes no issues.

```bash
oc delete subscription.operators.coreos.com golang-external-secrets \
  -n openshift-operators --ignore-not-found
oc delete namespace golang-external-secrets --ignore-not-found
```

#### Step 7 — (Optional) Remove OpenShift GitOps operator

Only needed if you want to test ACM re-installing ArgoCD from scratch.

```bash
oc delete subscription.operators.coreos.com openshift-gitops-operator \
  -n openshift-operators --ignore-not-found
oc delete namespace openshift-gitops --wait=false
oc delete namespace dallas-multicloudops-group-one --wait=false
```

**Verify spoke is clean:**
```bash
oc get applications.argoproj.io -A       # should be empty
oc get namespace | grep -E "trilio|wordpress-restore|imperative"  # should be gone
oc get crd | grep trilio                 # should be empty
```

---

### Phase 2 — Hub Teardown (context: ocp-dc6)

#### Step 1 — Delete the hub app-of-apps

```bash
oc delete applications.argoproj.io dallas-multicloudops-hub \
  -n openshift-gitops --wait
# Cascade-deletes all hub child apps and their managed resources:
# acm chart, vault, ESO, trilio-operand, wordpress, wordpress-restore, etc.
```

#### Step 2 — Remove Trilio finalizers and namespaces

```bash
oc patch triliovaultmanager triliovault-manager -n trilio-system \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

oc delete namespace trilio-system --wait=false
oc delete namespace wordpress --wait=false
oc delete namespace wordpress-restore --wait=false
oc delete namespace vault --wait=false
oc delete namespace imperative --wait=false
```

#### Step 3 — Remove ACM-placed OLM Subscriptions

```bash
oc delete subscription.operators.coreos.com k8s-triliovault \
  -n trilio-system --ignore-not-found
oc delete csv k8s-triliovault-stable.5.2.0 \
  -n openshift-operators --ignore-not-found
```

#### Step 4 — Remove Trilio CRDs

```bash
oc get crd | grep trilio | awk '{print $1}' | xargs oc delete crd --ignore-not-found
```

#### Step 5 — Remove ACM cluster registration for dr-cluster

```bash
oc delete managedcluster dr-cluster --ignore-not-found
# This also removes the ACM namespace for the cluster
```

#### Step 6 — Remove the Patterns Operator

The VP framework operator (patterns-operator) was installed by `make install`. Remove it last
so it doesn't interfere with ArgoCD cleanup above.

```bash
oc delete subscription.operators.coreos.com patterns-operator \
  -n openshift-operators --ignore-not-found
oc get csv -n openshift-operators | grep patterns | awk '{print $1}' \
  | xargs oc delete csv -n openshift-operators --ignore-not-found
```

**Verify hub is clean:**
```bash
oc get applications.argoproj.io -A
oc get namespace | grep -E "trilio|wordpress|vault|imperative|dallas-multi"
oc get crd | grep trilio
oc get managedcluster
```

---

### Re-install from scratch

Once both clusters are clean:

```bash
# 1. On hub — re-bootstrap
make install   # loads secrets + deploys full hub stack

# 2. Wait for hub ArgoCD apps to reach Synced/Healthy (~10-15 min)
make dr-status

# 3. Onboard spoke
make onboard-spoke CLUSTER=dr-cluster
```

---

### Key Teardown Insights

- **Label removal first.** Always remove `clusterGroup=group-one` from the spoke ManagedCluster
  before deleting anything. ACM's controller reconciles continuously — it will re-create
  ConfigurationPolicy-placed resources within seconds if the label is still present.
- **ArgoCD cascade delete is your friend.** Deleting the app-of-apps with `--wait` removes
  all child apps and their managed Kubernetes resources in one operation. You do not need to
  delete child apps individually.
- **OLM Subscriptions are the exception.** Anything installed via ACM ConfigurationPolicy
  (Trilio subscription, GitOps operator subscription) is not owned by ArgoCD and survives
  app-of-apps deletion. These require explicit `oc delete subscription` commands.
- **Finalizers block namespace deletion.** Trilio CRs have finalizers. If the operator is
  removed before the CRs are garbage-collected, namespaces hang in `Terminating`. Patch the
  TrilioVaultManager finalizer explicitly before deleting the namespace.
- **ODF is never touched.** The `openshift-storage` namespace and all ODF resources on the
  spoke are pre-existing infrastructure. No teardown step touches them.

---

## Trilio 5.3.x Upgrade Learnings

Validated 2026-04-05. Both hub and spoke upgraded from 5.2.0 to 5.3.x. These notes cover every
issue encountered; use them as a runbook for future upgrades or when troubleshooting 5.3.x.

---

### 1. License Key Backslashes Break 5.3.x

**Symptom:** TrilioVaultManager stays `Failed`; TVK UI shows "Unable to decode license key".

**Root cause:** The license key string stored in Vault contained backslash characters (common
when copying from a license email or PDF). Trilio 5.2.x read the license via a shell variable
assignment that implicitly stripped backslashes; 5.3.x reads raw Secret bytes directly — the
backslashes are passed to the decoder and it fails.

**Fix:** Strip backslashes before writing to Vault:

```bash
# Write license key with backslashes stripped
LICENSE_RAW='<paste raw key here>'
LICENSE_CLEAN=$(echo "$LICENSE_RAW" | tr -d '\\')

VAULT_TOKEN=$(oc get secret vaultkeys -n imperative \
  -o jsonpath='{.data.vault_data_json}' | \
  base64 -d | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

oc exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN \
  vault kv put secret/global/trilio-license trilioLicense="$LICENSE_CLEAN"
```

**Verify** the stored value contains no backslashes:

```bash
oc exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN \
  vault kv get -field=trilioLicense secret/global/trilio-license | cat -A
# No backslashes should appear in output
```

---

### 2. ESO ExternalSecret Template Section Corrupts Backslashes

**Symptom:** Even after fixing Vault, the `trilioLicense` Secret in-cluster still contains
backslashes — or worse, double-escaped sequences.

**Root cause:** The ExternalSecret had a `template:` section that piped values through Go
template processing. Go templates perform their own escape interpretation on string data,
re-introducing backslashes that were already absent from Vault.

**Fix:** Remove the `template:` section entirely from the ExternalSecret. Use the `data:`
section only — ESO copies Vault property values verbatim with no template processing:

```yaml
# charts/all/trilio-secrets/templates/trilio-license-external-secret.yaml
spec:
  data:
    - secretKey: key            # for 5.2.x License Job
      remoteRef:
        key: secret/global/trilio-license
        property: trilioLicense
    - secretKey: trilioLicense  # for 5.3.x native secretRef
      remoteRef:
        key: secret/global/trilio-license
        property: trilioLicense
```

Both keys map to the same Vault property. The 5.2.x License Job reads `data.key`; the 5.3.x
TrilioVaultManager reads `data.trilioLicense` via `spec.licenseRef.secretRef`. This dual-key
approach allows the same chart to work on either Trilio version without a code branch.

---

### 3. S3 Bucket Region: 5.3.x Does Not Follow PermanentRedirect (301)

**Symptom:** BackupTarget stays `Failed`; Trilio logs show an S3 error similar to
`PermanentRedirect: The bucket you are attempting to access must be addressed using the
specified endpoint`.

**Root cause:** The S3 bucket `sa-demo-2` was migrated from `us-east-1` to `ca-central-1`.
Trilio 5.2.x silently followed the S3 301 PermanentRedirect response and reached the bucket
successfully. Trilio 5.3.x does **not** follow 301 redirects — it treats the redirect as an
error and marks the Target `Failed`.

**Fix:** Set the correct region explicitly in all values files:

```yaml
# values-hub.yaml and values-group-one.yaml — under trilio-operand helmOverrides
- name: backupTarget.region
  value: ca-central-1
```

Also update the default in `charts/all/trilio-operand/values.yaml`:

```yaml
backupTarget:
  region: ca-central-1
```

**Key lesson:** Never rely on S3 redirect following in Trilio 5.3.x. Always set `region` to
match the actual bucket location.

---

### 4. T4K Version Mismatch Blocks Continuous Restore

**Symptom:** TVK UI shows "Mismatching T4K versions" on the Continuous Restore (CR) screen.
The spoke appears in the hub's target but is rejected as a CR destination.

**Root cause:** Continuous Restore requires identical Trilio versions on all participating
clusters. A hub on 5.2.x and a spoke on 5.3.x are incompatible at the CR protocol level.

**Fix:** Upgrade both clusters to the same version before enabling CR. In this pattern, hub
uses `installPlanApproval: Manual` for the OLM Subscription — approve the InstallPlan on the
hub to advance it to 5.3.x:

```bash
# On hub — find and approve the pending InstallPlan
PLAN=$(oc get installplan -n trilio-system -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}')
oc patch installplan $PLAN -n trilio-system --type merge -p '{"spec":{"approved":true}}'
```

Wait for TVM to report `Deployed` or `Updated`, then re-validate CR pairing in the TVK UI.

Note: As of this upgrade, the hub Subscription was also changed to `installPlanApproval: Manual`
(consistent with the spoke) so future upgrades are always deliberate and require explicit approval.

---

### 5. License CR Auto-Migration During 5.2.x → 5.3.x Upgrade

**Symptom (non-issue):** After the hub OLM upgrade completes, the existing License CR still
shows `spec.key` (5.2.x format) in Git, but the cluster-side CR is in `spec.secretRef` format.

**Explanation:** The 5.3.x TrilioVaultManager controller automatically migrates an existing
`spec.key` License CR to `spec.secretRef` format on first reconciliation. No manual deletion or
re-creation is required. The License Job workaround remains in place; the License CR is now
managed by TVM and uses the native 5.3.x format.

You do not need to delete and re-create the License CR when upgrading from 5.2.x to 5.3.x.

---

### 6. Stale CR BackupPlan instanceID After Spoke Reinstall

**Symptom:** After offboarding and re-onboarding a spoke, the hub's Continuous Restore
BackupPlan (`wordpress-backup-plan-cr`) fails to create ConsistentSets. TVK UI may show the
old spoke instance as unavailable.

**Root cause:** The CR BackupPlan references the spoke TVM's instanceID. After reinstall, the
spoke gets a new instanceID. The old instanceID is stale.

**Verify the current available instances on the target:**

```bash
oc get target trilio-s3-target -n trilio-system \
  -o jsonpath='{.status.availableContinuousRestoreInstances}' | python3 -m json.tool
```

The spoke self-registers in `status.availableContinuousRestoreInstances` on the hub's Target
after a successful onboarding (typically within 5–10 minutes of the TVM reaching `Deployed`).

**Fix:** Use the TVK UI to edit the CR BackupPlan and select the newly registered spoke
instance. There is no `oc patch` shortcut — the instanceID is embedded in the BackupPlan spec
and the TVK UI is the supported way to update it.

---

### 7. Stale ConfigMap Key Survives `kubernetes.core.k8s state: present`

**Symptom:** The `trilio-dr-status` ConfigMap on the hub contains a key that no longer exists
in any playbook (e.g., `phase3b_consistent_set` renamed to `phase3b_cr_backup`).

**Root cause:** `kubernetes.core.k8s` with `state: present` performs a strategic merge — it
adds or updates keys but never removes keys that are no longer in the provided data. Renamed
keys accumulate as dead entries.

**Fix:** Remove the stale key with a JSON patch:

```bash
oc patch configmap trilio-dr-status -n imperative \
  --type=json \
  -p '[{"op":"remove","path":"/data/phase3b_consistent_set"}]'
```

**Prevention:** When renaming a ConfigMap key in a playbook, add an explicit task to remove
the old key, or delete and re-create the ConfigMap in the playbook rather than relying on
strategic merge.

---

### 8. installPlanApproval: Manual on Hub Subscription

During the 5.3.x upgrade, the hub OLM Subscription was updated to use
`installPlanApproval: Manual` (previously `Automatic`). This is now consistent with the spoke.

**Rationale:** `Automatic` approval means any new Trilio version published to the channel is
installed immediately without review — this caused the inadvertent 5.2.x → 5.3.x upgrade on
the spoke before the hub was ready, triggering the T4K version mismatch. With `Manual` on both
clusters, upgrades are gated: approve the spoke InstallPlan first, validate, then approve the
hub InstallPlan.

**Approve an InstallPlan:**

```bash
# List pending plans
oc get installplan -n trilio-system

# Approve
PLAN=<install-plan-name>
oc patch installplan $PLAN -n trilio-system --type merge -p '{"spec":{"approved":true}}'
```
