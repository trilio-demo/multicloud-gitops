# CLAUDE.md — Trilio GitOps Pattern

## What This Repo Is
Red Hat Validated Pattern for Disaster Recovery with Trilio on OpenShift.
- **Source of truth for requirements:** `PRD.md`
- **Known divergences / open issues:** `Divergence.md`
- **Architecture insights and gotchas:** `Learnings.md`

## Key Architecture
- **Hub cluster:** ACM + Vault + ESO + ArgoCD + Trilio operator (OLM) + operand (Helm)
- **Spoke (secondary):** ESO + Trilio operator (OLM); trilio-operand chart is hub-only
- **Rule:** OLM installs operators; Helm manages operands (CRs). Never use Helm to install operators on OpenShift.
- **Secrets:** Never in Git. `values-secret.yaml` → Vault (via `make install`) → ESO → Kubernetes Secrets

## Critical File Locations
| What | Where |
|------|-------|
| Trilio operand Helm chart | `charts/all/trilio-operand/` |
| WordPress sample app chart | `charts/all/wordpress/` |
| Hub values | `values-hub.yaml` |
| Spoke values | `values-secondary.yaml` |
| Ansible validation playbook | `ansible/playbooks/validate-trilio.yaml` |
| Ansible DR backup playbook | `ansible/playbooks/dr-backup.yaml` |
| Ansible DR restore playbook | `ansible/playbooks/dr-restore.yaml` |
| Secret template | `values-secret.yaml.template` |

OLM Subscriptions are declared inline in values files — there are no standalone Subscription YAML files.

## PRD Implementation Status (as of 2026-04-06)
| Req | Description | Status |
|-----|-------------|--------|
| 1 | Trilio via OLM + Helm | Done |
| 2 | WordPress + MySQL sample app | Done |
| 3 | BackupTarget CR (all clusters) | Done |
| 4 | BackupPlan with quiesce/unquiesce hooks | Done |
| 5 | Backup via Ansible playbook | Done |
| 6/6a | Restore + Route transform | Done |
| 6b | Post-restore MySQL Hook CR (wordpress-restore-hook) | Done (deployed via wordpress-restore Helm chart, Req 6c) |
| 6c | DR namespace pre-provisioning via GitOps | Done |
| 7 | Continuous Restore (EventTarget) | Done |
| 7a | hookConfig for ConsistentSet restores | Done (works in 5.3.x; imperative-cr-restore.yaml) |
| 8 | VM-based app (OCP Virt) | Deferred |
| 9 | Trilio 5.3.x upgrade | Done |
| 10 | Spoke onboarding OLM/ArgoCD race fix | Done |
| 11 | Document.md usage manual | Not Started |
| 12 | Imperative framework E2E automation | Done |
| 13 | VP uninstall teardown validation | Done |
| 14 | Remove multicloud-gitops upstream overhead | Done |
| 15 | Rename pattern + cluster groups | Not Started |
| 16 | Publish to trilio-continuous-restore repo | Not Started |

## Key Gotchas (read before editing)
- **Vault secrets must be plain text** — ESO handles base64 encoding. Pre-encoded values cause double-encoding and break the BackupTarget (stays `Failed`).
- **TrilioVaultManager healthy states:** both `Deployed` AND `Updated` are healthy. Playbooks must accept either.
- **`global.localClusterName`** (not `global.clusterName`) is the correct VP variable for the cluster name in values files.
- **Restore namespace** is set by `metadata.namespace` on the Restore CR, not a `restoreNamespace` field.
- **`kubectl explain restore.spec`** returns ACM's CRD by default — always qualify: `--api-version=triliovault.trilio.io/v1`
- **Ingress domain from cluster** already includes `apps.` — Route hostname = `{{ restore_namespace }}.{{ ingress_domain }}` (no extra `.apps.`)
- **ArgoCD uses `helm template`** (not `helm install`) so no Helm release Secrets exist. Trilio won't discover apps as "Helm apps" in UI — this is expected and does not affect backup.
- **License Job is a one-shot workaround** for Helm's inability to reference runtime ESO-created secrets. This is an accepted pattern.
- **Trilio admission webhook clones the Target Secret on Restore CR creation** — when `imperative-sa` (or any SA) submits a Restore CR, the `tvk-mutation.trilio.io` webhook clones the Target's S3 credential Secret into the restore namespace. The creating SA must have `secrets: create/patch/update` cluster-wide, not just on `trilio-system`. Missing this causes a `400 Bad Request` (not a `403`), making it hard to trace back to RBAC.

## Vault Operations Quick Reference
```bash
# Extract root token
VAULT_TOKEN=$(oc get secret vaultkeys -n imperative \
  -o jsonpath='{.data.vault_data_json}' | \
  base64 -d | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

# Write S3 credentials (plain text only)
oc exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN \
  vault kv put secret/global/trilio-s3 accessKey="..." secretKey="..."

# Force immediate ESO re-sync
oc annotate externalsecret trilio-s3-credentials -n trilio-system \
  force-sync=$(date +%s) --overwrite
```

## Development Workflow
1. All changes committed to Git on branch `dallas`
2. ArgoCD picks up changes automatically (no manual `helm upgrade`)
3. Use `ansible-navigator run ansible/playbooks/<playbook>.yaml` for DR operations
4. Validate with `ansible/playbooks/validate-trilio.yaml` before and after changes
5. Update `PRD.md` matrix when requirements are completed or status changes

## Active Branch
`dallas` — PRs target `main`
