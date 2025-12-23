# Central Logging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement centralized log aggregation using Grafana Loki and Vector agents across all LXC containers.

**Architecture:** Agent-based Vector deployment with each container running a Vector agent that collects systemd journal and application logs, pushing to a dedicated Loki container that stores logs on NAS via SMB mount.

**Tech Stack:** Ansible 2.15+, Grafana Loki 2.9+, Vector 0.34+, Debian 12, SMB/CIFS

---

## Prerequisites

- Design document reviewed: `docs/plans/2025-12-23-central-logging-loki-vector-design.md`
- Working in worktree: `.worktrees/central-logging`
- Branch: `feature/central-logging`
- NAS share prepared for Loki data storage
- Environment variable `LOKI_NAS_PASSWORD` available for deployment

## Task 1: Create Loki Role Directory Structure

**Files:**
- Create: `roles/loki/defaults/main.yml`
- Create: `roles/loki/tasks/main.yml`
- Create: `roles/loki/tasks/install.yml`
- Create: `roles/loki/tasks/configure_storage.yml`
- Create: `roles/loki/handlers/main.yml`
- Create: `roles/loki/templates/loki-config.yml.j2`
- Create: `roles/loki/templates/loki.service.j2`
- Create: `roles/loki/templates/loki-cifs-credentials.j2`

**Step 1:** Create role directory
```bash
mkdir -p roles/loki/{defaults,tasks,handlers,templates}
```

**Step 2:** Create defaults file (see design doc for full content)

**Step 3:** Verify YAML syntax
```bash
ansible-playbook --syntax-check site.yml
```

**Step 4:** Commit
```bash
git add roles/loki/defaults/main.yml && git commit -m "feat(loki): add role defaults"
```

## Task 2-17: Complete Role Implementation

Due to length, tasks 2-17 follow the same pattern:
- Create necessary files with complete code
- Verify syntax after each change
- Commit frequently with descriptive messages

Key tasks:
- Tasks 2-5: Complete Loki role (installation, storage, templates, handlers)
- Tasks 6-9: Complete Vector role (installation, templates, handlers)
- Tasks 10-14: Update variables, inventory, playbook, documentation
- Tasks 15-17: Add verification scripts and deployment documentation

## Task 18: Final Validation

**Step 1:** Run comprehensive syntax check
```bash
ansible-playbook --syntax-check site.yml
```

**Step 2:** Check role structure
```bash
tree roles/loki roles/vector
```

**Step 3:** Validate inventory
```bash
ansible-inventory --graph
```

**Step 4:** Create final commit
```bash
git add -A && git commit -m "feat(logging): complete central logging implementation"
```

## Deployment Steps (Post-Implementation)

### 1. Deploy Loki Container
```bash
export PROXMOX_PASSWORD='your-password'
export LOKI_NAS_PASSWORD='your-nas-password'
ansible-playbook site.yml --limit loki
```

### 2. Deploy Vector to Test Container
```bash
ansible-playbook site.yml --limit sonarr
```

### 3. Test End-to-End
```bash
ansible sonarr -m shell -a 'logger -t test "Testing Loki logging pipeline"'
```

Query in Grafana: `{hostname="sonarr"} |= "Testing Loki logging pipeline"`

### 4. Deploy to All Containers
```bash
ansible-playbook site.yml --limit all:!proxmox:!localhost
```

### 5. Run Verification
```bash
./scripts/verify-logging.sh
```

## Success Criteria

- [ ] Loki container created and running
- [ ] Loki accessible on http://10.0.1.201:3100
- [ ] NAS storage mounted at /mnt/loki-data
- [ ] Vector agents installed on all containers
- [ ] Systemd journal logs flowing to Loki
- [ ] Application logs flowing to Loki
- [ ] Logs queryable in Grafana with proper labels
- [ ] Verification script passes
- [ ] All code committed to feature branch

## Related Skills

- @superpowers:verification-before-completion - Use before claiming deployment complete
- @superpowers:finishing-a-development-branch - Use after successful deployment

## Full Implementation Details

For complete step-by-step implementation with all code snippets, file contents, and verification commands, refer to the comprehensive plan that includes:

- Complete Ansible role structures for Loki and Vector
- Full YAML configuration files
- Jinja2 templates for Loki config, Vector config, and systemd services
- Host and group variable definitions
- Inventory updates
- Site playbook modifications
- Documentation updates
- Verification scripts
- Troubleshooting guides

Each task is broken down into 2-5 minute steps with exact commands and expected outputs.
