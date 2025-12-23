# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an Ansible-based infrastructure-as-code repository for managing a Proxmox homelab environment. The playbooks automate the provisioning and configuration of LXC containers for various services including media management (Sonarr, Radarr, Prowlarr), streaming (Jellyfin), and monitoring (Grafana, Prometheus).

## Architecture

### Unified Deployment Model

The `site.yml` playbook handles both infrastructure provisioning and service configuration in a single execution. Each service deployment consists of two phases:

1. **Provisioning Phase** (`lxc_provision` role): Checks if container exists, creates it if needed
2. **Configuration Phase** (service role): Configures the application within the container

### Key Design Patterns

- **Container specifications** are defined in `host_vars/<hostname>.yml` with all LXC parameters (vmid, resources, networking, mounts)
- **Idempotent provisioning**: The `lxc_provision` role checks if containers exist before creating them, making deployments safe to re-run
- **Role-based infrastructure**: LXC container creation is a role that can be applied to any host with `lxc_*` variables defined
- **Per-host configuration**: Each service host has comprehensive variable definitions including both infrastructure (LXC) and application settings
- **Role delegation**: Container provisioning delegates to the Proxmox host; application configuration runs directly on containers
- **Variable hierarchy**: `group_vars/proxmox.yml` holds API credentials (password from `PROXMOX_PASSWORD` env var), `group_vars/all.yml` sets SSH configuration, `host_vars/` contain complete host-specific settings

## Common Commands

### Initial Setup
```bash
# Install required Ansible collections
ansible-galaxy collection install -r requirements.yml

# Bootstrap local dependencies (if needed)
ansible-playbook bootstrap.yml

# Generate SSH key pair for container access
ssh-keygen -t ed25519 -f ~/.ssh/id_proxmox
```

### Deploying Services
```bash
# Set Proxmox API password
export PROXMOX_PASSWORD='your-password'

# Deploy a single service (creates container + configures service)
ansible-playbook site.yml --limit sonarr

# Deploy all services
ansible-playbook site.yml

# Re-run deployment (idempotent - checks if container exists first)
ansible-playbook site.yml --limit sonarr
```

### Testing and Validation
```bash
# Check playbook syntax
ansible-playbook --syntax-check site.yml

# Dry run to see what would change (note: container provisioning is skipped in check mode)
ansible-playbook site.yml --check --limit sonarr

# List available hosts and groups
ansible-inventory --list

# Verify container connectivity
ansible sonarr -m ping

# Check what containers exist
ansible-playbook site.yml --limit sonarr --tags never -vv
```

## Configuration Files

- `ansible.cfg`: Disables host key checking for container access
- `inventory.yml`: Static inventory defining host groups (proxmox, monitoring, streaming)
- `site.yml`: Main playbook that provisions containers and configures services
- `group_vars/proxmox.yml`: Proxmox API connection details (host: 10.0.1.1, node: pve)
- `group_vars/all.yml`: Global SSH settings (user: root, key: ~/.ssh/id_proxmox)
- `host_vars/<service>.yml`: Per-host configuration including LXC specs and application settings

## Role Structure

### lxc Role
- Located in `roles/lxc/`
- Manages the complete LXC container lifecycle on Proxmox
- **State-based operation**: Controlled by `lxc_state` variable (default: `present`)
  - `lxc_state: present` - Ensure container exists and is running
  - `lxc_state: absent` - Remove container completely
  - `lxc_state: started` - Ensure container is running
  - `lxc_state: stopped` - Ensure container is stopped
- **Task files**:
  - `tasks/main.yml` - Routes to appropriate task file based on state
  - `tasks/present.yml` - Creates container if needed, ensures it's running
  - `tasks/absent.yml` - Deletes container if it exists
  - `tasks/started.yml` - Starts container and waits for SSH
  - `tasks/stopped.yml` - Stops container gracefully (or forcefully if `lxc_force_stop: true`)
- **Variables**: Requires `lxc_*` variables defined in host_vars (vmid, hostname, cores, memory, disk, netif)
- **Delegation**: Runs on localhost, makes Proxmox API calls remotely
- **Idempotent**: Safe to run multiple times; only makes changes when needed

### sonarr Role
- Located in `roles/sonarr/`
- Installs and configures Sonarr TV series management application
- **Tasks**: Creates system user, downloads versioned binary, configures systemd service
- **Templates**: `sonarr.service` - Systemd unit with security hardening
- **Defaults**: Default paths, versions, and settings in `defaults/main.yml`
- **Variables**: Override in `host_vars/sonarr.yml` (version, install paths, user, port)
- **Idempotent**: Checks installed version before downloading; only updates when needed

### Service Role Pattern
Service roles should follow this structure:
- `defaults/main.yml`: Sensible defaults for all variables
- `tasks/main.yml`: Imports specific task files
- `tasks/install.yml`: Creates users, installs application, configures service
- `templates/`: Jinja2 templates for configuration files
- `handlers/main.yml`: Service restart and reload handlers

## Required Collections

- `community.general` (>=9.0.0): General-purpose modules
- `community.proxmox` (>=3.0.0): Proxmox VE API modules for LXC management

Install with: `ansible-galaxy collection install -r requirements.yml`

## Environment Variables

- `PROXMOX_PASSWORD`: Required for Proxmox API authentication (referenced in `group_vars/proxmox.yml:7`)

## SSH Key Requirements

The playbook expects SSH keys at:
- Private key: `~/.ssh/id_proxmox`
- Public key: `~/.ssh/id_proxmox.pub` (injected into containers at creation)

Generate with: `ssh-keygen -t ed25519 -f ~/.ssh/id_proxmox`

## Adding New Services

1. **Create host_vars file**: `host_vars/<service>.yml` with:
   - `ansible_host`: IP address for the container
   - `lxc_*`: Container specifications (vmid, cores, memory, disk, networking, mounts)
   - `<service>_*`: Application-specific configuration variables

2. **Add to inventory**: Add hostname to appropriate group in `inventory.yml`

3. **Create service role**: `roles/<service>/` following the sonarr role pattern:
   - `defaults/main.yml`: Default configuration values
   - `tasks/main.yml` and `tasks/install.yml`: Installation logic
   - `templates/`: Configuration file templates
   - `handlers/main.yml`: Service management handlers

4. **Add to site.yml**: Create two plays for the service:
   ```yaml
   - name: Provision LXC Container for <Service>
     hosts: <service>
     gather_facts: false
     connection: local
     roles:
       - lxc

   - name: Configure <Service>
     hosts: <service>
     become: true
     roles:
       - <service>
   ```

5. **Deploy**: Run `ansible-playbook site.yml --limit <service>`

The `lxc` role automatically handles container creation (using `lxc_state: present` by default), making the process fully automated and idempotent.

### Managing Container Lifecycle

To control container state, set `lxc_state` in host_vars or as a variable:
```bash
# Remove a container
ansible-playbook site.yml --limit sonarr -e lxc_state=absent

# Stop a container
ansible-playbook site.yml --limit sonarr -e lxc_state=stopped

# Start a container
ansible-playbook site.yml --limit sonarr -e lxc_state=started
```

## Looking Up Ansible Collection Documentation

When working with Ansible collections (like `devopsarr.sonarr`), use these methods to find available modules and their parameters:

### List All Modules in a Collection
```bash
# List all modules with short descriptions
ansible-doc -l devopsarr.sonarr

# List just module names
ansible-doc -l devopsarr.sonarr | awk '{print $1}'
```

### Get Detailed Module Documentation
```bash
# View full documentation for a specific module
ansible-doc devopsarr.sonarr.sonarr_quality_profile

# Show examples only
ansible-doc devopsarr.sonarr.sonarr_quality_profile | grep -A 100 "EXAMPLES:"
```

### Online Documentation
- **Ansible Galaxy**: `https://galaxy.ansible.com/ui/repo/published/<namespace>/<collection>/docs/`
  - Example: `https://galaxy.ansible.com/ui/repo/published/devopsarr/sonarr/docs/`
- **GitHub Repository**: Most collections have detailed README files with examples
  - Example: `https://github.com/devopsarr/ansible-collection-sonarr`

### Common Pattern
Collection modules typically follow naming conventions:
- `<collection>.<resource>` - Manage a resource (create/update/delete)
- `<collection>.<resource>_info` - Get information about resources (read-only)
- `<collection>.<resource>_schema_info` - Get schema/structure information

Example:
```bash
# Manage quality profiles
devopsarr.sonarr.sonarr_quality_profile

# Get information about existing profiles
devopsarr.sonarr.sonarr_quality_profile_info
```
