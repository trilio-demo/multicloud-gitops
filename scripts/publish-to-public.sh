#!/usr/bin/env bash
# publish-to-public.sh
#
# Copies the public-facing files from this working repo to a clean local
# directory suitable for publication as the trilio-continuous-restore repo.
#
# Usage:
#   ./scripts/publish-to-public.sh [TARGET_DIR]
#
# Default target: ~/Development/trilio-continuous-restore-publish
#
# After running, review the target directory then:
#   cd <TARGET_DIR>
#   git init -b main
#   git add -A
#   git commit -m "Initial release of Trilio Continuous Restore Validated Pattern"
#   git remote add origin <new-repo-url>
#   git push -u origin main
#
# Safe to re-run — target directory is wiped and rebuilt each time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${1:-$HOME/Development/trilio-continuous-restore-publish}"

# ---------------------------------------------------------------------------
# Whitelist — only these files reach the public repo
# ---------------------------------------------------------------------------
COPY_FILES=(
  # Pattern framework
  values-global.yaml
  values-hub.yaml
  values-secondary.yaml
  values-4.20-hub.yaml
  values-4.20-secondary.yaml
  values-4.21-hub.yaml
  values-4.21-secondary.yaml
  values-secret.yaml.template
  pattern-metadata.yaml
  pattern.sh
  Makefile
  Makefile-common
  ansible.cfg

  # Documentation
  README.md
  Document.md
  LICENSE

  # Linting / security scanning config
  .ansible-lint
  .trivyignore
)

COPY_DIRS=(
  charts
  ansible
  tests
  overrides
)

# ---------------------------------------------------------------------------
# Forbidden files — script aborts if any of these end up in the target
# ---------------------------------------------------------------------------
FORBIDDEN_FILES=(
  CLAUDE.md
  PRD.md
  Learnings.md
  Divergence.md
  Prompt.md
  Team.md
  OVERVIEW.md
  values-secret.yaml
  trilio-gitops.code-workspace
)

# ---------------------------------------------------------------------------
echo "=== Trilio Continuous Restore — publish to public repo ==="
echo "Source : $SOURCE_DIR"
echo "Target : $TARGET_DIR"
echo ""

# ---------------------------------------------------------------------------
# Wipe and recreate target
# ---------------------------------------------------------------------------
echo "→ Wiping target directory..."
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"

# ---------------------------------------------------------------------------
# Copy whitelisted files
# ---------------------------------------------------------------------------
echo "→ Copying files..."
for f in "${COPY_FILES[@]}"; do
  src="$SOURCE_DIR/$f"
  dst="$TARGET_DIR/$f"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "   copied: $f"
  else
    echo "   WARN: $f not found in source — skipping"
  fi
done

# ---------------------------------------------------------------------------
# Copy whitelisted directories
# ---------------------------------------------------------------------------
for d in "${COPY_DIRS[@]}"; do
  src="$SOURCE_DIR/$d"
  dst="$TARGET_DIR/$d"
  if [[ -d "$src" ]]; then
    cp -r "$src" "$dst"
    echo "   copied dir: $d/"
  else
    echo "   WARN: $d/ not found in source — skipping"
  fi
done

# ---------------------------------------------------------------------------
# Write .gitignore
# ---------------------------------------------------------------------------
echo "→ Writing .gitignore..."
cat > "$TARGET_DIR/.gitignore" << 'EOF'
# Secrets — never commit
values-secret*
pattern-vault.init
vault.init

# Editor / OS
*.swp
*.swo
.*.expected.yaml
*.code-workspace
.DS_Store

# Claude (internal tooling)
CLAUDE.md
.claude/
EOF

# ---------------------------------------------------------------------------
# Write CLAUDE.md for the public repo
# ---------------------------------------------------------------------------
echo "→ Writing CLAUDE.md..."
cat > "$TARGET_DIR/CLAUDE.md" << 'EOF'
# CLAUDE.md — Trilio Continuous Restore Validated Pattern

## What This Repo Is
Red Hat Validated Pattern for Disaster Recovery with Trilio for Kubernetes on OpenShift.

- **Usage manual:** `Document.md`
- **Pattern name:** `trilio-continuous-restore`
- **Spoke cluster group:** `secondary`

## Key Architecture
- **Hub cluster:** ACM + Vault + ESO + ArgoCD + Trilio operator (OLM) + operand (Helm)
- **Spoke (secondary):** ESO + Trilio operator (OLM); trilio-operand chart deployed via ACM
- **Rule:** OLM installs operators; Helm manages operands (CRs). Never use Helm to install operators on OpenShift.
- **Secrets:** Never in Git. `values-secret.yaml` → Vault (via `make install`) → ESO → Kubernetes Secrets

## Critical File Locations
| What | Where |
|------|-------|
| Trilio operand Helm chart | `charts/all/trilio-operand/` |
| WordPress sample app chart | `charts/all/wordpress/` |
| Hub values | `values-hub.yaml` |
| Spoke values | `values-secondary.yaml` |
| Ansible DR backup playbook | `ansible/playbooks/dr-backup.yaml` |
| Ansible DR restore playbook | `ansible/playbooks/dr-restore.yaml` |
| Ansible validation playbook | `ansible/playbooks/validate-trilio.yaml` |
| Secret template | `values-secret.yaml.template` |

OLM Subscriptions are declared inline in values files — there are no standalone Subscription YAML files.

## Key Gotchas
- **Vault secrets must be plain text** — ESO handles base64 encoding. Pre-encoded values cause double-encoding and break the BackupTarget (stays `Failed`).
- **TrilioVaultManager healthy states:** both `Deployed` AND `Updated` are healthy. Playbooks must accept either.
- **`global.localClusterName`** (not `global.clusterName`) is the correct VP variable for the cluster name in values files.
- **Restore namespace** is set by `metadata.namespace` on the Restore CR, not a `restoreNamespace` field.
- **`kubectl explain restore.spec`** returns ACM's CRD by default — always qualify: `--api-version=triliovault.trilio.io/v1`
- **Ingress domain from cluster** already includes `apps.` — Route hostname = `{{ restore_namespace }}.{{ ingress_domain }}` (no extra `.apps.`)
- **ArgoCD app namespace naming:** `<branch>-trilio-continuous-restore-<group>` — on `main` this is `main-trilio-continuous-restore-hub` and `main-trilio-continuous-restore-secondary`
- **5.3.x does not follow S3 301 PermanentRedirect** — always set `backupTarget.region` to the actual bucket region.

## Development Workflow
1. All changes committed to Git on branch `main`
2. ArgoCD picks up changes automatically (no manual `helm upgrade`)
3. Use `ansible-navigator run ansible/playbooks/<playbook>.yaml` for DR operations
4. Validate with `ansible/playbooks/validate-trilio.yaml` before and after changes
EOF

# ---------------------------------------------------------------------------
# Sanity check — abort if any forbidden file is present
# ---------------------------------------------------------------------------
echo "→ Sanity check..."
FAIL=0
for f in "${FORBIDDEN_FILES[@]}"; do
  if [[ -e "$TARGET_DIR/$f" ]]; then
    echo "   ERROR: forbidden file found in target: $f"
    FAIL=1
  fi
done
if [[ $FAIL -eq 1 ]]; then
  echo ""
  echo "ABORT: internal files found in publish target. Review whitelist and re-run."
  exit 1
fi
echo "   OK — no internal files present"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=== Done ==="
echo ""
echo "Target: $TARGET_DIR"
echo ""
echo "Review, then publish:"
echo ""
echo "  cd $TARGET_DIR"
echo "  git init -b main"
echo "  git add -A"
echo "  git commit -m 'Initial release of Trilio Continuous Restore Validated Pattern'"
echo "  git remote add origin <new-repo-url>"
echo "  git push -u origin main"
