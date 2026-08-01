---
name: vpn-nl-connect
description: Instructions for connecting to the vpn_nl jump host for network diagnostics and connectivity tests from a non-Russian IP.
---

# vpn-nl-connect

This skill describes the process of establishing an SSH connection to the `vpn_nl` machine using credentials stored in the project's secret management system.

## Purpose
To allow the agent to execute commands, perform network probes (like curl), or verify accessibility of services from a European exit node without hardcoding sensitive data in the skill definition.

## Instructions

1. **Retrieve Credentials**:
   - Access the `secrets/vault_data.sops.yaml` file using `sops -d`.
   - Locate the `vpn_nl` section to obtain:
     - `ssh_host`: The FQDN or IP of the machine.
     - `ssh_user`: The username for SSH access (typically `root`).
     - `ssh_private_key`: The OpenSSH private key.

2. **Prepare Connection**:
   - Write the `ssh_private_key` to a temporary file on the local filesystem.
   - Set strict permissions on the key file: `chmod 600 <temp_key_file>`.

3. **Establish Connection**:
   - Connect using the retrieved host and user:
     `ssh -i <temp_key_file> -o StrictHostKeyChecking=no <ssh_user>@<ssh_host> "<command>"`

4. **Cleanup**:
   - Immediately remove the temporary key file after the command execution is complete to maintain security.

## Security Notes
- NEVER commit the decrypted private key or any session logs containing sensitive output to Git.
- Always use `StrictHostKeyChecking=no` only for automated diagnostic tasks where the host identity is pre-verified by the infrastructure owner.
