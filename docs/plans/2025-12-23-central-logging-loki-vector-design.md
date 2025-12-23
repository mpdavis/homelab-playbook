# Central Logging with Grafana Loki and Vector

**Date:** 2025-12-23
**Status:** Design Approved
**Author:** Design Session

## Overview

This design implements centralized log aggregation for the homelab Proxmox environment using Grafana Loki for storage and Vector for log collection. The solution provides comprehensive logging across all LXC containers with 90-day retention, storing logs on existing NAS infrastructure.

## Objectives

- Centralize logs from all LXC containers in the homelab
- Collect both systemd journal and application-specific log files
- Retain logs for 90 days for historical analysis and troubleshooting
- Query logs through existing Grafana instance
- Maintain infrastructure-as-code approach with Ansible automation

## Architecture

### Three-Tier Logging Stack

The logging infrastructure consists of three main components:

1. **Loki (dedicated LXC container)** - Central log aggregation and storage service that receives logs from Vector agents, stores them on NAS via SMB mount, and serves queries to Grafana.

2. **Vector agents (on every LXC container)** - Lightweight log collectors running on each service container that collect both systemd journal entries and application-specific log files, label them appropriately, and push to Loki over HTTP.

3. **Grafana (existing)** - Query interface configured with Loki as a data source for exploring logs using LogQL queries.

### Data Flow

```
[Container Services] → systemd journal → [Vector Agent]
                    → app log files   → [Vector Agent] → HTTP → [Loki] → SMB → [NAS]
                                                                    ↑
[Grafana] ← HTTP queries ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ┘
```

### Network Requirements

- Vector agents need HTTP access to Loki (port 3100)
- Grafana needs HTTP access to Loki (port 3100)
- Loki container needs SMB/CIFS access to NAS (port 445)
- All communication stays within internal network (no authentication required initially)

### Design Rationale

**Agent-Based Vector Deployment (vs Centralized):**
- More resilient - individual agent failures don't affect other services
- Simpler network model - each container talks directly to Loki
- Enables service-specific log processing and enrichment
- Scales naturally with Ansible automation as services are added
- No single point of failure for log collection

**Direct NAS Mount (vs Bind Mount):**
- Cleaner Ansible automation
- Avoids unprivileged LXC UID/GID mapping complexity
- Self-contained container configuration
- No Proxmox host intermediary to manage

## Component Details

### Loki Container

**LXC Specifications:**
- VMID: 201 (or next available)
- Resources: 2 CPU cores, 4GB RAM, 20GB root disk
- OS: Debian 12
- Network: Static IP (e.g., 10.0.1.201)

**NAS Storage:**
- Mount point: `/mnt/loki-data`
- Protocol: SMB/CIFS via `/etc/fstab`
- Credentials: `/etc/loki-cifs-credentials` (mode 600)
- Directory structure:
  - `chunks/` - Compressed log data
  - `index/` - Index files for queries
  - `boltdb-shipper-active/` - Active index
  - `boltdb-shipper-cache/` - Index cache

**Configuration:**
- Storage backend: Filesystem (simple, reliable for homelab)
- Retention: 90 days enforced via compactor
- Compression: Snappy (good balance of speed/size)
- Ingestion rate: 16MB/sec per stream
- Query limits: 5000 streams, 5MB result size (adjustable)
- Config location: `/etc/loki/config.yml` (templated by Ansible)

### Vector Agents

**Installation:**
- Systemd service per container
- Binary from official Vector releases (versioned)
- System user: `vector`
- Config: `/etc/vector/vector.toml` (templated)

**Configuration Sections:**

1. **Sources:**
   - `journald`: Captures all systemd journal entries
   - `files`: Tails application-specific logs (paths from host_vars)

2. **Transforms:**
   - Add labels: `hostname`, `service`, `environment=homelab`, `log_type`
   - Parse structured logs (JSON where applicable)

3. **Sinks:**
   - Endpoint: `http://loki:3100` (or static IP)
   - Batching: 5-second timeout or 1MB batch
   - Retry: Exponential backoff up to 60 seconds

**Resource Usage:**
- Memory: ~50-100MB per agent
- CPU: Minimal

### Grafana Integration

**Data Source Configuration (Manual):**
- Type: Loki
- URL: `http://10.0.1.201:3100`
- Access: Server
- Authentication: None

**Example LogQL Queries:**
```logql
# All logs from a service
{hostname="sonarr"}

# Journal logs from all services
{log_type="journal"}

# Application errors
{service=~".+"} |= "error" or "ERROR"

# Error rate over time
rate({service=~".+"} |= "error" [5m])
```

## Ansible Implementation

### New Roles

**`roles/loki/`**
```
├── defaults/main.yml          # Version, ports, paths, retention
├── tasks/
│   ├── main.yml
│   ├── install.yml            # Download, user creation, systemd
│   └── configure_storage.yml  # cifs-utils, credentials, fstab
├── templates/
│   ├── loki-config.yml.j2     # Loki config with templated paths
│   └── loki.service.j2        # Systemd unit
└── handlers/main.yml          # Restart/reload
```

**`roles/vector/`**
```
├── defaults/main.yml          # Version, Loki endpoint
├── tasks/
│   ├── main.yml
│   └── install.yml            # Download, user creation, systemd
├── templates/
│   ├── vector.toml.j2         # Config with conditional sources
│   └── vector.service.j2      # Systemd unit
└── handlers/main.yml          # Restart/reload
```

### Variable Organization

**`group_vars/all.yml`** (global logging config):
```yaml
loki_endpoint: "http://10.0.1.201:3100"
loki_hostname: "loki"
```

**`host_vars/loki.yml`** (Loki container):
```yaml
lxc_vmid: 201
lxc_hostname: loki
lxc_cores: 2
lxc_memory: 4096
lxc_disk: 20
# ... standard LXC settings ...

loki_nas_share: "//10.0.1.10/loki-share"
loki_nas_username: "loki-user"
loki_nas_password: "{{ lookup('env', 'LOKI_NAS_PASSWORD') }}"
loki_retention_days: 90
```

**`host_vars/<service>.yml`** (per-service):
```yaml
# Existing service config...

vector_log_paths:
  - /opt/sonarr/logs/*.txt
  - /var/log/sonarr/*.log
```

### Playbook Updates (`site.yml`)

```yaml
# Loki infrastructure
- name: Provision LXC Container for Loki
  hosts: loki
  gather_facts: false
  connection: local
  roles:
    - lxc

- name: Configure Loki
  hosts: loki
  become: true
  roles:
    - loki

# Vector on all containers (except Proxmox host)
- name: Deploy Vector Agents
  hosts: all:!proxmox
  become: true
  roles:
    - vector
```

## Testing & Validation

### Deployment Verification

1. **Loki Health:**
   ```bash
   curl http://10.0.1.201:3100/ready
   curl http://10.0.1.201:3100/metrics | grep loki_ingester_streams
   ```

2. **Vector Status:**
   ```bash
   systemctl status vector
   journalctl -u vector -f
   vector top
   ```

3. **End-to-End:**
   ```bash
   # On any container
   logger -t test-log "Testing Loki logging pipeline"

   # Query in Grafana
   {hostname="sonarr"} |= "Testing Loki logging pipeline"
   ```

### Common Issues

| Issue | Diagnosis | Solution |
|-------|-----------|----------|
| No logs appearing | Vector sink misconfigured | Check Loki endpoint, verify network with `telnet loki 3100` |
| SMB mount fails | Permissions or connectivity | Verify credentials file (mode 600), check cifs-utils installed |
| High Loki memory | Query or retention config | Adjust limits in config, review query patterns |
| Missing app logs | File path mismatch | Verify paths in Vector config, check file permissions |

### Ongoing Monitoring

- Loki metrics endpoint: `/metrics` (for Prometheus if added later)
- Vector internal metrics
- NAS disk usage: `df -h /mnt/loki-data`
- Grafana alert: "No logs from {service} in 10 minutes"

## Out of Scope (Future Enhancements)

- Proxmox host logging (deferred for initial implementation)
- Authentication between Vector and Loki
- Multi-tenancy or log isolation by service type
- Object storage backend (S3-compatible)
- Log-based alerting rules
- Automatic log parsing for structured application logs

## Success Criteria

- All LXC containers shipping logs to Loki
- Both systemd journal and application logs collected
- 90-day retention working correctly
- Logs queryable in Grafana with < 10-second latency
- All infrastructure defined in Ansible for reproducibility
- New services automatically get Vector agent via playbook

## Timeline Considerations

Implementation can proceed in phases:
1. Loki container deployment and NAS mount configuration
2. Vector role creation and deployment to existing containers
3. Grafana data source configuration
4. Testing and validation across all services
5. Documentation updates for operations
