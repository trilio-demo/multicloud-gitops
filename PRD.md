# Title
Red Hat Validated Pattern: Disaster Recovery with Trilio

# Product Requirements Document (PRD)

## Overview
This document defines the requirements for a new Red Hat Validated Pattern focused on Disaster Recovery (DR) using Trilio. The pattern must adhere to the best practices and standards established by the Red Hat Validated Patterns framework, ensuring repeatability, security, and operational excellence for OpenShift-based DR solutions.

## Objectives
- Deliver a fully automated, GitOps-driven DR solution for OpenShift clusters using Trilio.
- Ensure the pattern is modular, reusable, and aligns with the Validated Patterns methodology.
- Provide clear documentation, automation, and integration with common tools (ArgoCD, Helm, Ansible).
- Enable rapid deployment, testing, and validation of DR capabilities in enterprise environments.

## Requirements
### General
- Must follow the [Red Hat Validated Patterns best practices](https://github.com/validatedpatterns/multicloud-gitops#best-practices).
- All automation, configuration, and documentation must be delivered as code in Git.
- Pattern must be compatible with OpenShift 4.x and support multi-cluster topologies.
- All resources must be managed declaratively (GitOps-first approach).

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

## References
- [Red Hat Validated Patterns: multicloud-gitops](https://github.com/validatedpatterns/multicloud-gitops)
- [Red Hat Validated Patterns: config-demo](https://github.com/validatedpatterns/config-demo)
- [Trilio for Kubernetes Documentation](https://docs.trilio.io/kubernetes/)

## Acceptance Criteria
- Pattern deploys successfully via ArgoCD with minimal manual intervention.
- Trilio operator and operands are fully functional and licensed.
- DR workflows (backup, restore, failover) are automated and validated.
- Pattern passes all included Ansible validation playbooks.
- Documentation is complete and follows Validated Patterns standards.

## Implementation and Validation Matrix

| Requirement | Implementation | Validation/Test Evidence | Status |
|-------------|----------------|-------------------------|--------|
| Trilio operator installed via OLM Subscription | ACM policy or Subscription YAML | Confirmed operator pod running in target namespace; Subscription and CSV present | Validated |
| Trilio operand (TrilioVaultManager) installed via Helm | trilio-operand Helm chart (triliovaultmanager.yaml) | Helm release deployed; TVM CR present and reconciled | Validated |
| Trilio license Secret created from value | values.yaml, ESO/Secret manifest | Secret appears in trilio-system namespace with correct key | Validated |
| Trilio License CR created by Job when Secret exists | trilio-license-job.yaml, trilio-license-job-sa.yaml, trilio-license-job-role.yaml, trilio-license-job-rolebinding.yaml | Job runs, detects Secret, creates License CR; Trilio UI/API shows licensed | Validated |

> Update this table as new requirements are implemented and validated.

## Operator Installation and Operand Management

**Clarification:**
For OpenShift-based Validated Patterns, operators should be installed and managed using OLM (Operator Lifecycle Manager) via Subscription/OperatorGroup YAML or ACM policies. Helm should be used for deploying operands (the custom resources managed by operators) and other application resources. This approach aligns with both OpenShift best practices and Validated Pattern methodology, ensuring full GitOps compliance, upgradeability, and supportability.

---

*This PRD is intended for use by AI and human contributors to guide the development of a new Red Hat Validated Pattern for Disaster Recovery with Trilio. All contributions must adhere to the requirements and best practices outlined above.*
