---
name: usadba-ips
description: Retrieve the user's main public IP address and their tunnel IP address using specific external services to verify network connectivity.
---

# usadba-ips

This skill allows the agent to retrieve the user's main public IP address and their tunnel IP address using specific external services.

## Purpose
To verify network connectivity and identify current exit nodes for both primary internet and VPN/tunnel connections.

## Instructions
1. **Retrieve Main IP**: Execute `curl -s https://myip.ru/index_small.php`. The response is a small HTML snippet; extract the IP address from the table cell (`<td>`).
2. **Retrieve Tunnel IP**: Execute `curl -s https://ifconfig.me`. The response is the plain text IP address.
3. **Reporting**: Present both addresses to the user, clearly distinguishing between the "Main IP" and the "Tunnel IP".
