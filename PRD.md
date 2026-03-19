# Title
Red Hat Validated Pattern: Disaster Recovery with Trilio

# Product Requirements Document (PRD)

## Overview
This document defines the requirements for a new Red Hat Validated Pattern focused on Disaster Recovery (DR) using Trilio. The pattern must adhere to the best practices and standards established by the Red Hat Validated Patterns framework, ensuring repeatability, security, and operational excellence for OpenShift-based DR solutions.

The pattern must work against any reachable OpenShift cluster, including RHPDS demo clusters, OpenMetal, and customer environments — with no environment-specific manual steps.

---

## Objectives
- Deliver a fully automated, GitOps-driven DR solution for OpenShift clusters using Trilio.
- Ensure the pattern is modular, reusable, and aligns with the Validated Patterns methodology.
- Provide clear documentation, automation, and integration with common tools (ArgoCD, Helm, Ansible).
- Enable rapid deployment, testing, and validation of DR capabilities in enterprise environments.
- Support Annual DR Test scenarios triggered by a defined operational event, not just manual runbook execution.
- Demonstrate accelerated RTO via Trilio's EventTarget / Continuous Restore capability (pre-staged PVCs on the DR cluster).

---

## Pre-Requisites

The following must be satisfied on **every cluster** (hub and spokes) before deploying this pattern. The `validate-trilio.yaml` playbook checks these conditions and fails fast with a clear message if any are not met.

| Pre-Requisite | Detail |
|---------------|--------|
| OpenShift 4.x | Any supported OCP 4.x release |
| CSI StorageClass (default) | A CSI-backed StorageClass must exist and be marked as the cluster default. Trilio uses the CSI snapshot API to protect PVCs — non-CSI storage (in-tree drivers, `kubernetes.io/no-provisioner`) is not supported. **ODF (`ocs-storagecluster-ceph-rbd`) is the recommended choice on OpenShift** but any CSI driver is acceptable (AWS EBS CSI, Azure Disk CSI, vSphere CSI, etc.). |
| S3-compatible object storage | Required for the BackupTarget CR. Store credentials in Vault at `secret/global/trilio-s3` with properties `accessKey` and `secretKey`. Any S3-compatible endpoint works (AWS S3, ODF NooBaa MCG, MinIO, etc.). Set `bucketName` and `region` in `values-hub.yaml` via `helmOverrides` on the `trilio-operand` application. |
| `values-secret.yaml` populated before `make install` | The VP bootstrap process writes secrets to Vault **before** ArgoCD syncs. If Vault is not populated before sync, the Trilio license Job and BackupTarget will fail until secrets are available. See `values-secret.yaml.template` for required entries and `Learnings.md` for recovery steps. |
| Unique OCP cluster name (recommended) | Each cluster's infrastructure name (from `oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}'`) is used as the Trilio `tvkInstanceName`. Unique names are not strictly required by Trilio, but duplicate names make the TVK multi-cluster UI harder to navigate. vSphere and cloud-provisioned clusters generate unique infrastructure names automatically. |

> **ODF Note:** ODF must be installed and configured **before** running `pattern.sh make install`. The VP does not install ODF — it has hardware requirements (minimum 3 nodes with attached block devices) that vary by environment. On RHPDS clusters, ODF is typically pre-installed. On OpenMetal or bare-metal OCP, install ODF separately via the ODF operator and create a `StorageSystem`/`StorageCluster` before deploying this pattern.

> **Optional — OpenShift Virtualization (OCP Virt):** Required only if VM-based workload protection is needed (Req 8). OCP Virt is **not required** for the core container DR workflow. When present, Trilio can protect VirtualMachine resources alongside PVC-backed applications using the same BackupPlan model. OCP Virt must be installed and a default VM StorageClass configured before any VM-targeted BackupPlan is created. If OCP Virt is not installed, Req 8 is not applicable and no other functionality is affected.

### Restore Pre-Requisites

The following must be known or provisioned before running the `dr-restore.yaml` playbook. These are in addition to the cluster-level pre-requisites above.

| Pre-Requisite | Detail |
|---------------|--------|
| Cluster ingress domain | **Auto-discovered** by the restore playbook from the DR cluster (`config.openshift.io/v1 Ingress/cluster`). Used to construct the Route hostname as `{{ restore_namespace }}.{{ ingress_domain }}` (e.g. `wordpress-restore.apps.ocp-dc6.demo.presales.trilio.io`). No manual input required — the playbook queries the cluster it is currently authenticated to. Override with `-e cluster_domain=<value>` only if auto-discovery is unavailable. |
| `restore_namespace` pre-created | The target namespace must exist before the restore starts. Trilio does not create it. Automated via Req 6c (GitOps); until then, create manually: `oc new-project wordpress-restore` |
| `wordpress-restore-hook` Hook CR | Must be pre-deployed in `restore_namespace` for MySQL URL rewrite to run post-restore (Req 6b). If absent, the playbook warns and proceeds without it. Automated via Req 6c (GitOps); until then, apply manually from `ansible/playbooks/` or the `charts/all/wordpress-restore/` chart. |
| Shared BackupTarget reachable | The DR cluster's BackupTarget CR must point to the same S3 bucket as the source cluster and be in `Available` state. |

---

## Requirements

### General
- Must follow the [Red Hat Validated Patterns best practices](https://github.com/validatedpatterns/multicloud-gitops#best-practices).
- All automation, configuration, and documentation must be delivered as code in Git.
- Pattern must be compatible with OpenShift 4.x and support multi-cluster topologies.
- All resources must be managed declaratively (GitOps-first approach).
- Must be portable across RHPDS, OpenMetal, and any OCP cluster without environment-specific customization.

### Disaster Recovery Specific
- Deploy and configure Trilio operator and operands (e.g., TrilioVaultManager) using Helm charts.
- Automate Trilio license management via integration with Vault and External Secrets Operator.
- Provide sample DR policies, backup/restore workflows, and validation playbooks.
- Support both hub-and-spoke and standalone OpenShift topologies.
- Include monitoring and alerting integration for DR events.

### Tooling

- **Operator Lifecycle Manager (OLM)**: Use OLM (via Subscription/OperatorGroup YAML or ACM policies) to install and manage operators, following OpenShift best practices.
- **Helm**: Use Helm charts to manage operands (the custom resources managed by operators) and other application resources. Do not use Helm to install operators directly on OpenShift; instead, leverage OLM for operator lifecycle management.
- **ArgoCD**: For continuous delivery and GitOps management of all resources.
- **Ansible**: For imperative actions, validation, and integration tasks.
- **External Secrets Operator**: For secure license and secret management from Vault.

### Documentation
- Must include a comprehensive README with architecture diagrams, deployment steps, and troubleshooting.
- Provide links to upstream Trilio documentation and Red Hat Validated Patterns resources.
- Include example values files for different topologies (hub, spoke, standalone).

---

## End-to-End DR Workflow Requirements

These are the functional requirements that define the complete scope of the pattern.
Each item maps to a deliverable in the Implementation Matrix below.

| # | Requirement | Priority |
|---|-------------|----------|
| 1 | Deploy Trilio via Validated Pattern (OLM + Helm) | P0 — Done |
| 2 | Deploy a sample stateful application via Helm (WordPress + MySQL) | P0 — Done |
| 3 | Define a BackupTarget CR on all clusters (shared S3 or NFS storage) | P0 — Done |
| 4 | Define a BackupPlan CR scoped to the sample app namespace, with quiesce/unquiesce hooks | P0 — Done |
| 5 | Execute a Backup of the sample app via Ansible playbook | P0 — Done |
| 6 | Restore from Backup via Ansible playbook (backup method) | P1 — Done |
| 6 | Restore from BackupTarget location browse (location method) | P1 — Done |
| 6a | Route hostname transform inline in Restore CR via transformComponents | P1 — Done |
| 6b | Post-restore MySQL Hook CR (wordpress-restore-hook) for wp_options URL rewrite | P1 — Partial (manual deploy works; GitOps automation pending via 6c) |
| 6c | DR restore namespace (wordpress-restore) + Hook CR pre-provisioned via GitOps on all clusters | P1 — Done |
| 7 | Continuous Restore via EventTarget: pre-stage PVCs on DR cluster from ConsistentBackupPlan for accelerated RTO | P1 — Done |
| 7a | Hook CR support for ConsistentSet restores: post-restore URL rewrite via hookConfig (currently applied via direct database exec) | P2 — Not Started |
| 8 | (Optional) Deploy a VM-based application (OpenShift Virtualization) | P2 — Deferred |
| 9 | Upgrade to Trilio 5.3.x: adopt native license-via-Secret model; remove License Job workaround | P1 — In Progress (manifests in hand) |
| 10 | Spoke onboarding: resolve OLM/ArgoCD race condition so trilio-operand self-heals without manual sync | P1 — Done |
| 11 | Pattern documentation (`Document.md`) for publication on validatedpatterns.io — comprehensive usage manual for pattern adopters | P1 — Not Started |
| 12 | Imperative Framework Automation: full E2E DR lifecycle driven by VP imperative jobs — backup on hub ready, enable Continuous Restore when DR cluster joins, restore + validate when ConsistentSet present, alert on success/failure | P0 — Not Started |
| 13 | VP Uninstall: validate Pattern CR deletion teardown; document finalizer cleanup; confirm ODF is preserved; verify spoke disassociation from ACM | P2 — Not Started |
| 14 | Remove multicloud-gitops upstream overhead (hello-world, config-demo, RHDP-specific workflows where appropriate); retain or comment items with future value; document every decision | P1 — Not Started |
| 15 | Publish clean pattern to new public GitHub repo `trilio-continuous-restore`: update all metadata, RHDP workflow references, pattern name throughout; disconnect from multicloud-gitops lineage while preserving VP framework compatibility | P1 — Not Started |

---

## Detailed Requirement Notes

### Req 2 — Sample App (WordPress + MySQL) ✓ DONE
Custom Helm chart at `charts/all/wordpress/` built from owner's existing manifests. Preserves `app: wordpress` / `tier: mysql` / `tier: frontend` labels (required for Trilio hook selectors). Replaces manual `oc adm policy add-scc-to-user anyuid` with a declarative ServiceAccount + RoleBinding. NodePort replaced with ClusterIP + OpenShift Route. Deployed to `wordpress` namespace on hub (primary) cluster via ArgoCD. Validated 2026-03-04.

### Req 3 — BackupTarget CR (All Clusters) ✓ DONE
`trilio-s3-target` Target CR deployed in `trilio-system` on hub cluster via `charts/all/trilio-operand`. S3 credentials (`accessKey`/`secretKey`) stored in Vault at `secret/global/trilio-s3` as plain text; ESO ExternalSecret `trilio-s3-credentials` syncs them into `aws-s3-login` Secret within 5 minutes. BackupTarget reached `Available` state after correct credentials were stored. EventTarget annotation (`trilio.io/event-target: "true"`) set on all clusters. Bucket: `sa-demo-2`, region: `us-east-1`. Validated 2026-03-04.

> **Note:** Credentials must be plain text in Vault — base64-encoded values cause double-encoding by ESO and result in a `Failed` Target state. See Learnings.md for the correct `oc exec` extraction and write commands.

### Req 4 — BackupPlan with Quiesce/Unquiesce Hooks ✓ DONE
`wordpress-backup-plan` BackupPlan CR deployed via `charts/all/wordpress/templates/backup-plan.yaml`. Protects entire `wordpress` namespace (`backupPlanComponents: {}`). References `trilio-s3-target` in `trilio-system`. MySQL quiesce/unquiesce Hook CR (`wordpress-mysql-hook`) deployed via `charts/all/wordpress/templates/backup-hook.yaml` in the `wordpress` namespace — hook runs `FLUSH TABLES WITH READ LOCK` before snapshot and `FLUSH LOGS; UNLOCK TABLES` after. Hook applied to pods matching `wordpress-mysql*` selector. BackupPlan and Hook deployed via ArgoCD; manual backup confirmed successful. Validated 2026-03-05.

### Req 5 — Backup Execution ✓ DONE
`dr-backup.yaml` Ansible playbook validated end-to-end against a real cluster. Playbook reworked from original to use the existing ArgoCD-managed `wordpress-backup-plan` rather than creating a new BackupPlan. Key changes: removed BackupPlan creation step; added BackupPlan existence/health check; default `backup_name` auto-generated from timestamp via `lookup('pipe', 'date +%Y%m%d-%Hh%M')`; added `backup_type` parameter (Full/Incremental). TVM healthy-state check updated to accept both `Deployed` and `Updated`. Validated 2026-03-05.

### Req 6 — Cross-Cluster Restore (Standard Path)
The restore playbook (`dr-restore.yaml`) must be parameterized for a target cluster kubeconfig/context. The target cluster must have Trilio installed (via this pattern) and a BackupTarget CR pointing to the same storage as the source. In this path, Trilio fetches both metadata and data from the BackupTarget — RTO is bounded by data transfer time. The trigger for restore should be a defined operational event (e.g., an `ansible-navigator run` invoked from a CI/CD pipeline, ACM policy, or documented runbook command).

### Req 6a — Post-Restore Route Transform
The Restore CR's `transformComponents` field rewrites resource fields during restore. The Route hostname must be patched inline (no separate Transform CR needed) so the WordPress app is immediately accessible at the DR cluster URL after restore. The restore playbook derives the hostname as `{{ restore_namespace }}.apps.{{ cluster_domain }}` when `cluster_domain` is provided. Validated 2026-03-06 via manual UI restore.

### Req 6b — Post-Restore MySQL Hook (WordPress URL Rewrite)
A Trilio `Hook` CR (`wordpress-restore-hook`) must be pre-deployed in the restore namespace before the restore starts. The post-restore hook updates the MySQL `wp_options` table (`siteurl` and `home`) to the DR cluster URL, ensuring WordPress internal links resolve correctly after failover. This Hook CR is separate from the backup quiesce/unquiesce hook and must be deployed to every DR restore namespace (via ArgoCD or manual apply). The restore playbook detects the Hook CR automatically — if absent, restore proceeds without it (demo mode) with a warning.

**Status (2026-03-06):** Validated — hook executes correctly post-restore when manually pre-deployed to the restore namespace. GitOps automation of the Hook CR deployment (Req 6c) is pending.

### Req 6c — DR Restore Namespace Pre-Provisioning (All Clusters)
The WordPress restore namespace (`wordpress-restore`) and its prerequisites must be provisioned automatically by the Validated Pattern on all clusters — not created manually before a DR event. This must be managed declaratively via ArgoCD so it exists and is ready before any restore is triggered.

The namespace provisioning must include:
- The `wordpress-restore` Namespace itself
- The `wordpress-restore-hook` Hook CR (Req 6b) deployed into that namespace
- Any required RBAC (ServiceAccount, RoleBinding for `anyuid` SCC) so restored pods can run

**Implementation:** `charts/all/wordpress-restore/` Helm chart wired into both `values-hub.yaml` and `values-group-one.yaml`. Deploys the namespace, `wordpress-sa` ServiceAccount, `anyuid` SCC RoleBinding, and `wordpress-restore-hook` Hook CR on all clusters. Hook URL rendered at deploy time from `global.localClusterDomain` — no manual configuration required.

### Req 7 — Continuous Restore via EventTarget (Accelerated RTO Path)

**This is the architectural differentiator of the pattern.**

#### How It Works
1. The `BackupTarget` CR on the **DR cluster** is flagged as an EventTarget.
2. This flag causes Trilio to create an **EventTarget pod** in the `trilio-system` namespace on the DR cluster.
3. The EventTarget pod periodically monitors the shared BackupTarget storage for new backups.
4. When a new backup is detected, the EventTarget pod **pre-stages PVCs** on the DR cluster — the actual volume data is copied locally, ahead of any restore request.
5. The number of pre-staged restore points is controlled by the `consistentSets` count on the BackupTarget.
6. When a DR event triggers a restore, Trilio only needs to **fetch metadata** from the BackupTarget (not the full dataset) — the PVC data is already local.
7. Result: dramatically reduced RTO compared to the standard restore path (Req 6).

#### Implementation Requirements
- BackupTarget CR must be defined on ALL clusters (source and DR), pointing to the same shared storage.
- The DR cluster's BackupTarget CR must have the EventTarget flag set.
- A `ConsistentBackupPlan` must be defined to group all application namespaces into atomic snapshots — the EventTarget uses these as the unit of pre-staging.
- The `consistentSets` count should be configurable (default: 2–3 restore points retained on the DR cluster).
- The restore playbook (`dr-restore.yaml`) must be capable of targeting the pre-staged Consistent Set, not just a named Backup.
- The Annual DR Test workflow should use this path to demonstrate accelerated RTO.

#### Architecture Diagram (Continuous Restore Flow)
```
Source Cluster                        Shared Storage (S3)
─────────────                         ────────────────────
BackupPlan + Hooks                    BackupTarget (S3)
    │                                      ▲  │
    │  creates Backup CR                   │  │ new backup detected
    ▼                                      │  ▼
Backup (ConsistentSet) ──writes──────────►│  EventTarget pod polls
                                          │  (on DR cluster)
                                          │        │
DR Cluster                                │        │ pre-stages PVCs
─────────────                             │        ▼
BackupTarget (same S3) ◄──metadata only──┘  PVCs pre-staged locally
EventTarget flag set                              │
EventTarget pod running                           │ DR Test triggered
                                                  ▼
                                         Restore CR (metadata fetch only)
                                                  │
                                                  ▼
                                         App running with local PVC data
                                         + Transform applied (Route/Ingress)
```

### Req 7a — Hook CR Support for ConsistentSet Restores

For standard backup/location restores, the `dr-restore.yaml` playbook includes a pre-deployed `Hook` CR in the Restore CR's `hookConfig` — this causes Trilio to automatically execute the MySQL wp_options URL rewrite post-restore. For ConsistentSet restores, the playbook achieves the same result via a direct `kubectl exec` into the MySQL container (section 10 of the playbook). Both paths produce an identical outcome.

Adding `hookConfig` support for ConsistentSet restores would unify the two code paths and eliminate the direct exec step. This is a planned enhancement for a future iteration.

### Req 11 — Pattern Documentation for validatedpatterns.io

A `Document.md` file in the repo root that serves as the canonical usage manual for pattern adopters. This file is pulled by the Red Hat Validated Patterns team to publish on validatedpatterns.io.

**Audience:** Operators, architects, and developers who want to deploy and use the pattern — not contributors writing PRD-level detail.

**Required sections:**
- Pattern overview and use case
- Architecture: hub vs. spoke roles, key components, how Trilio integrates with the Validated Patterns framework
- Pre-requisites and environment requirements
- Deployment walkthrough: `make install`, secret population, cluster labelling
- Operational guide: how to trigger backup, DR restore (standard and Continuous Restore paths), and the Annual DR Test
- Ansible playbook reference (inputs, outputs, when to use each)
- Troubleshooting: top failure modes with diagnostic commands
- Links to upstream Trilio documentation and Red Hat Validated Patterns resources

**Constraints:** Must not duplicate `PRD.md` (internal requirements) or `Learnings.md` (contributor gotchas). Length target: readable in under 20 minutes.

---

### Req 12 — Imperative Framework Automation (E2E DR Lifecycle)

**Priority: P0 — This is the primary automated validation path for the pattern.**

The VP imperative framework executes Ansible playbooks as Kubernetes Jobs on a schedule (default: every 10 minutes) using the `imperative.jobs` list in `values-hub.yaml`. This enables fully automated, cluster-driven DR lifecycle management with no human intervention required after initial cluster provisioning.

#### Design Goals
- Prove the pattern is fully automated, not just scripted — the cluster drives the workflow
- Serve as the continuous E2E test harness: run after every code change to validate the full DR path
- Enable demo scenarios where the full hub + spoke DR workflow completes automatically in ~30 minutes after clusters are up
- Alert on success or failure so operators know when DR readiness changes

#### Workflow Phases

**Phase 1 — Hub Ready: Ensure a backup exists**

Trigger: Hub cluster is up, Trilio TVM is healthy, WordPress is running.

Jobs:
1. `imperative-validate` — poll until CSV Succeeded + TVM Deployed/Updated + License present + BackupTarget Available; fail fast with diagnostic output if not ready within timeout
2. `imperative-backup` — check if any Available Backup exists for `wordpress-backup-plan-cr` (the CR BackupPlan); if none, create one; wait for Available; idempotent (skips if backup already present)

**Phase 2 — DR Cluster Joins: Enable Continuous Restore**

Trigger: ACM detects a cluster with label `clusterGroup=group-one` that does not yet have an Available ConsistentSet on the shared BackupTarget.

Jobs:
3. `imperative-enable-cr` — wraps `enable-continuous-restore.yaml`; runs on hub with DR cluster context; retries until CR BackupPlan Available; idempotent (skips if CR BackupPlan already present and Available)
4. `imperative-wait-cs` — poll BackupTarget on DR cluster until at least one ConsistentSet is Available; timeout with alert

**Phase 3 — DR Test: Restore and Validate**

Trigger: ConsistentSet Available on DR cluster.

Jobs:
5. `imperative-restore` — wraps `dr-restore.yaml -e restore_method=consistentset`; targets most recent Available ConsistentSet; waits for Restore Completed; applies Route transform
6. `imperative-validate-restore` — curl WordPress at DR URL; confirm HTTP 200; verify wp_options siteurl/home match DR URL; output PASS/FAIL with timestamp

**Phase 4 — Alert**

7. `imperative-alert` — post result summary (cluster name, backup name, ConsistentSet name, restore name, pass/fail, elapsed time) to a configured output (log, Slack webhook, or ACM policy status)

#### Implementation Notes
- Each phase is a separate playbook in `ansible/playbooks/` prefixed `imperative-*.yaml`
- Playbooks must be idempotent — repeated runs produce the same result without side effects
- Each job declares `timeout` in seconds; total `activeDeadlineSeconds` covers the full pipeline (~2 hours for cold-start)
- The `imperative.schedule` in `values-hub.yaml` drives Phase 1 continuously; Phase 2–4 are edge-triggered (run once when condition first satisfied) — implement with a flag ConfigMap or Backup/ConsistentSet existence check to avoid re-running on every schedule tick
- DR cluster context must be available to hub-side imperative jobs: store the DR cluster kubeconfig in Vault at `secret/global/dr-cluster-kubeconfig`; ESO ExternalSecret loads it into a Secret consumed by the imperative Job Pod

#### New Playbooks Required
| Playbook | Phase | Description |
|----------|-------|-------------|
| `ansible/playbooks/imperative-validate.yaml` | 1 | Pre-flight health check (CSV, TVM, License, BackupTarget) |
| `ansible/playbooks/imperative-backup.yaml` | 1 | Ensure Available backup exists; create if absent |
| `ansible/playbooks/imperative-enable-cr.yaml` | 2 | Enable Continuous Restore on DR cluster (idempotent) |
| `ansible/playbooks/imperative-wait-cs.yaml` | 2 | Poll for Available ConsistentSet on DR cluster |
| `ansible/playbooks/imperative-restore.yaml` | 3 | Restore from ConsistentSet; apply Route transform |
| `ansible/playbooks/imperative-validate-restore.yaml` | 3 | Verify WordPress accessible at DR URL |
| `ansible/playbooks/imperative-alert.yaml` | 4 | Emit structured pass/fail result |

#### `values-hub.yaml` imperative.jobs additions (sketch)
```yaml
imperative:
  jobs:
    - name: imperative-validate
      playbook: ansible/playbooks/imperative-validate.yaml
      timeout: 600
    - name: imperative-backup
      playbook: ansible/playbooks/imperative-backup.yaml
      timeout: 1800
    - name: imperative-enable-cr
      playbook: ansible/playbooks/imperative-enable-cr.yaml
      timeout: 600
    - name: imperative-wait-cs
      playbook: ansible/playbooks/imperative-wait-cs.yaml
      timeout: 3600
    - name: imperative-restore
      playbook: ansible/playbooks/imperative-restore.yaml
      timeout: 1800
    - name: imperative-validate-restore
      playbook: ansible/playbooks/imperative-validate-restore.yaml
      timeout: 300
    - name: imperative-alert
      playbook: ansible/playbooks/imperative-alert.yaml
      timeout: 120
```

---

### Req 11 — Pattern Documentation for validatedpatterns.io

A `Document.md` file in the repo root that serves as the canonical usage manual for pattern adopters. This file is intended to be pulled by the Red Hat Validated Patterns team for publication on validatedpatterns.io.

**Audience:** Operators, architects, and developers who want to deploy and use the pattern — not contributors writing PRD-level detail.

**Required sections:**
- Pattern overview and use case
- Architecture: hub vs. spoke roles, key components, how Trilio integrates with the Validated Patterns framework
- Architecture diagram placeholder — a draw.io diagram file will be added to the repo separately and referenced here
- Pre-requisites and environment requirements
- Deployment walkthrough: `make install`, secret population, cluster labelling
- Operational guide: how to trigger backup, DR restore (standard and Continuous Restore paths), and the Annual DR Test
- Ansible playbook reference (inputs, outputs, when to use each)
- Troubleshooting: top failure modes with diagnostic commands
- Links to upstream Trilio documentation and Red Hat Validated Patterns resources

**Constraints:** Must not duplicate `PRD.md` (internal requirements) or `Learnings.md` (contributor gotchas). Length target: readable in under 20 minutes.

---

### Req 14 — Remove Multicloud-GitOps Upstream Overhead

The pattern was bootstrapped from the `multicloud-gitops` upstream template and carries inherited artifacts that have no relevance to Trilio DR. These must be removed or documented before public publication. Every removal decision must be recorded — items with potential future value are commented or noted rather than silently deleted.

**Remove entirely:**
| Item | Path | Reason |
|------|------|--------|
| hello-world chart | `charts/all/hello-world/` | Demo app unrelated to Trilio DR |
| hello-world references | `values-hub.yaml`, `values-group-one.yaml`, `values-standalone.yaml`, `values-4.2x-*.yaml` | Cleanup after chart removal |
| hello-world Trivy exemptions | `.trivyignore` lines for AVD-KSV-0020/0021/0014/0125 | Apache container CVEs; not applicable without chart |
| hello-world interop test | `tests/interop/test_modify_web_content.py` | Tests hello-world ConfigMap update; not Trilio |
| config-demo chart | `charts/all/config-demo/` | Demo app; ESO/Vault validation covered by Trilio-specific tooling |
| config-demo references | `values-hub.yaml`, `values-group-one.yaml`, `values-standalone.yaml` | Cleanup after chart removal |
| values-standalone.yaml | `values-standalone.yaml` | Single-cluster topology not part of hub/spoke Trilio design |
| charts/region/.keep | `charts/region/` | Empty placeholder from template |

**Update (do not remove):**
| Item | Path | Change Required |
|------|------|-----------------|
| values-global.yaml | `values-global.yaml` | Change `global.pattern` from `multicloud-gitops` to `trilio-gitops` |
| pattern-metadata.yaml | `pattern-metadata.yaml` | Update name, display_name, repo_url, issues_url, docs_url, ci_url, owners |
| ansible/site.yaml | `ansible/site.yaml` | Update comment from "MultiCloud-GitOps" to "Trilio GitOps" |
| tests/interop/run_tests.sh | `tests/interop/run_tests.sh` | Change `PATTERN_NAME="MultiCloudGitops"` and `PATTERN_SHORTNAME="mcgitops"` |
| RHDP sync workflow | `.github/workflows/sync-rhdp-branch.yml` | Update pattern name reference; keep workflow — pattern targets RHDP |
| RHDP metadata workflow | `.github/workflows/update-metadata.yml` | Update pattern name in metadata reference; keep workflow |

**Keep with comment explaining retention:**
| Item | Path | Why Keep |
|------|------|---------|
| Version-specific values | `values-4.20-hub.yaml`, `values-4.20-group-one.yaml`, `values-4.21-*.yaml` | Required for OCP 4.20/4.21 ESO API version compatibility |
| overrides/ directory | `overrides/values-AWS.yaml`, `values-IBMCloud.yaml` | VP sharedValueFiles mechanism; cloud-platform overrides are a useful extension point for future Trilio cloud-specific config |
| tests/interop/ framework | `conftest.py`, hub/edge component tests, subscription tests | VP test harness; valuable for CI/CD validation — update PATTERN_NAME references only |
| imperative framework | `values-hub.yaml` `imperative:` section | Powers Req 12 automation; critical to keep and extend |

---

### Req 13 — VP Uninstall: Teardown Validation

The latest Validated Patterns framework supports pattern uninstall via deletion of the Pattern CR. Deleting the CR triggers a ~30-minute automated teardown of all pattern-managed resources.

**Scope:**
- Delete Pattern CR → framework removes all ArgoCD Applications, Subscriptions, and managed namespaces
- ODF is **intentionally excluded** — ODF does not support removal after installation and should remain in place
- Trilio operator should be removed (OLM Subscription deleted by framework)
- Vault and ESO should be removed
- ACM: spoke clusters should be gracefully disassociated (ManagedCluster detached), not deleted

**Requirements:**
1. Document the exact uninstall command and expected teardown sequence
2. Identify any resources that retain finalizers after Pattern CR deletion and document the manual finalizer removal steps (e.g., `oc patch ... -p '{"metadata":{"finalizers":[]}}' --type=merge`)
3. Confirm hub cluster is left in a clean state: no VP namespaces, no Trilio resources, no ArgoCD Applications for this pattern
4. Confirm spoke cluster is disassociated from ACM hub and functional as a standalone cluster (Trilio uninstalled, ODF intact)
5. Document which pre-requisites (ODF, pull secrets) persist after uninstall — these are the starting point for a fresh re-install

**Out of scope:** ODF removal, OpenShift upgrade, or cluster decommission.

---

### Req 15 — Publish to New Public GitHub Repo: trilio-continuous-restore

Create a clean, publicly accessible GitHub repository named **`trilio-continuous-restore`** for the Trilio GitOps Validated Pattern. This repo is the artifact delivered to Red Hat and Trilio for community and customer use.

**Pre-requisites:** Req 14 (overhead removal) complete.

**Scope:**
- New repo name: `trilio-continuous-restore`
- Org: TBD — either `validatedpatterns` if adopted by the RH VP team, or `trilio-demo` / partner org for interim publication
- All content from `dallas` branch of this working repo, after Req 14 cleanup, forms the `main` branch of the new public repo
- No internal working files, scratch notes, or lab-specific configuration visible in the new repo

**Files to exclude from public repo (confirm these are already in .gitignore):**
- `Team.md`
- Any `values-secret.yaml` variants
- `CLAUDE.md` (internal AI contributor instructions — decision: include or exclude?)
- `.claude/` directory

**RHDP Workflow decision point:**
The `sync-rhdp-branch.yml` workflow has an org guard: `if: github.repository_owner == 'validatedpatterns'`. If the new public repo is under a different org, this workflow will silently no-op. Options:
1. Update the org guard to match the new repo owner
2. Remove the guard and rely on the `DOCS_TOKEN` secret being absent to prevent unintended triggers
3. Coordinate with RH VP team to host under `validatedpatterns` org from day one

**pattern-metadata.yaml must be fully updated before push:**
- `name: trilio-continuous-restore`
- `display_name: Trilio Continuous Restore`
- `repo_url`: new public repo URL
- `issues_url`: new public repo issues URL
- `docs_url`: TBD (validatedpatterns.io page once published)
- `ci_url`: TBD
- `owners`: update to reflect Trilio + RH contacts

**values-global.yaml:**
- `global.pattern: trilio-continuous-restore`

**Post-publication:**
- Create a PR from `main` in new public repo to register in the VP patterns index
- Notify RH VP team for documentation pull and validatedpatterns.io listing
- `Document.md` (Req 11) serves as the primary onboarding document

---

### Req 8 — VM Application (Deferred)
OpenShift Virtualization (KubeVirt/CNV) adds significant complexity (operator, DataVolumes, potentially build pipelines). A simple RHEL or Fedora appliance VM avoids Windows licensing friction. Deferred to a future iteration; flagged as a stretch goal for customer POC demos. If implemented, the VM should be brought up in a `stopped` state post-restore so the operator can verify before starting.

### Req 9 — Upgrade to Trilio 5.3.x: Native License-via-Secret

Trilio 5.3.0 introduces native support for license management via a Kubernetes Secret — the operator reads the license key directly from a named Secret, eliminating the need for the License CR and the Job workaround. During an upgrade from 5.2.x, Trilio automatically converts the existing License CR to the new Secret-based model.

**Impact on this pattern:**
- The ESO ExternalSecret (`trilio-license-external-secret.yaml`) is retained unchanged — the `trilio-license` Secret it creates from Vault is exactly what Trilio 5.3.x reads natively. No Vault path changes required.
- The `trilio-license-job` (Job, ServiceAccount, Role, RoleBinding) is **preserved in the chart** — it provides a 5.2.x backward-compatibility path and is a valuable reference for the "declarative systems with runtime dependencies" pattern. The Job becomes a no-op on 5.3.x (License CR already handled natively) but does no harm.
- The native 5.3.x License Secret reference is added to the TrilioVaultManager spec alongside the existing resources.
- This resolves the Helm/ESO ordering limitation for 5.3.x while keeping the Job as living documentation and a fallback.

**Status (2026-03-11):** 5.3.x manifests for the new License Secret and TrilioVaultManager spec are in hand. Ready to implement.

**Implementation steps:**
1. Add the 5.3.x native License Secret reference to the TrilioVaultManager spec in `charts/all/trilio-operand/`
2. Change OLM channel from `5.2.x` → `5.3.x` in `values-hub.yaml` and `values-group-one.yaml`
3. Validate upgrade path: existing License CR converts automatically on upgrade; no manual intervention required
4. Add a `Learnings.md` section documenting the 5.3.x model and any upgrade gotchas; retain the Job workaround section as a reference pattern

**Current state:** Pinned to `5.2.x` channel (OLM will not auto-upgrade). Implementation begins after Req 10 sync-wave fix is validated.

### Req 10 — Spoke Onboarding: Resolve OLM/ArgoCD Race Condition

When ACM bootstraps a new group-one spoke, ArgoCD syncs all applications immediately — including `trilio-operand`, which contains the TrilioVaultManager and BackupTarget CRs. These require Trilio CRDs to be registered. OLM installs the Trilio operator asynchronously; if ArgoCD wins the race, the sync fails with CRDs not yet available and the app stays `OutOfSync / Missing`.

**Observed behaviour (2026-03-10):** CSV reached `Succeeded` (5.2.0) but `trilio-operand` remained `OutOfSync / Missing`. Manual sync patch did not self-recover, suggesting a secondary ESO dependency (ExternalSecrets also in the same chart need ESO running and Vault reachable before the License Job proceeds).

**Root cause confirmed (2026-03-11):** Two-layer deadlock:
1. Trilio's admission webhook (`tvk-mutation.trilio.io`) validates the Target CR and checks that `aws-s3-login` credential Secret exists at apply time — rejects if absent
2. `aws-s3-login` is created by an ESO ExternalSecret that lives in the same `trilio-operand` chart — because the webhook rejection causes the entire sync to fail, the ExternalSecret never lands, ESO never creates the secret, webhook keeps rejecting

ArgoCD retries indefinitely but never self-recovers. Observed: attempt #7+ with no progress.

**Confirmed fix:** Split the ExternalSecrets (`trilio-s3-credentials`, `trilio-license`) out of `charts/all/trilio-operand/` into a new dedicated ArgoCD application (`trilio-secrets`) that syncs before `trilio-operand` using ArgoCD sync waves. Once ESO creates the secrets, the Trilio webhook is satisfied and `trilio-operand` syncs cleanly on the first try.

**Implementation approach (2026-03-11):**
1. Create `charts/all/trilio-secrets/` containing only the two ExternalSecret templates (extracted from `trilio-operand`)
2. Add `trilio-secrets` as a new application in `values-group-one.yaml` with `argocd.argoproj.io/sync-wave: "-1"` annotation so it deploys before all other applications
3. Remove the ExternalSecret templates from `charts/all/trilio-operand/` (they now live in `trilio-secrets`)
4. `trilio-operand` remains at default sync-wave 0 — it will only attempt to sync after `trilio-secrets` (and ESO) have run
5. Validate on a fresh spoke onboard: `trilio-operand` should sync cleanly without the manual workaround

**Current workaround:** Manually render and apply the ExternalSecrets to break the deadlock, then trigger a sync. See `Learnings.md` onboarding Known Issue section for exact commands and debugging runbook.

---

## References
- [Red Hat Validated Patterns: multicloud-gitops](https://github.com/validatedpatterns/multicloud-gitops)
- [Red Hat Validated Patterns: config-demo](https://github.com/validatedpatterns/config-demo)
- [Trilio for Kubernetes Documentation](https://docs.trilio.io/kubernetes/)
- [Trilio BackupPlan Hooks](https://docs.trilio.io/kubernetes/architecture/apis-and-command-line-reference/custom-resource-definitions-application-1/triliovaultmanager#hooks)
- [Trilio Transform CRD](https://docs.trilio.io/kubernetes/architecture/apis-and-command-line-reference/custom-resource-definitions-application-1/triliovaultmanager#transform)
- [Trilio ConsistentBackupPlan](https://docs.trilio.io/kubernetes/architecture/apis-and-command-line-reference/custom-resource-definitions-application-1/triliovaultmanager#consistentbackupplan)
- [Trilio EventTarget / Continuous Restore](https://docs.trilio.io/kubernetes/)

---

## Acceptance Criteria
- Pattern deploys successfully via ArgoCD with minimal manual intervention on any OCP 4.x cluster.
- Trilio operator and operands are fully functional and licensed.
- WordPress sample app is deployed via Helm and managed by ArgoCD.
- BackupTarget CR is defined on all clusters and reaches `Available` state.
- BackupPlan with quiesce/unquiesce hooks is defined and validated for the WordPress namespace.
- Backup playbook (`dr-backup.yaml`) runs successfully against a real cluster.
- Standard restore playbook (`dr-restore.yaml`) completes on a separate cluster.
- Post-restore Transform is applied and verified (Route/Ingress hostname updated).
- EventTarget flag is set on DR cluster BackupTarget; EventTarget pod is running.
- ConsistentBackupPlan is defined and PVCs are pre-staged on DR cluster.
- DR Test restore completes from pre-staged Consistent Set (metadata-only fetch from BackupTarget).
- Pattern passes all included Ansible validation playbooks.
- Documentation is complete and follows Validated Patterns standards.

---

## Execution Environment: Validated Patterns Utility Container

All pattern bootstrap and operational tooling runs inside the **Red Hat Validated Patterns standard utility container**, invoked via `pattern.sh`. This eliminates local toolchain dependencies and ensures reproducible execution across environments (developer laptops, CI/CD pipelines, RHPDS demo clusters).

**Container image:** `quay.io/validatedpatterns/utility-container` (maintained by the VP team)

**Included tooling:**

| Tool | Purpose in this Pattern |
|------|------------------------|
| `oc` / `kubectl` | Interact with OpenShift/Kubernetes API |
| `helm` | Deploy operand Helm charts (trilio-operand, etc.) |
| `ansible` + `ansible-navigator` | Run DR validation and workflow playbooks |
| `kubernetes.core` Ansible collection | `k8s` and `k8s_info` modules used in all playbooks |
| `git` | Clone and manage pattern repository |
| `make` | Drive pattern lifecycle targets (`install`, `upgrade`, etc.) |
| `python3` + `pip` | Runtime for Ansible and Kubernetes SDK |
| `jq` / `yq` | JSON/YAML manipulation in scripts |
| `podman` | Container runtime for the utility container itself |

**Extension point:** If additional Ansible collections are required (e.g. future playbooks), add an `ansible/requirements.yml` file — the framework installs declared collections automatically at runtime without requiring a custom container image.

---

## Implementation and Validation Matrix

| Requirement | Implementation | Validation/Test Evidence | Status |
|-------------|----------------|-------------------------|--------|
| Default CSI StorageClass present on all clusters | Pre-requisite (not installed by VP); validated by playbook | `validate-trilio.yaml` task 0 asserts default StorageClass exists with CSI provisioner; fails fast with install guidance if absent | Validated in playbook |
| Trilio operator installed via OLM Subscription | ACM policy or Subscription YAML | Confirmed operator pod running in target namespace; Subscription and CSV present | Validated |
| Trilio operand (TrilioVaultManager) installed via Helm | trilio-operand Helm chart (triliovaultmanager.yaml) | Helm release deployed; TVM CR present and reconciled | Validated |
| Trilio license Secret created from Vault via ESO | values.yaml, ESO/Secret manifest | Secret appears in trilio-system namespace with correct key | Validated |
| Trilio License CR created by Job when Secret exists | trilio-license-job.yaml + RBAC manifests | Job runs, detects Secret, creates License CR; Trilio UI/API shows licensed | Validated |
| README with architecture diagram and troubleshooting | README.md (Mermaid diagram, troubleshooting section) | Diagram renders in GitHub; troubleshooting covers all major failure scenarios | Validated |
| DR validation playbook | ansible/playbooks/validate-trilio.yaml | Playbook runs end-to-end against real cluster: CSV Succeeded, TVM Deployed, License CR present, all pods Running | Validated |
| values-group-one.yaml spoke application path correct | values-group-one.yaml | ArgoCD syncs trilio-operand chart to spoke cluster | Validated |
| S3 credentials stored in Vault (`secret/global/trilio-s3`) | Plain text `accessKey` + `secretKey` written to Vault via `oc exec -n vault vault-0` using root token from `vaultkeys` secret in `imperative` namespace | Vault KV entry confirmed; ESO ExternalSecret `trilio-s3-credentials` synced and `aws-s3-login` Secret created in `trilio-system` within 5 minutes | Validated 2026-03-04 |
| `aws-s3-login` OCP Secret created by ESO from Vault | ExternalSecret `trilio-s3-credentials` in `charts/all/trilio-operand/templates/backup-target-secret.yaml`; refreshInterval: 5m | Secret `aws-s3-login` present in `trilio-system` with correct plain text `accessKey` and `secretKey` fields | Validated 2026-03-04 |
| BackupTarget CR on all clusters (S3, credentials from Vault) | charts/all/trilio-operand: backup-target.yaml (Target CR) + backup-target-secret.yaml (ExternalSecret → aws-s3-login Secret from secret/global/trilio-s3); EventTarget annotation set to "true" on all clusters | BackupTarget `trilio-s3-target` reached `Available` state in `trilio-system`; EventTarget annotation present | Validated 2026-03-04 |
| Sample app: WordPress + MySQL via Helm | charts/all/wordpress (custom chart from existing manifests; ServiceAccount + anyuid RoleBinding; ClusterIP + Route) | Deployed to `wordpress` namespace via ArgoCD on hub cluster; pods Running; Route accessible (2026-03-04) | Validated |
| BackupPlan CR scoped to WordPress namespace | charts/all/wordpress/templates/backup-plan.yaml — BackupPlan `wordpress-backup-plan` protecting full `wordpress` namespace via `backupPlanComponents: {}`; references `trilio-s3-target` | BackupPlan deployed via ArgoCD; manual backup completed successfully | Validated 2026-03-05 |
| Quiesce/unquiesce hooks for MySQL | charts/all/wordpress/templates/backup-hook.yaml — Hook CR `wordpress-mysql-hook` in `wordpress` namespace; pre: `FLUSH TABLES WITH READ LOCK`; post: `FLUSH LOGS; UNLOCK TABLES`; selector: `wordpress-mysql*` | Hook deployed via ArgoCD; executed as part of manual backup run | Validated 2026-03-05 |
| DR backup workflow playbook (tested) | ansible/playbooks/dr-backup.yaml — reworked to use existing ArgoCD-managed BackupPlan; auto-timestamped backup_name; Full/Incremental type parameter | Playbook run end-to-end; Backup CR reached `Available`; hooks executed; TVM Updated state accepted | Validated 2026-03-05 |
| DR restore from Backup (backup method) | ansible/playbooks/dr-restore.yaml `-e restore_method=backup`; auto-discovers latest Available Backup if name omitted; Route hostname auto-discovered from `Ingress/cluster` | Restore CR `Completed`; Route hostname correct; pods Running | Validated 2026-03-06 |
| DR restore from location browse (location method) | ansible/playbooks/dr-restore.yaml `-e restore_method=location`; path auto-extracted from Backup CR `status.location` or supplied manually via `backup_location_path`; Target namespace must be `trilio_namespace` (trilio-system), not restore namespace | Restore CR `Completed`; Route hostname correct; Hook ran (MySQL wp_options updated); pods Running | Validated 2026-03-10 |
| Cross-cluster restore (parameterized for target cluster) | ansible/playbooks/dr-restore.yaml (kubeconfig param) | Restore completes on separate cluster using shared BackupTarget storage | Not Started |
| Post-restore Route transform (hostname patch) | dr-restore.yaml `transformComponents` — `{{ restore_namespace }}.{{ ingress_domain }}`; ingress domain auto-discovered from `config.openshift.io/v1 Ingress/cluster`; no separate Transform CR needed | Route hostname updated inline during restore | Validated 2026-03-06 |
| Post-restore MySQL Hook (wp_options URL rewrite) | wordpress-restore-hook Hook CR pre-deployed in restore namespace; dr-restore.yaml detects and includes in hookConfig if present | MySQL wp_options siteurl/home updated to DR URL post-restore | Validated 2026-03-10; GitOps automation complete (Req 6c) |
| wordpress-restore namespace + RBAC pre-provisioned via GitOps | charts/all/wordpress-restore/ — deploys namespace, wordpress-sa SA, anyuid RoleBinding, wordpress-restore-hook Hook CR; wired into values-hub.yaml + values-group-one.yaml; hook URL rendered from global.localClusterDomain | wordpress-restore NS + Hook CR + RBAC pre-exist on all clusters before restore | Done 2026-03-10 |
| CR BackupPlan (ContinuousRestore-enabled) | `enable-continuous-restore.yaml` playbook — discovers spoke instanceID from Target CR `status.availableContinuousRestoreInstances`; creates ContinuousRestore Policy (consistentSets=3) and CR-enabled BackupPlan in `wordpress` ns; Ansible-owned (no ArgoCD tracking) | BackupPlan `wordpress-backup-plan-cr` reached `Available`; backup created via `dr-backup.yaml -e backupplan_name=wordpress-backup-plan-cr` | Done 2026-03-14 |
| EventTarget flag on DR cluster BackupTarget | BackupTarget CR `trilio.io/event-target: "true"` annotation set on all clusters (Req 3) | EventTarget pod running in `trilio-system` on DR cluster | Done (Req 3) |
| PVC pre-staging via EventTarget pod | Automatic — EventTarget pod monitors shared S3 BackupTarget for new CR backups | ConsistentSet CR created on DR cluster (ocp-dc12) after CR-enabled backup | Done 2026-03-14 |
| Accelerated restore from pre-staged Consistent Set | ansible/playbooks/dr-restore.yaml `-e restore_method=consistentset -e consistent_set_name=<name>`; post-restore URL rewrite via direct database exec (Hook CR support planned, Req 7a) | Restore completed; Route hostname correct; MySQL wp_options updated via direct exec; WordPress accessible at DR URL | Done 2026-03-13 |
| DR trigger mechanism (Annual DR Test) | TBD — documented runbook or ACM scheduled policy invoking dr-test.yaml | DR test invocable by single command or automated trigger | Not Started |
| (Optional) VM-based application | Deferred — OpenShift Virtualization / KubeVirt | VM restores in stopped state; operator verifies before starting | Deferred |
| Spoke onboarding race condition (Req 10) | `charts/all/trilio-secrets/` new app (sync-wave -1) with ExternalSecrets only; `trilio-operand` at wave 0 with `SkipDryRunOnMissingResource=true`; ExternalSecret templates removed from `trilio-operand` chart | Fresh spoke onboard completes fully automatically with no manual workaround — validated 2026-03-13 on ocp-dc12 | Done |
| Trilio 5.3.x native license-via-Secret (Req 9) | Add 5.3.x License Secret ref to TVM spec; bump OLM channel to 5.3.x; retain Job for 5.2.x backwards compatibility | Upgrade validates automatically; License CR converts; no manual steps | In Progress (manifests in hand) |
| Pattern documentation for validatedpatterns.io (Req 11) | `Document.md` in repo root — usage manual for pattern adopters covering architecture, deployment, operations, and troubleshooting | Document pulled by RH VP team; published on validatedpatterns.io | Not Started |
| Imperative Framework Automation — E2E DR lifecycle (Req 12) | 7 imperative playbooks wired into `values-hub.yaml` `imperative.jobs`; 4-phase pipeline: validate → backup → enable CR → wait CS → restore → validate restore → alert | Full E2E DR cycle completes automatically after clusters up; PASS/FAIL alert emitted | Not Started |
| VP Uninstall teardown validation (Req 13) | Delete Pattern CR; document finalizer cleanup; confirm ODF preserved; confirm spoke disassociation | Hub clean (no VP namespaces/Trilio/ArgoCD apps); spoke standalone and functional; ODF intact | Not Started |

> Update this table as new requirements are implemented and validated.

---

## Ansible Playbook Responsibilities

`site.yaml` is the RHPDS bootstrap shim only — it runs `pattern.sh make install` and is not the DR workflow coordinator.

| Playbook | Role | Status |
|----------|------|--------|
| `ansible/site.yaml` | RHPDS bootstrap (pattern install) | Done |
| `ansible/playbooks/validate-trilio.yaml` | Pre-flight health check (CSV, TVM, License, pods) | Validated |
| `ansible/playbooks/dr-backup.yaml` | Verify existing BackupPlan + create Backup CR, poll to completion | Validated 2026-03-05 |
| `ansible/playbooks/dr-restore.yaml` | Create Restore CR (backup/location/consistentset), auto-discover Route hostname, optional hookConfig, poll to completion, validate pods | Validated 2026-03-06 (backup method) |
| `ansible/playbooks/enable-continuous-restore.yaml` | Discover spoke instanceID from Target CR status; create ContinuousRestore Policy + CR-enabled BackupPlan (Ansible-owned, not ArgoCD-managed) | Done 2026-03-14 |
| `ansible/playbooks/dr-test.yaml` | Annual DR Test — backup + pre-staged restore + transform end-to-end | Not Started |
| `ansible/playbooks/imperative-validate.yaml` | Imperative: pre-flight health check — CSV, TVM, License, BackupTarget (Req 12 Phase 1) | Not Started |
| `ansible/playbooks/imperative-backup.yaml` | Imperative: ensure Available backup exists; create if absent (Req 12 Phase 1) | Not Started |
| `ansible/playbooks/imperative-enable-cr.yaml` | Imperative: enable Continuous Restore on DR cluster; idempotent (Req 12 Phase 2) | Not Started |
| `ansible/playbooks/imperative-wait-cs.yaml` | Imperative: poll for Available ConsistentSet on DR cluster (Req 12 Phase 2) | Not Started |
| `ansible/playbooks/imperative-restore.yaml` | Imperative: restore from ConsistentSet; apply Route transform (Req 12 Phase 3) | Not Started |
| `ansible/playbooks/imperative-validate-restore.yaml` | Imperative: verify WordPress accessible at DR URL post-restore (Req 12 Phase 3) | Not Started |
| `ansible/playbooks/imperative-alert.yaml` | Imperative: emit structured pass/fail result with cluster + restore details (Req 12 Phase 4) | Not Started |

---

## Operator Installation and Operand Management

**Clarification:**
For OpenShift-based Validated Patterns, operators should be installed and managed using OLM (Operator Lifecycle Manager) via Subscription/OperatorGroup YAML or ACM policies. Helm should be used for deploying operands (the custom resources managed by operators) and other application resources. This approach aligns with both OpenShift best practices and Validated Pattern methodology, ensuring full GitOps compliance, upgradeability, and supportability.

---

*This PRD is intended for use by AI and human contributors to guide the development of a new Red Hat Validated Pattern for Disaster Recovery with Trilio. All contributions must adhere to the requirements and best practices outlined above.*
