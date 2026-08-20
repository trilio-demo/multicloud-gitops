# Session State — Full Archaeology

Backward-looking record: what got done thread-by-thread, decisions articulated, ruled-out paths.
The forward-looking brief lives in `CLAUDE.md` — read that first.

---

## 2026-08-19 — Req 17: DC6 Teardown Complete

### Thread 1 — Establishing whether Req 17 was still outstanding

Asked whether a teardown task was still open for DC6/DC12. Confirmed from `PRD.md` (matrix row 17,
detail block) that Req 17 was `Not Started`, P0, with Req 18 blocked behind it.

Then checked live state rather than trusting memory, which said "consider them gone" as of
2026-08-14. Memory was half right:

- **DC6:** still fully deployed. Pattern CR `dallas-multicloudops` present, `targetRevision: dallas`,
  8 healthy ArgoCD Applications, Trilio 5.3.1 TVM `Updated`, imperative CronJobs still ticking
  (and failing, since the spoke was gone).
- **DC12:** unreachable. `dial tcp 172.31.0.33:6443: i/o timeout`, no ICMP reply. dc6 (172.31.0.19)
  answered fine from the same `/24`, so this was the host being down, not a VPN or routing problem.
  Vince confirmed he had released DC12 to the lab team a month prior and they had reclaimed it.

### Thread 2 — A wrong reading, corrected

Initially reported DC6 as being in a "half-state" with zero ArgoCD Applications. That was a bad
query: bare `oc get applications` resolves to ACM's `applications.app.k8s.io`, not
`applications.argoproj.io`. Qualified, all 8 apps were present and healthy. Corrected before any
action was taken. Written up in `Learnings.md`.

Also discovered the Vault root token was already unrecoverable: `vaultkeys` absent from `imperative`
(that namespace had zero secrets), and no `vault.init` / `pattern-vault.init` on local disk. Vault-0
was up and `Sealed: false` only because it had not restarted in 174 days. This killed both the
documented "save the token before offboard" step and the playbook's `clean_vault` step.

### Thread 3 — Planning, and the naming discrepancy

Found that the live deployment predated the Req 15 rename entirely. PRD Req 17 assumed ArgoCD
namespaces `dallas-trilio-continuous-restore-{hub,secondary}`; reality was pattern
`dallas-multicloudops`, namespace `dallas-multicloudops-hub`. The offboard playbooks default to
`main-trilio-continuous-restore-*`, and because their ArgoCD steps use `ignore_errors`, wrong values
would have failed silently and left ArgoCD live through the operator removal.

Recommended sequence: delete Pattern CR → unlabel → playbook with overrides → force-strip
`dr-cluster` finalizers → delete leftover namespaces → verify. Flagged Vault namespace deletion as
the one irreversible call needing explicit confirmation.

### Thread 4 — Execution, and an overreach

Vince approved the teardown. Executed in this order:

1. **Deleted Pattern CR `dallas-multicloudops`.** This was the overreach. The
   `foregroundDeletePattern` finalizer runs the operator's *own* teardown, which cascade-deletes
   **all** child apps — including `acm`, `vault` and `golang-external-secrets`. Had told Vince those
   three were preserved, which is true of `offboard-hub.yaml` but **not** of the operator finalizer.
   Result: MultiClusterHub went to `Uninstalling`, Vault pods deleted. Reported immediately rather
   than after the fact. Recommended letting it finish — a half-uninstalled MCH is worse than a
   removed one, and Req 18 recreates all three as child apps, so the requested endpoint was
   unchanged. Vince did not ask for it to be arrested.

2. **Pattern CR stalled at `DeleteSpokeChildApps`**, looping on four
   `dallas-multicloudops-group-one` apps "in dr-cluster" that could never be verified gone. Note
   that namespace does not exist on the hub, so the apps were invisible to
   `oc get applications.argoproj.io -A` — only ACM could see them. This also corrected an earlier
   claim that nothing spoke-related remained on the hub.
   Fixed by unlabelling and deleting ManagedCluster `dr-cluster`. All six ACM cleanup finalizers
   resolved on their own — the anticipated `manifestwork-cleanup` hang did not materialise, so no
   force-strip was needed.

3. **ACM uninstall then wedged** across a five-link chain: `acm` app → MCH → MCE →
   `ManagedCluster/local-cluster` → `managedclusteraddon/config-policy-controller`, stuck on
   `addon.open-cluster-management.io/addon-pre-delete`. That hook needs an addon agent the uninstall
   had already removed. MCH sat in `Uninstalling` with only its own operator pods left, which looks
   like progress but is not. Diagnosed by reading the **MCE** operator log — MCH only says "MCE has
   not yet been terminated", while MCE names the actual blocker. Stripped the single finalizer and
   the chain unwound in ~2 minutes.

4. **Ran `offboard-hub.yaml`** with `--skip-tags preflight`,
   `hub_app_of_apps`/`hub_child_app_namespace=dallas-multicloudops-hub`, `clean_vault=false`.
   `ok=20 changed=8 failed=0`. Cleared finalizers off two stuck Trilio CRs
   (`licenses/trilio-license`, `restores/imperative-restore-20260407-01h38`), deleted the
   validating/mutating webhooks and all 16 Trilio CRDs. By this point the operator cascade had
   already removed the Subscription, CSV, all Trilio CRs, and the `dallas-multicloudops-hub`,
   `wordpress` and `golang-external-secrets` namespaces, so most steps were no-ops.

### Verified end state

No Pattern CRs, no ArgoCD Applications, 0 Trilio CRDs, all pattern namespaces gone, nothing stuck
Terminating cluster-wide, Vault namespace + PVC + PV fully removed with no orphaned or Released PVs.
`patterns-operator` v0.0.65, `openshift-gitops-operator` v1.18.3 (8/8 pods Running) and ODF
`ocs-storagecluster` Ready — all retained and healthy.

Snapshots captured pre and post in the session scratchpad (`pre-teardown.txt`, `post-teardown.txt`);
those are ephemeral and not preserved in the repo.

### Decisions articulated

- **Let the ACM cascade complete rather than arrest it.** Half-uninstalled MCH is a worse state than
  removed, and Req 18 reinstalls ACM as a child app regardless.
- **Left 66 ACM/MCE/Hive CRDs and the empty `hive` namespace in place.** Both ACM and MCE CSVs are
  gone; only CRDs remain. A fresh `main` deploy reconciles them. Deleting 66 CRDs is invasive and was
  not required by the ask — offered to Vince as a follow-up rather than done unilaterally.
- **Skipped `make offboard-spoke` entirely.** It requires the spoke context; DC12 was gone. Its
  hub-side work turned out to be unnecessary once `dr-cluster` was deleted.
- **Did not commit the doc updates.** Repo convention is to commit only when asked, and `main` is the
  default branch.

### Ruled out

- Force-stripping `dr-cluster`'s six ACM finalizers — prepared for it, proved unnecessary.
- Preserving Vault. Its root token and unseal keys were already lost, so the data was written off
  before teardown started; the PVC and PV went with the namespace.
- Recovering the Vault root token from local disk — no `vault.init` or `pattern-vault.init` existed
  (both are gitignored, neither was present).

### Playbook defects logged for Req 18

1. Preflight `Check for active secondary spoke clusters` has no `failed_when`/`ignore_errors` and
   hard-fails once the `ManagedCluster` CRD is absent.
2. Step 1 deletes ManagedClusters with plain `state: absent` — no finalizer force-strip, despite the
   header promising that treatment for Applications and Trilio CRs.
3. `pattern_namespaces` omits `<branch>-<pattern>-hub`, orphaning the pattern's ArgoCD namespace and
   instance on a playbook-only teardown.

All three written up in `Learnings.md` alongside the Pattern-CR cascade, the `DeleteSpokeChildApps`
stall, the `addon-pre-delete` chain, and the `oc get applications` CRD ambiguity.

---

## 2026-08-19 (same session, later) — ODF Storage System Removal on DC6

### Context

Vince decided to destroy the DC6 cluster entirely and rebuild it later. Removing the ODF storage
system first makes the destroy cleaner — no stale container volumes left behind in the vSphere host
VM infrastructure. Two explicit asks: find any finalizers that would prevent deletion and remove
them, and observe whether the storage capacity is actually reclaimed.

### Thread 5 — Survey first

The survey reframed the task. The OSD device sets and mons were backed by `thin-csi` PVCs — vSphere
VMDKs, not local disks:

- 3 × 512Gi OSD devicesets + 3 × 50Gi mons = **1,686Gi of VMDKs**
- 2 PVCs on `ocs-storagecluster-ceph-rbd` (noobaa db 50Gi, `simple-project/test-pvc` 1Gi) living
  inside Ceph

`thin-csi` reclaimPolicy was `Delete`, and the StorageCluster already carried
`uninstall.ocs.openshift.io/cleanup-policy: delete` + `mode: graceful`. So a graceful teardown would
delete the VMDKs on its own.

Recorded all six vSphere `volumeHandle` values as the baseline for the capacity question before
touching anything.

### Thread 6 — The finalizer ask, answered by declining to act

Surveyed finalizers across 15 ODF CRs. Every one carried exactly one finalizer, and **all were live
operator finalizers, none stale**. Same for the PV layer:
`external-provisioner.volume.kubernetes.io/finalizer` and
`external-attacher/csi-vsphere-vmware-com`.

Those finalizers *are* the cleanup mechanism — they drive the detach-and-delete in vSphere. Removing
them would have deleted the Kubernetes objects while orphaning the VMDKs, producing exactly the
stale-volume outcome the request was trying to prevent. So the finalizer request was answered by
explaining why nothing should be stripped, and stripping nothing. **Zero finalizer intervention was
needed for the entire teardown.**

### Thread 7 — Execution

1. Deleted `simple-project/test-pvc` (no pod consumer) — `mode: graceful` blocks while consumers
   outside `openshift-storage` exist. PVC and PV both reclaimed immediately, confirming the
   provisioner path was healthy.
2. Deleted the StorageSystem. The entire CR tree collapsed in ~15s via owner references —
   StorageCluster, CephCluster, block pools, filesystems, object stores, noobaa, all gone.
3. The six thin-csi PVs then sat in `Released` (reclaim=Delete, no deletionTimestamp, claimRef still
   set) for about a minute. Verified this was in-flight work rather than a stall:
   `oc get volumeattachment` was empty and all Ceph/OSD/mon pods were gone, so the volumes were
   detached. Cause of the delay was a `vmware-vsphere-csi-driver-controller` pod restarting at the
   moment of deletion and dropping its work queue.
4. It recovered on retry; the csi-provisioner logged `DeleteVolume` for all six handles by name and
   removed the PV objects.

### Verified end state

0 PVs, 0 PVCs, 0 ODF CRs of any kind, no VolumeAttachments. All four ODF storage classes removed
themselves; only `thin-csi` remains. **Vince independently confirmed in vSphere that the container
volumes are gone** — the capacity question is answered affirmatively by direct observation, not just
by Kubernetes object state.

### Decisions articulated

- **Stripped no finalizers, contrary to the literal request.** Explained why in-line: the finalizers
  were the thing making the VMDK deletion happen. The stated goal (no stale volumes) was better
  served by leaving them alone.
- **Did not intervene during the `Released` window.** Force-stripping the PV finalizers in that
  minute would have orphaned 1.65 TiB in vSphere. Verified detachment and provisioner activity
  instead, then waited.
- **Left the ODF operators and `openshift-storage` namespace installed.** 12 CSVs, 8 operator pods.
  Harmless given the cluster is being destroyed; the volumes were the whole point. Offered as a
  follow-up, not done unilaterally.

### Worth carrying forward

- The vSphere CSI controller on this platform was already unstable: one pod at 12 restarts, its peer
  at 1028 over 175 days. Check restart counts before a storage teardown here.
- Removing ODF removes the default StorageClass. `ocs-storagecluster-ceph-rbd` held the default flag;
  `thin-csi` is not marked default. Anything provisioning before ODF is reinstalled will fail to bind.
