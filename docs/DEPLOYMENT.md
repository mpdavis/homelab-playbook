# Central Logging Deployment Guide

This guide covers deploying the central logging infrastructure using Grafana Loki and Vector for the homelab environment.

## Architecture Overview

The central logging solution consists of:

- **Grafana Loki** (10.0.1.201): Log aggregation and storage system
  - Receives logs from Vector agents via HTTP API
  - Stores logs on NAS-backed storage with 90-day retention
  - Provides query API for Grafana and CLI tools

- **Vector** (deployed on all application hosts): Lightweight log collector
  - Tails application log files
  - Enriches logs with metadata (hostname, service, environment)
  - Forwards logs to Loki via HTTP

## Prerequisites

### Required Environment Variables

```bash
# Proxmox API authentication (required for LXC provisioning)
export PROXMOX_PASSWORD='your-proxmox-password'

# NAS credentials for Loki storage (required for Loki deployment)
export LOKI_NAS_PASSWORD='your-nas-password'
```

### Infrastructure Requirements

1. **Proxmox Host**: API accessible at 10.0.1.1
2. **NAS Share**: CIFS share at 10.0.1.10 for log storage
   - Share name: `loki-logs`
   - User: `loki` with write permissions
3. **Network**: Available IP 10.0.1.201 for Loki container
4. **SSH Keys**: `~/.ssh/id_proxmox` keypair for container access

### Ansible Collections

Install required collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

Required collections:
- `community.general` (>=9.0.0)
- `community.proxmox` (>=3.0.0)

## Deployment Steps

### 1. Deploy Loki Server

Deploy the Loki log aggregation server:

```bash
# Deploy Loki (creates LXC container + configures Loki)
ansible-playbook site.yml --limit loki
```

This will:
1. Create LXC container (VMID 201) on Proxmox
2. Install Loki 2.9.3
3. Mount NAS storage for log persistence
4. Configure Loki with 90-day retention
5. Start Loki service on port 3100

**Expected output:**
```
PLAY RECAP ************************************************************
loki                       : ok=X    changed=Y    unreachable=0    failed=0
```

### 2. Deploy Vector Agents

Deploy Vector log collectors to application hosts:

```bash
# Deploy Vector on all hosts (currently: sonarr)
ansible-playbook site.yml --tags vector

# Or deploy to specific hosts
ansible-playbook site.yml --limit sonarr
```

This will:
1. Install Vector agent
2. Configure log file paths from `vector_log_paths` variable
3. Set up Loki endpoint from `loki_endpoint` variable
4. Add host labels (hostname, job name)
5. Start Vector service

**Expected output:**
```
PLAY RECAP ************************************************************
sonarr                     : ok=X    changed=Y    unreachable=0    failed=0
```

### 3. Deploy Full Stack

Deploy both Loki and Vector in one command:

```bash
ansible-playbook site.yml
```

## Verification

### Automated Verification

Use the provided verification script:

```bash
./scripts/verify-logging.sh
```

This script checks:
- Loki service health (ready endpoint)
- Loki metrics endpoint accessibility
- Vector service status on all hosts
- Log ingestion (queries for recent logs)
- Available Loki labels

**Expected output:**
```
========================================
Central Logging Verification
========================================

==> Checking Loki health
✓ Loki is ready at http://10.0.1.201:3100
✓ Loki metrics endpoint is accessible

==> Checking Vector agent status
✓ Vector service is running on sonarr

==> Checking log ingestion
✓ Found 1 log stream(s) from sonarr
  Sample: [2024-01-15 10:30:45] Info: Starting Sonarr...

==> Checking Loki labels
✓ Available labels: job, hostname, filename
✓ Found 'job' label
✓ Found 'hostname' label

========================================
Verification Summary
========================================
Checks passed: 7
Checks failed: 0

All checks passed!
```

### Manual Verification

#### Check Loki Health

```bash
# Check if Loki is ready
curl http://10.0.1.201:3100/ready

# Check Loki metrics
curl http://10.0.1.201:3100/metrics

# Check Loki build info
curl http://10.0.1.201:3100/loki/api/v1/status/buildinfo
```

#### Check Vector Status

```bash
# Check Vector service on hosts
ansible sonarr -m systemd -a "name=vector state=started"

# View Vector logs
ansible sonarr -m shell -a "journalctl -u vector -n 50"

# Check Vector configuration
ansible sonarr -m shell -a "vector validate /etc/vector/vector.toml"
```

#### Query Logs from Loki

```bash
# Install logcli (Loki CLI tool)
brew install logcli  # macOS
# or download from: https://github.com/grafana/loki/releases

# Configure logcli
export LOKI_ADDR=http://10.0.1.201:3100

# Query recent logs from sonarr
logcli query '{job="sonarr"}' --limit 10 --since 1h

# Query logs with label filtering
logcli query '{job="sonarr", hostname="sonarr"}' --limit 20

# Follow logs in real-time
logcli query '{job="sonarr"}' --tail --since 1m
```

#### Check Loki Labels

```bash
# List all available labels
curl http://10.0.1.201:3100/loki/api/v1/labels

# Get values for a specific label
curl http://10.0.1.201:3100/loki/api/v1/label/job/values
```

## Configuration

### Adding Log Collection to New Services

To add log collection to a new service:

1. **Define log paths** in the service's `host_vars/<service>.yml`:

```yaml
# Vector log collection
vector_log_paths:
  - "{{ <service>_data_dir }}/logs/*.log"
  - "/var/log/<service>/*.log"
```

2. **Add service to site.yml** Vector play:

```yaml
- name: Configure Vector on Application Hosts
  hosts: sonarr,radarr,prowlarr  # Add new service here
  become: true
  roles:
    - vector
```

3. **Deploy** Vector to the new host:

```bash
ansible-playbook site.yml --limit <service>
```

### Modifying Loki Retention

To change log retention period, update `host_vars/loki.yml`:

```yaml
loki_retention_days: 30  # Change from 90 to 30 days
```

Then redeploy:

```bash
ansible-playbook site.yml --limit loki
```

### Customizing Vector Configuration

Vector configuration is generated from templates in `roles/vector/templates/`. To customize:

1. Edit `roles/vector/templates/vector.toml.j2`
2. Add custom transforms or sinks
3. Redeploy Vector:

```bash
ansible-playbook site.yml --tags vector
```

## Troubleshooting

### Loki Container Won't Start

**Symptom**: Container starts but Loki service fails

**Diagnosis**:
```bash
# Check Loki logs
ansible loki -m shell -a "journalctl -u loki -n 100"

# Check Loki configuration
ansible loki -m shell -a "cat /etc/loki/config.yml"

# Test Loki configuration
ansible loki -m shell -a "/usr/local/bin/loki -config.file=/etc/loki/config.yml -verify-config"
```

**Common causes**:
- NAS mount failed (check credentials, network connectivity)
- Invalid configuration syntax
- Insufficient memory (increase `lxc_memory` in host_vars)

### Vector Not Sending Logs

**Symptom**: Vector service running but no logs appear in Loki

**Diagnosis**:
```bash
# Check Vector logs
ansible sonarr -m shell -a "journalctl -u vector -n 50"

# Verify Vector can reach Loki
ansible sonarr -m shell -a "curl -I http://10.0.1.201:3100/ready"

# Check Vector metrics
ansible sonarr -m shell -a "curl http://localhost:9598/metrics"
```

**Common causes**:
- Log file paths don't exist or are inaccessible
- Loki endpoint unreachable (firewall, network)
- Vector configuration syntax errors
- File permissions (Vector runs as `vector` user)

### No Logs Ingested

**Symptom**: Loki and Vector running but no logs in queries

**Diagnosis**:
```bash
# Check if log files exist and are being written to
ansible sonarr -m shell -a "ls -lh {{ sonarr_data_dir }}/.config/Sonarr/logs/"

# Check Vector is tailing files
ansible sonarr -m shell -a "journalctl -u vector -n 100 | grep -i 'watching\|tailing'"

# Check Loki ingester metrics
curl http://10.0.1.201:3100/metrics | grep loki_ingester
```

**Common causes**:
- Application not writing logs yet
- Log paths don't match glob patterns
- Clock skew between hosts (Loki rejects out-of-order logs)
- Vector buffer full or backpressure

### NAS Mount Issues

**Symptom**: Loki fails to write logs, mount errors

**Diagnosis**:
```bash
# Check mount status
ansible loki -m shell -a "mount | grep loki"

# Check NAS connectivity
ansible loki -m shell -a "ping -c 3 10.0.1.10"

# Test CIFS credentials
ansible loki -m shell -a "smbclient //10.0.1.10/loki-logs -U loki%PASSWORD -c ls"

# Check disk space
ansible loki -m shell -a "df -h /var/lib/loki"
```

**Common causes**:
- Wrong NAS credentials
- NAS share not accessible
- Network connectivity issues
- Insufficient permissions on NAS share

### Firewall Issues

**Symptom**: Vector can't connect to Loki

**Diagnosis**:
```bash
# Test connectivity from Vector host to Loki
ansible sonarr -m shell -a "nc -zv 10.0.1.201 3100"

# Check if Loki is listening
ansible loki -m shell -a "ss -tlnp | grep 3100"

# Check iptables rules (if using firewall)
ansible loki -m shell -a "iptables -L -n | grep 3100"
```

**Resolution**:
```bash
# If firewall is blocking, add rule on Loki container
ansible loki -m shell -a "iptables -A INPUT -p tcp --dport 3100 -j ACCEPT"
```

## Integration with Grafana

To visualize logs in Grafana:

1. **Add Loki data source** in Grafana UI:
   - URL: `http://10.0.1.201:3100`
   - Access: Server (default)

2. **Create dashboard** with LogQL queries:
   ```
   {job="sonarr"}
   {job="sonarr"} |= "error"
   {hostname="sonarr"} | json | level="ERROR"
   ```

3. **Set up alerts** based on log patterns

## Maintenance

### Log Rotation

Loki handles retention automatically based on `loki_retention_days` setting. No manual log rotation needed.

### Backup Strategy

Loki stores logs on NAS (`//10.0.1.10/loki-logs`). Back up this share using your NAS backup solution.

### Upgrading Loki

To upgrade Loki to a new version:

1. Update `loki_version` in `host_vars/loki.yml`
2. Redeploy:
   ```bash
   ansible-playbook site.yml --limit loki
   ```

### Upgrading Vector

Vector is installed from official repositories. To upgrade:

```bash
ansible sonarr -m apt -a "name=vector state=latest update_cache=yes"
ansible sonarr -m systemd -a "name=vector state=restarted"
```

## Performance Tuning

### Loki Performance

For high log volumes, adjust in `host_vars/loki.yml`:

```yaml
lxc_cores: 4      # Increase CPU cores
lxc_memory: 8192  # Increase memory
```

### Vector Performance

Vector is lightweight and rarely needs tuning. For very high volumes:

1. Adjust buffer settings in `roles/vector/templates/vector.toml.j2`
2. Increase batch sizes for Loki sink
3. Add multiple Loki instances with load balancing

## Security Considerations

- Loki has no authentication by default (suitable for internal networks)
- For production, consider adding authentication proxy
- Vector communicates with Loki over HTTP (no TLS in current setup)
- Log files may contain sensitive data - ensure proper NAS access controls
- Container runs as root - consider rootless LXC for additional security

## Additional Resources

- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Vector Documentation](https://vector.dev/docs/)
- [LogQL Query Language](https://grafana.com/docs/loki/latest/logql/)
- [Vector Loki Sink](https://vector.dev/docs/reference/configuration/sinks/loki/)
