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
| 4 | Define a BackupPlan CR scoped to the sample app namespace, with quiesce/unquiesce hooks | P0 — Not Started |
| 5 | Execute a Backup of the sample app via Ansible playbook | P0 — Not Started (playbook exists, untested) |
| 6 | Restore the app from a Backup to a different cluster, triggered by a defined event | P1 — Not Started |
| 6a | Transform the restored app post-restore (e.g., patch Route/Ingress hostname) | P1 — Not Started |
| 7 | Continuous Restore via EventTarget: pre-stage PVCs on DR cluster from ConsistentBackupPlan for accelerated RTO | P1 — Not Started |
| 8 | (Optional) Deploy a VM-based application (OpenShift Virtualization) | P2 — Deferred |

---

## Detailed Requirement Notes

### Req 2 — Sample App (WordPress + MySQL) ✓ DONE
Custom Helm chart at `charts/all/wordpress/` built from owner's existing manifests. Preserves `app: wordpress` / `tier: mysql` / `tier: frontend` labels (required for Trilio hook selectors). Replaces manual `oc adm policy add-scc-to-user anyuid` with a declarative ServiceAccount + RoleBinding. NodePort replaced with ClusterIP + OpenShift Route. Deployed to `wordpress` namespace on hub (primary) cluster via ArgoCD. Validated 2026-03-04.

### Req 3 — BackupTarget CR (All Clusters) ✓ DONE
`trilio-s3-target` Target CR deployed in `trilio-system` on hub cluster via `charts/all/trilio-operand`. S3 credentials (`accessKey`/`secretKey`) stored in Vault at `secret/global/trilio-s3` as plain text; ESO ExternalSecret `trilio-s3-credentials` syncs them into `aws-s3-login` Secret within 5 minutes. BackupTarget reached `Available` state after correct credentials were stored. EventTarget annotation (`trilio.io/event-target: "true"`) set on all clusters. Bucket: `sa-demo-2`, region: `us-east-1`. Validated 2026-03-04.

> **Note:** Credentials must be plain text in Vault — base64-encoded values cause double-encoding by ESO and result in a `Failed` Target state. See Learnings.md for the correct `oc exec` extraction and write commands.

### Req 4 — BackupPlan with Quiesce/Unquiesce Hooks
The BackupPlan must reference the WordPress namespace. Quiesce/unquiesce hooks are required to achieve a crash-consistent MySQL backup — hooks run before/after snapshot to drain in-flight writes. Owner has existing hook manifests that can be contributed.

### Req 5 — Backup Execution
`dr-backup.yaml` Ansible playbook exists but is untested. Must be validated against a real cluster with the WordPress app running and a BackupTarget defined.

### Req 6 — Cross-Cluster Restore (Standard Path)
The restore playbook (`dr-restore.yaml`) must be parameterized for a target cluster kubeconfig/context. The target cluster must have Trilio installed (via this pattern) and a BackupTarget CR pointing to the same storage as the source. In this path, Trilio fetches both metadata and data from the BackupTarget — RTO is bounded by data transfer time. The trigger for restore should be a defined operational event (e.g., an `ansible-navigator run` invoked from a CI/CD pipeline, ACM policy, or documented runbook command).

### Req 6a — Post-Restore Transform
Trilio's `Transform` CRD allows patching resources during restore (e.g., replacing the Route hostname with the DR-site hostname, updating StorageClass references). A sample Transform CR must be provided and wired into the restore playbook so the app is immediately accessible after restore without manual intervention.

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

### Req 8 — VM Application (Deferred)
OpenShift Virtualization (KubeVirt/CNV) adds significant complexity (operator, DataVolumes, potentially build pipelines). A simple RHEL or Fedora appliance VM avoids Windows licensing friction. Deferred to a future iteration; flagged as a stretch goal for customer POC demos. If implemented, the VM should be brought up in a `stopped` state post-restore so the operator can verify before starting.

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
| BackupPlan CR scoped to WordPress namespace | TBD — Helm chart or Ansible | BackupPlan reaches `Available`; hooks defined for MySQL quiesce/unquiesce | Not Started |
| Quiesce/unquiesce hooks for MySQL | TBD — Hook CRs (owner has existing manifests) | Hooks run before/after snapshot; no data corruption in restore | Not Started |
| DR backup workflow playbook (tested) | ansible/playbooks/dr-backup.yaml | Playbook runs against real cluster; Backup CR reaches `Available` | Not Tested |
| DR restore workflow playbook — standard path | ansible/playbooks/dr-restore.yaml | Restore CR reaches `Completed` on separate cluster; pods Running | Not Tested |
| Cross-cluster restore (parameterized for target cluster) | ansible/playbooks/dr-restore.yaml (kubeconfig param) | Restore completes on separate cluster using shared BackupTarget storage | Not Started |
| Post-restore Transform (Route/Ingress hostname patch) | TBD — Transform CR + restore playbook integration | Route hostname updated to DR-site value post-restore | Not Started |
| ConsistentBackupPlan (multi-app atomic backup) | TBD — ConsistentBackupPlan CR | Multi-namespace backup completes atomically | Not Started |
| EventTarget flag on DR cluster BackupTarget | BackupTarget CR (eventTarget: true) on DR cluster | EventTarget pod running in trilio-system on DR cluster | Not Started |
| PVC pre-staging via EventTarget pod | Automatic (driven by EventTarget pod monitoring BackupTarget) | PVCs visible on DR cluster after new backup detected; data local | Not Started |
| Accelerated restore from pre-staged Consistent Set | ansible/playbooks/dr-restore.yaml (ConsistentSet target) | Restore completes with metadata-only fetch; significantly faster than standard path | Not Started |
| DR trigger mechanism (Annual DR Test) | TBD — documented runbook or ACM scheduled policy invoking dr-test.yaml | DR test invocable by single command or automated trigger | Not Started |
| (Optional) VM-based application | Deferred — OpenShift Virtualization / KubeVirt | VM restores in stopped state; operator verifies before starting | Deferred |

> Update this table as new requirements are implemented and validated.

---

## Ansible Playbook Responsibilities

`site.yaml` is the RHPDS bootstrap shim only — it runs `pattern.sh make install` and is not the DR workflow coordinator.

| Playbook | Role | Status |
|----------|------|--------|
| `ansible/site.yaml` | RHPDS bootstrap (pattern install) | Done |
| `ansible/playbooks/validate-trilio.yaml` | Pre-flight health check (CSV, TVM, License, pods) | Validated |
| `ansible/playbooks/dr-backup.yaml` | Create BackupPlan + Backup CR, poll to completion | Exists, untested |
| `ansible/playbooks/dr-restore.yaml` | Create Restore CR, poll to completion, apply Transform, validate pods | Exists, untested |
| `ansible/playbooks/dr-test.yaml` | Annual DR Test — backup + pre-staged restore + transform end-to-end | Not Started |

---

## Operator Installation and Operand Management

**Clarification:**
For OpenShift-based Validated Patterns, operators should be installed and managed using OLM (Operator Lifecycle Manager) via Subscription/OperatorGroup YAML or ACM policies. Helm should be used for deploying operands (the custom resources managed by operators) and other application resources. This approach aligns with both OpenShift best practices and Validated Pattern methodology, ensuring full GitOps compliance, upgradeability, and supportability.

---

*This PRD is intended for use by AI and human contributors to guide the development of a new Red Hat Validated Pattern for Disaster Recovery with Trilio. All contributions must adhere to the requirements and best practices outlined above.*
