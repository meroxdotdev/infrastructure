# Docker Setup Role

Installs Docker CE and Docker Compose V2 plugin on Ubuntu/Debian systems.

## Requirements

- Ubuntu 22.04+ or Debian 11+
- Ansible 2.17+
- community.docker collection

## Role Variables
```yaml
docker_edition: 'ce'                    # Docker edition
docker_channel: 'stable'                # Release channel
docker_service_state: started           # Service state
docker_service_enabled: true            # Enable on boot
docker_users: []                        # Users to add to docker group
docker_install_compose_plugin: true     # Install Docker Compose V2
```

## Example Playbook
```yaml
- hosts: servers
  roles:
    - role: docker_setup
```

## Tags

- `docker` - All Docker tasks
- `setup` - Installation tasks
- `config` - Configuration tasks
- `verify` - Verification tasks
