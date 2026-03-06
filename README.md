# Red Hat Validated Pattern: Disaster Recovery with Trilio

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A GitOps-driven Disaster Recovery solution for OpenShift using [Trilio for Kubernetes](https://docs.trilio.io/kubernetes/), built on the [Red Hat Validated Patterns](https://validatedpatterns.io/) framework.

## Overview

This pattern automates the full lifecycle of Trilio DR capabilities across OpenShift clusters:

- **Operator installation** via OLM (Operator Lifecycle Manager)
- **Operand deployment** (TrilioVaultManager CR) via Helm
- **License management** via HashiCorp Vault + External Secrets Operator
- **Continuous delivery** via ArgoCD / OpenShift GitOps
- **Validation** via Ansible playbooks

## Architecture

```mermaid
graph TD
    subgraph Git["Git Repository (Source of Truth)"]
        values["values-hub.yaml\nvalues-group-one.yaml"]
        charts["charts/all/trilio-operand/\n  - TrilioVaultManager CR\n  - License Job + RBAC\n  - ExternalSecret"]
    end

    subgraph Hub["Hub Cluster"]
        ACM["ACM\nAdvanced Cluster Management"]
        ArgoCD["ArgoCD\nOpenShift GitOps"]
        Vault["HashiCorp Vault\n(License Key store)"]
        ESO["External Secrets\nOperator (ESO)"]
        OLM_Hub["OLM\nTrilio Subscription"]
        TVM_Hub["TrilioVaultManager\nOperand (Hub)"]
        Job["License Job\n(one-time bootstrap)"]
        LicenseCR["License CR\n(Trilio licensed)"]
        Secret["Secret: trilio-license\n(from Vault via ESO)"]
    end

    subgraph Spoke["Spoke Cluster (group-one)"]
        OLM_Spoke["OLM\nTrilio Subscription"]
        TVM_Spoke["TrilioVaultManager\nOperand (Spoke)"]
        ESO_Spoke["External Secrets\nOperator"]
    end

    Git -->|GitOps sync| ArgoCD
    ArgoCD -->|Manages| OLM_Hub
    ArgoCD -->|Deploys| TVM_Hub
    ArgoCD -->|Deploys| Job
    ArgoCD -->|Deploys| ESO

    Vault -->|License key| ESO
    ESO -->|Creates| Secret
    Job -->|Reads| Secret
    Job -->|Creates| LicenseCR
    LicenseCR -->|Activates| TVM_Hub

    ACM -->|Propagates policy| Spoke
    ArgoCD -->|Syncs spoke apps| OLM_Spoke
    ArgoCD -->|Syncs spoke apps| TVM_Spoke
    ESO_Spoke -->|Pulls secrets| Vault
```

### Component Roles

| Component | Role |
|-----------|------|
| **OLM Subscription** | Installs `k8s-triliovault` operator from certified-operators catalog |
| **TrilioVaultManager CR** | Operand that configures Trilio data protection services |
| **ExternalSecret** | Pulls Trilio license key from Vault path `secret/global/trilio-license` |
| **License Job** | One-time bootstrap Job that creates the `License` CR from the ESO-managed Secret |
| **ArgoCD** | Continuous delivery — syncs all Helm charts to hub and spoke clusters |
| **ACM** | Manages spoke cluster membership and propagates subscriptions |

## Prerequisites

- OpenShift 4.x (hub + optional spoke clusters)
- OpenShift GitOps (ArgoCD) installed on hub
- Advanced Cluster Management (ACM) installed on hub
- HashiCorp Vault accessible from the cluster
- External Secrets Operator deployed
- Trilio license key stored in Vault at `secret/global/trilio-license` with property `key`

## Deployment

### 1. Clone and configure secrets

```bash
git clone <this-repo>
cp values-secret.yaml.template values-secret.yaml
# Edit values-secret.yaml and populate your Vault token / license key
```

### 2. Store the license in Vault

```bash
vault kv put secret/global/trilio-license key="<your-trilio-license-key>"
```

### 3. Deploy the pattern

```bash
./pattern.sh make install
```

ArgoCD will:
1. Install the Trilio operator via OLM Subscription
2. Deploy the TrilioVaultManager CR
3. Sync the ExternalSecret → Secret from Vault
4. Run the License Job to create the License CR

### 4. Validate

```bash
# Check Trilio operator
oc get csv -n trilio-system | grep trilio

# Check TrilioVaultManager
oc get triliovaultmanager -n trilio-system

# Check License CR
oc get license -n trilio-system

# Run Ansible validation
ansible-playbook ansible/playbooks/validate-trilio.yaml
```

## DR Workflows

### Backup a namespace

```bash
ansible-playbook ansible/playbooks/dr-backup.yaml \
  -e target_namespace=my-app \
  -e backup_name=my-app-backup-01 \
  -e s3_target=my-s3-target
```

### Restore from a backup

```bash
ansible-playbook ansible/playbooks/dr-restore.yaml \
  -e source_backup=my-app-backup-01 \
  -e restore_name=my-app-restore-01 \
  -e restore_namespace=my-app
```

See [ansible/playbooks/](ansible/playbooks/) for full playbook documentation.

## Repository Structure

```
.
├── charts/all/trilio-operand/     # Helm chart: TVM CR, License Job, RBAC, ExternalSecret
├── ansible/
│   ├── site.yaml                  # RHPDS bootstrap playbook
│   └── playbooks/
│       ├── validate-trilio.yaml   # Validates Trilio operator, TVM, and license
│       ├── dr-backup.yaml         # Creates BackupPlan + triggers Backup CR
│       └── dr-restore.yaml        # Triggers Restore CR from a given Backup
├── values-hub.yaml                # Hub cluster: subscriptions, applications, namespaces
├── values-group-one.yaml          # Spoke cluster: subscriptions, applications
├── values-global.yaml             # Global defaults
├── values-secret.yaml.template    # Secret management template
├── overrides/                     # Cloud-provider overrides (AWS, IBMCloud)
├── tests/interop/                 # Pytest integration tests
├── PRD.md                         # Product Requirements Document
├── Divergence.md                  # PRD vs implementation gap tracker
└── Learnings.md                   # Key insights and best practices
```

## Troubleshooting

### Trilio operator not installing

**Symptom**: `oc get csv -n trilio-system` returns nothing or shows `Pending`.

**Check**:
```bash
oc get subscription k8s-triliovault -n trilio-system -o yaml
oc get installplan -n trilio-system
oc get events -n trilio-system --sort-by='.lastTimestamp'
```

**Common causes**:
- `certified-operators` CatalogSource is not healthy: `oc get catalogsource -n openshift-marketplace`
- OperatorGroup missing or misconfigured: `oc get operatorgroup -n trilio-system`
- The namespace needs `operatorGroup: true` in `values-hub.yaml` / `values-group-one.yaml`

---

### TrilioVaultManager stuck in `Reconciling`

**Symptom**: `oc get triliovaultmanager -n trilio-system` shows status `Reconciling` indefinitely.

**Check**:
```bash
oc describe triliovaultmanager triliovault-manager -n trilio-system
oc logs -l app=k8s-triliovault -n trilio-system --tail=50
```

**Common causes**:
- License CR is missing or invalid — see License section below
- Insufficient cluster resources for `dataJobResources` / `metadataJobResources`
- Ingress controller conflicts — chart disables it by default (`ingress-controller.enabled: false`)

---

### License CR not created

**Symptom**: `oc get license -n trilio-system` returns nothing. TVM shows unlicensed.

**Diagnosis flow**:
```bash
# 1. Check the ExternalSecret synced the Secret
oc get externalsecret trilio-license -n trilio-system -o jsonpath='{.status.conditions}'
oc get secret trilio-license -n trilio-system

# 2. Check the License Job ran
oc get job trilio-license-job -n trilio-system
oc logs job/trilio-license-job -n trilio-system

# 3. Check Vault connectivity
oc get clustersecretstore vault-backend -o yaml
```

**Common causes**:
- Vault is unreachable or the path `secret/global/trilio-license` does not exist
- The `ClusterSecretStore` named `vault-backend` is not Ready
- The License Job RBAC is missing — ensure the `Role` and `RoleBinding` are deployed

---

### ArgoCD application out of sync

**Symptom**: `trilio-operand` application shows `OutOfSync` in ArgoCD UI.

**Check**:
```bash
oc get application trilio-operand -n openshift-gitops -o yaml | grep -A10 status
```

**Common causes**:
- Helm template rendering error (check Events tab in ArgoCD UI)
- `values-group-one.yaml` `argoProject` mismatch — must be `trilio-operand`
- The Job has `ttlSecondsAfterFinished` not set, causing drift detection on completed Jobs

---

### Backup fails to complete

**Symptom**: `oc get backup -n my-app` shows `Failed` or stays in `InProgress`.

**Check**:
```bash
oc describe backup <backup-name> -n my-app
oc logs -l triliovault.trilio.io/component=data-mover -n trilio-system --tail=100
```

**Common causes**:
- S3 target unreachable or credentials invalid
- PVC is not bound or CSI driver not supported
- BackupPlan references a Target that is not in `Available` status: `oc get target -n trilio-system`

## References

- [Red Hat Validated Patterns](https://validatedpatterns.io/)
- [Trilio for Kubernetes Documentation](https://docs.trilio.io/kubernetes/)
- [External Secrets Operator](https://external-secrets.io/)
- [OLM Operator Lifecycle Manager](https://olm.operatorframework.io/)
