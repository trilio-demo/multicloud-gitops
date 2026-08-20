# CLAUDE.md — Trilio GitOps Pattern

## Session Continuity

This user closes VSCode and CC CLI frequently and **never rejoins sessions**. Every new conversation starts cold. When you detect a session-end signal, sync memory before responding with a farewell.

**Session-end phrases:** "that's it for the day", "good session, nite", "stopping point", or any clear sign-off.

---

## Session State (updated 2026-08-19)

**Last session headline:** Req 17 done — DC6 hub torn down and verified clean, then ODF removed and
1.65 TiB of vSphere VMDKs reclaimed (confirmed in vSphere by Vince). DC12 was reclaimed by the lab
team. **DC6 is being destroyed and rebuilt later.**

**No live clusters exist for this pattern right now.** Anything that assumes a running hub is stale.

### Open items — carried
- **Req 18 is the next real work:** fresh deploy of hub + spoke from `main`, then full E2E imperative
  automation to green. First live test of the Req 15 renames — expect ArgoCD namespaces
  `main-trilio-continuous-restore-{hub,secondary}` and `clusterGroup=secondary` on the spoke.
- **Need a hub cluster and a spoke cluster assigned** before Req 18 can start. DC6 is slated for
  destroy + rebuild, so it is not available until rebuilt; no spoke identified yet. **Settle this
  first — nothing else in Req 18 can proceed without it.**
- **Fix three `offboard-hub.yaml` defects** found during the DC6 teardown (details in `Learnings.md`):
  preflight hard-fails when the `ManagedCluster` CRD is absent; no ManagedCluster finalizer
  force-strip in step 1; `pattern_namespaces` omits `<branch>-<pattern>-hub`.
- **DC6 leftovers now moot** — the cluster is being destroyed. For the record it still had 66
  ACM/MCE/Hive CRDs, an empty `hive` namespace, and the ODF operators + `openshift-storage` namespace
  (12 CSVs, 8 pods) installed with no StorageSystem.
- **On the DC6 rebuild:** removing ODF removed the default StorageClass. Reinstall ODF before
  anything needs to provision, or set a default explicitly — `thin-csi` is not marked default.
- **Req 8 (OCP Virt VM workload)** still deferred.

### Next-session pickup
1. Confirm which clusters are assigned for hub and spoke.
2. Fix the three offboard playbook defects before deploying, so teardown works next time.
3. Deploy hub from `main` via the VP operator. Secrets go to Vault manually — `make install` /
   `rhvp.cluster_utils` are not used in this project.
4. Onboard the spoke, then run the imperative E2E chain to green.

### Continuity reminders
- Vault root token and unseal keys were **lost** on the old DC6 deployment (`vaultkeys` gone, no
  `vault.init` on disk). On the next deploy, save both immediately after init.
- **Uncommitted doc updates from 2026-08-19 sit in the working tree** (`PRD.md`, `Learnings.md`,
  `CLAUDE.md`, `docs/session-state.md`, plus new `docs/`) — never committed. Commit these before
  starting new work, or the Req 17 + ODF write-ups exist only on local disk.
- Do not trust `oc` contexts named `ocp-dc6` after the rebuild — the cluster will be new.

Full archaeology: `docs/session-state.md` — consult when prior-thread depth, decision reasoning, or
ruled-out paths are needed.

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

## PRD Implementation Status (as of 2026-08-19)
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
| 11 | Document.md usage manual | Done |
| 12 | Imperative framework E2E automation | Done |
| 13 | VP uninstall teardown validation | Done |
| 14 | Remove multicloud-gitops upstream overhead | Done |
| 15 | Rename pattern + cluster groups | Done |
| 16 | Publish to trilio-continuous-restore repo | Done |
| 17 | Teardown `dallas`-branch clusters (DC6 hub + DC12 spoke) | Done 2026-08-19 |
| 18 | Fresh deploy from `main`; validate Req 15 renames live; E2E to green | **Next** |

## Key Gotchas (read before editing)
- **Vault secrets must be plain text** — ESO handles base64 encoding. Pre-encoded values cause double-encoding and break the BackupTarget (stays `Failed`).
- **TrilioVaultManager healthy states:** both `Deployed` AND `Updated` are healthy. Playbooks must accept either.
- **`global.localClusterName`** (not `global.clusterName`) is the correct VP variable for the cluster name in values files.
- **Restore namespace** is set by `metadata.namespace` on the Restore CR, not a `restoreNamespace` field.
- **`kubectl explain restore.spec`** returns ACM's CRD by default — always qualify: `--api-version=triliovault.trilio.io/v1`
- **Ingress domain from cluster** already includes `apps.` — Route hostname = `{{ restore_namespace }}.{{ ingress_domain }}` (no extra `.apps.`)
- **ArgoCD uses `helm template`** (not `helm install`) so no Helm release Secrets exist. Trilio won't discover apps as "Helm apps" in UI — this is expected and does not affect backup.
- **License Job is a one-shot workaround** for Helm's inability to reference runtime ESO-created secrets. This is an accepted pattern.
- **Deleting the Pattern CR cascades wider than `offboard-hub.yaml`** — its `foregroundDeletePattern` finalizer removes *all* child apps including `acm`, `vault` and `golang-external-secrets`. The playbook preserves those three; the operator does not. Delete the Pattern CR only when you want the pattern gone completely.
- **`oc get applications` resolves to ACM's CRD, not ArgoCD's** — same trap as the Trilio CRDs. Always `oc get applications.argoproj.io -A`, or a healthy deployment reads as empty.
- **ACM uninstall wedges on `addon-pre-delete`** — chain is `acm` app → MCH → MCE → `ManagedCluster/local-cluster` → `managedclusteraddon/config-policy-controller`. Strip that finalizer to unblock. Read the **MCE** log, not MCH's, to find the real blocker.
- **Removing ODF: never pre-strip finalizers** — the ODF/Ceph/noobaa CR finalizers and the PV `external-provisioner` / `external-attacher/csi-vsphere-vmware-com` finalizers *are* what deletes the backing vSphere VMDK. Stripping them orphans the volume. The `Released` PV phase is normal in-flight work; verify `oc get volumeattachment` is empty and wait.
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
1. All changes committed to Git on branch `main`
2. ArgoCD picks up changes automatically (no manual `helm upgrade`)
3. Use `ansible-navigator run ansible/playbooks/<playbook>.yaml` for DR operations
4. Validate with `ansible/playbooks/validate-trilio.yaml` before and after changes
5. Update `PRD.md` matrix when requirements are completed or status changes

## Active Branch
`main` — canonical since Req 15 merge (c9ed7d2). `dallas` kept for posterity only.
