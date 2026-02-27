# Divergence.md

## Purpose
This document tracks any significant divergence between the Product Requirements Document (PRD.md) and the actual implementation in this repository. Each entry should include:
- **PRD Reference**: The requirement or section in PRD.md
- **Observed Divergence**: What differs in the codebase or automation
- **Rationale/Context**: Why the divergence exists (if known)
- **Remediation Plan**: Steps to resolve, or justification for permanent divergence

---

## Current Divergence Log

### 1. PRD: Operator and Operand Management
- **PRD Reference**: Section "Operator Installation and Operand Management"; OLM for operators, Helm for operands
- **Observed Divergence**: No direct divergence observed. All operator installs are via OLM (ACM policy/Subscription), operands via Helm charts.
- **Rationale/Context**: N/A
- **Remediation Plan**: N/A

### 2. PRD: Trilio License Management
- **PRD Reference**: "Automate Trilio license management via integration with Vault and External Secrets Operator."
- **Observed Divergence**: License CR creation is handled by a Job, not directly by Helm or ESO. This is a workaround for Helm limitations with dynamic Secret-to-CR creation.
- **Rationale/Context**: Helm cannot create a CR from a Secret rendered by ESO in the same release; a Job is used to bridge this gap.
- **Remediation Plan**: 
	- Clearly document this workaround in the README and Learnings.md as an accepted pattern for dynamic resource creation.
	- Monitor Helm and ESO project updates for new features that could eliminate the need for this workaround.
	- If/when Helm or ESO support direct Secret-to-CR creation, refactor to remove the Job and simplify the flow.

### 3. PRD: Documentation
- **PRD Reference**: "Must include a comprehensive README with architecture diagrams, deployment steps, and troubleshooting."
- **Observed Divergence**: README.md exists, but may lack architecture diagrams and detailed troubleshooting.
- **Rationale/Context**: Initial focus was on automation and code; documentation can be expanded.
- **Remediation Plan**: 
	- Add architecture diagrams (e.g., PNG/SVG or Mermaid) to README.md to illustrate the pattern's components and flow.
	- Expand the troubleshooting section with common issues, error messages, and solutions.
	- Review PRD.md and ensure all documentation requirements are reflected in README.md.

### 4. PRD: Ansible Validation Playbooks
- **PRD Reference**: "Provide sample DR policies, backup/restore workflows, and validation playbooks."
- **Observed Divergence**: Ansible playbooks exist, but coverage of DR policies and backup/restore workflows may be limited.
- **Rationale/Context**: Playbooks focus on pattern validation, not full DR workflow automation.
- **Remediation Plan**: 
	- Develop additional Ansible playbooks to automate and validate DR scenarios, including backup and restore workflows.
	- Reference these playbooks in documentation and ensure they are tested as part of CI or manual validation.
	- Solicit feedback from users and stakeholders to prioritize playbook coverage and improvements.

---

> **Note:** Update this file whenever a new divergence is found or resolved. This ensures traceability and continuous alignment with the PRD.
