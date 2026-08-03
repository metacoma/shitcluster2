---
name: mcp-list
description: Retrieve the list of available tools from an MCP (Model Context Protocol) server using standard curl commands.
---

# MCP Tool List Skill

This skill provides a method to retrieve the list of available tools from any MCP (Model Context Protocol) server that supports HTTP/SSE transport, using standard `curl` commands without needing a full SSE client.

## Workflow

To get the tool list from an MCP server, you must follow the protocol's session lifecycle: **Session Discovery $\to$ Initialization $\to$ Tool Listing**.

### 1. Session Discovery
MCP servers require a session ID for state management. This is provided by the server in the response headers of any request to the MCP endpoint.

**Command:**
```bash
SESSION_ID=$(curl -k -I <SERVER_URL> | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')
echo "Session ID: $SESSION_ID"
```

### 2. Server Initialization
Before calling any functional methods, the client must initialize the connection. The server will reject `tools/list` requests if the session has not been initialized.

**Command:**
```bash
curl -k -X POST <SERVER_URL> \
     -H "Content-Type: application/json" \
     -H "mcp-session-id: $SESSION_ID" \
     -d '{
       "jsonrpc":"2.0",
       "id":1,
       "method":"initialize",
       "params":{
         "protocolVersion":"2024-11-05",
         "capabilities":{},
         "clientInfo":{"name":"curl-agent","version":"1.0"}
       }
     }'
```

### 3. Listing Tools
Once initialized, you can request the list of available tools.

**Command:**
```bash
curl -k -X POST <SERVER_URL> \
     -H "Content-Type: application/json" \
     -H "mcp-session-id: $SESSION_ID" \
     -d '{
       "jsonrpc":"2.0",
       "id":2,
       "method":"tools/list",
       "params":{}
     }'
```

## Troubleshooting & Notes

- **SSL Certificates**: Use `-k` (or `--insecure`) if the MCP server uses self-signed certificates (common in homelab environments).
- **Transport Format**: The response is typically wrapped in SSE format (`event: message\ndata: {...}`). You may need to parse the `data:` field to get the actual JSON result.
- **Protocol Version**: Ensure `protocolVersion` matches the server's expected version (currently `2024-11-05`).
- **Session Expiry**: If you receive a "Missing session ID" or "Invalid session" error, repeat Step 1 to get a fresh ID.

## Example Usage for Hound MCP
```bash
URL="https://hound-mcp.mansion.metacoma.org/mcp"
SID=$(curl -k -I $URL | grep -i "mcp-session-id" | awk '{print $2}' | tr -d '\r')
curl -k -X POST $URL -H "Content-Type: application/json" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agent","version":"1.0"}}}'
curl -k -X POST $URL -H "Content-Type: application/json" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```
