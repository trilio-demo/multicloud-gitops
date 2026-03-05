# Learnings and Key Insights

## OLM vs. Helm for Operator and Operand Management
- **OLM (Operator Lifecycle Manager)** is the OpenShift-recommended way to install and manage operators. It provides lifecycle, upgrade, and security management for operators.
- **Helm** is best used for deploying operands (the custom resources managed by operators) and other application resources, not for installing operators themselves on OpenShift.
- **Validated Patterns Best Practice:** Use OLM for operator installation and Helm for operand/application management. This approach aligns with both OpenShift and Validated Pattern methodologies, ensuring GitOps compliance and supportability.

## General Pattern Development
- All resources should be managed declaratively and stored in Git.
- ArgoCD is recommended for GitOps-driven continuous delivery.
- Use External Secrets Operator for secure secret and license management from Vault.
- Ansible is recommended for imperative actions and validation.

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
*Update this file as new insights are discovered or existing patterns are refined.*
