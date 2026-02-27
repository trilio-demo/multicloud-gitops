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
Add new learnings and insights here as the pattern evolves.
