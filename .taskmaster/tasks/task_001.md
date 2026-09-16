# Task ID: 1

**Title:** Lock in process discipline before any code

**Status:** done

**Dependencies:** None

**Priority:** high

**Description:** Establish the governance rule that determined every historical success/failure researched: small aligned team, real running code always paired with any formal rule, never policy accumulated ahead of implementation.

**Details:**

Grounded in the Multics/OSI/Palladium/CORBA vs WASM/LLVM/HTTP/Kubernetes-CRD research: OSI failed because ISO ratified paper designs before any implementation existed ('too risky and untested' rejection of a working 1975 proposal); IETF's 'rough consensus and running code' was coined directly against this. CORBA is the sharpest warning: it started with real running code and small ambition and STILL failed, because its mechanism didn't stay small - it ballooned into committee-driven policy (naming/trading/notification services, security, versioning all bolted on). The rule for this project: (1) a small, aligned group who will each actually ship code decides Layer 0's design, never a broad multi-stakeholder process; (2) no formal rule for Layer 0 ever exists as spec-only - working, tested code implementing it ships in the same cycle, no exceptions, ever; (3) expect and budget for the first version of any extension mechanism to need real revision once real usage exposes what's wrong (the ThirdPartyResources to CRD lesson) - that's healthy, not failure.

**Test Strategy:**

See subtask-level test strategy; each subtask must ship with real, running, tested code in the same cycle as any formal rule it implements — never spec-only.

## Subtasks

### 1.1. Define and document the 'no spec without running code' rule

**Status:** done  
**Dependencies:** None  

Write the actual project-level rule (e.g. in a CONTRIBUTING or CLAUDE.md-equivalent doc) that no Layer 0 formal rule may be merged without a working, tested implementation in the same change.

**Details:**

This is the single variable that separated every historical success from every failure researched. Write it down where it can't be quietly bypassed under time pressure.

### 1.2. Establish the small-aligned-group governance model for Layer 0 changes

**Status:** done  
**Dependencies:** None  

Define who can propose/approve changes to Layer 0 specifically, keeping the group small and requiring each approver to have actually implemented against the change.

**Details:**

Mirrors WASM's CG (four browser vendors, each shipping) vs OSI's sprawling committee; mirrors IETF's running-code requirement for standards-track advancement.
