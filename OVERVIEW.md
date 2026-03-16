# Disaster Recovery with Trilio — Pattern Overview

A Red Hat Validated Pattern that delivers fully automated, GitOps-driven Disaster Recovery for
OpenShift using [Trilio for Kubernetes](https://docs.trilio.io/kubernetes/).

---

## What This Pattern Delivers

| Capability | How |
|------------|-----|
| Trilio deployed and licensed across all clusters | OLM operators + Helm operands via ArgoCD |
| Secrets never in Git | HashiCorp Vault → External Secrets Operator → Kubernetes Secrets |
| New DR cluster onboards automatically | ACM bootstraps ArgoCD; sync-waves sequence the deployment |
| Sample stateful app (WordPress + MySQL) protected | BackupPlan with quiesce/unquiesce hooks |
| Standard DR restore | `dr-restore.yaml` playbook — backup or location browse methods |
| Accelerated DR restore (reduced RTO) | Continuous Restore — Trilio pre-stages PVCs on the DR cluster |
| Runnable DR Test | Single `ansible-navigator run` command; no manual prep required |

---

## Cluster Architecture

```mermaid
flowchart LR
  Git["📁 Git\nSource of Truth\n──────────────\nvalues-hub.yaml\nvalues-group-one.yaml\ncharts/"]

  subgraph Hub ["Hub Cluster"]
    direction TB
    ACM["ACM\nAdvanced Cluster Management\n────────────────────────\nPolicies · PlacementRules\nBootstraps spoke GitOps"]

    subgraph HubArgo ["ArgoCD  (Hub)"]
      direction TB
      HW1["① wave -1 · trilio-secrets\nExternalSecrets only\n(creates Vault-backed Secrets\nbefore any CRs are applied)"]
      HW0["② wave 0 · trilio-operand\nTrilioVaultManager CR\nBackupTarget S3\nLicense Job"]
      HWApp["③ wave 0 · wordpress\nSample app\nBackupPlan + Hooks"]
      HWRestore["③ wave 0 · wordpress-restore\nDR namespace\nHook CR · RBAC\n(pre-provisioned on every cluster)"]
      HW1 --> HW0
    end

    Vault["🔐 HashiCorp Vault\nLicense key\nS3 credentials"]
    ESO_H["External Secrets\nOperator"]
    TVM_H["Trilio\nOLM operator → TVM CR\nBackupTarget Available"]
    WordPress["WordPress + MySQL\nstateful sample app"]
  end

  subgraph Spoke ["DR Cluster  (group-one)"]
    direction TB

    subgraph SpokeArgo ["ArgoCD  (bootstrapped by ACM)"]
      direction TB
      SW1["① wave -1 · trilio-secrets\nExternalSecrets\n(same pattern as Hub)"]
      SW0["② wave 0 · trilio-operand\nTrilioVaultManager CR\nBackupTarget S3"]
      SWRestore["③ wave 0 · wordpress-restore\nDR namespace ready\nHook CR pre-deployed"]
      SW1 --> SW0
    end

    ESO_S["External Secrets\nOperator"]
    TVM_S["Trilio\nOLM operator → TVM CR\nBackupTarget Available"]
    EventTarget["EventTarget Pod\nMonitors shared S3\nfor new backups"]
    ConsistentSet["ConsistentSet\nPVCs pre-staged locally\n(accelerated RTO)"]
    WPRestore["wordpress-restore\nReady for failover\nbefore DR is declared"]
  end

  S3[("☁️  Shared S3\nSame bucket\nboth clusters")]

  Git -->|GitOps sync| HubArgo
  Git -->|GitOps sync| SpokeArgo
  ACM -->|"label cluster → group-one\nACM bootstraps ArgoCD\nautomatically"| SpokeArgo
  Vault -->|ESO sync| ESO_H
  ESO_H -->|"trilio-license\naws-s3-login"| HW1
  TVM_H -->|backup data| S3
  TVM_S -.-|"same bucket"| S3
  EventTarget -->|monitors| S3
  EventTarget -->|"pre-stages PVCs\n(3 consistent sets)"| ConsistentSet
```

---

## Deployment Sequencing (Sync Waves)

The sync-wave split solves a bootstrap ordering problem: Trilio's admission webhook requires
credential Secrets to exist before it will accept a BackupTarget CR. The wave -1 application
creates those Secrets first; wave 0 is guaranteed to find them ready.

```mermaid
sequenceDiagram
  participant ACM
  participant ArgoCD
  participant OLM
  participant ESO
  participant Trilio

  ACM->>ArgoCD: Bootstrap GitOps on new spoke
  Note over ArgoCD: sync-wave -1 runs first
  ArgoCD->>ESO: Apply ExternalSecrets (trilio-secrets app)
  ESO->>ESO: Sync from Vault → create Secrets
  Note over ArgoCD: sync-wave 0 runs after wave -1 completes
  ArgoCD->>OLM: OLM Subscription → install Trilio operator
  OLM->>Trilio: CSV Succeeded → TVM CRD registered
  ArgoCD->>Trilio: Apply TrilioVaultManager CR
  Trilio->>Trilio: Reconcile → register child CRDs
  ArgoCD->>Trilio: Apply BackupTarget CR
  Note over Trilio: Webhook validates aws-s3-login Secret ✓
  Trilio->>Trilio: BackupTarget → Available
```

---

## DR Workflow

Two restore paths are available. Both are driven by the same `dr-restore.yaml` playbook.

```mermaid
flowchart TD
  subgraph Normal ["Standard DR  (any backup)"]
    direction LR
    B1["Backup CR\npoint-in-time"]
    B2["dr-restore.yaml\n-e restore_method=backup\nor restore_method=location"]
    B3["Restore CR\nfetch metadata + data\nfrom S3"]
    B4["App running\nat DR URL"]
    B1 --> B2 --> B3 --> B4
  end

  subgraph CR ["Accelerated DR  (Continuous Restore)"]
    direction LR
    C1["enable-continuous-restore.yaml\nCreates CR BackupPlan\n+ ContinuousRestore Policy"]
    C2["dr-backup.yaml\nBackup from CR BackupPlan"]
    C3["EventTarget Pod\nDetects new backup\nPre-stages PVCs on DR cluster"]
    C4["ConsistentSet CR\nData already local\n(3 sets retained)"]
    C5["dr-restore.yaml\n-e restore_method=consistentset"]
    C6["Restore CR\nmetadata fetch only\nPVC data already present"]
    C7["App running\nat DR URL\n⚡ reduced RTO"]
    C1 --> C2 --> C3 --> C4 --> C5 --> C6 --> C7
  end

  subgraph Post ["Post-Restore  (both paths)"]
    direction LR
    P1["Route hostname\ntransform applied\n(transformComponents)"]
    P2["MySQL wp_options\nURL rewrite\n(Hook CR or direct exec)"]
    P3["WordPress\naccessible\nat DR URL ✓"]
    P1 --> P2 --> P3
  end

  B4 --> Post
  C7 --> Post
```

---

## Where Ansible Fits

Ansible handles all **imperative operations** — things that are triggered by a human decision
(DR test, annual exercise, on-demand backup) rather than Git state.

```mermaid
flowchart LR
  subgraph Playbooks ["Ansible Playbooks  (ansible-navigator run)"]
    direction TB
    PV["validate-trilio.yaml\nPre-flight health check\nCSV · TVM · License · pods"]
    PB["dr-backup.yaml\nCreate Backup CR\npoll to Available"]
    PR["dr-restore.yaml\nCreate Restore CR\nbuild/location/consistentset\npoll to Completed"]
    PE["enable-continuous-restore.yaml\nDiscover spoke instanceID\nCreate CR BackupPlan\n+ ContinuousRestore Policy"]
  end

  Operator(["👤 Operator\nor CI/CD pipeline"])

  Operator -->|"pre-flight check"| PV
  Operator -->|"scheduled or\non-demand backup"| PB
  Operator -->|"DR event declared\nor annual DR test"| PR
  Operator -->|"one-time setup\nper DR cluster"| PE

  PV -->|"✓ cluster healthy"| Hub["Hub Cluster"]
  PB -->|"Backup CR → Available"| Hub
  PR -->|"Restore CR → Completed\nWordPress live at DR URL"| Spoke["DR Cluster"]
  PE -->|"CR BackupPlan → Available"| Hub
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| OLM for operators, Helm for operands | OpenShift best practice; OLM manages upgrades and RBAC |
| Secrets via Vault → ESO, never in Git | Credentials rotate in Vault; all clusters pick them up automatically |
| Sync-wave split (trilio-secrets / trilio-operand) | Trilio admission webhook requires credential Secrets before BackupTarget is accepted |
| CR BackupPlan is Ansible-owned (not ArgoCD-managed) | Requires runtime-discovered spoke instanceID — same accepted pattern as the License Job |
| Post-restore URL rewrite via direct exec (ConsistentSet path) | Hook CR support for ConsistentSet restores is a planned enhancement (Req 7a) |
| `wordpress-restore` namespace pre-provisioned on all clusters | No manual prep required when DR is declared; namespace and Hook CR already exist |
