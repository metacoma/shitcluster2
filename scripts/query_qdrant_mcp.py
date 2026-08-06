#!/usr/bin/env python3
"""Query the repo RAG via the qdrant-mcp MCP server (qdrant-find).

Usage: python3 scripts/query_qdrant_mcp.py "how to add a new KCL app"
"""
import html
import json
import re
import sys
import urllib.request

MCP_URL = "https://qdrant-mcp.mansion.metacoma.org/mcp/"
LIMIT = 5


class McpClient:
    def __init__(self, url):
        self.url = url
        self.session_id = None

    def _post(self, payload, timeout=120):
        req = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream",
                     **({"Mcp-Session-Id": self.session_id} if self.session_id else {})},
            method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode(), {k.lower(): v for k, v in r.headers.items()}

    def _parse(self, body):
        for line in body.splitlines():
            if line.startswith("data:"):
                msg = json.loads(line[6:].strip())
                if "result" in msg:
                    return msg["result"]
                if "error" in msg:
                    raise RuntimeError(msg["error"])
        return None

    def connect(self):
        body, hdrs = self._post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "repo-query", "version": "1.0"}},
        })
        self.session_id = hdrs.get("mcp-session-id")
        if not self.session_id:
            raise RuntimeError(f"no session id: {body[:200]}")
        self._post({"jsonrpc": "2.0", "id": 2,
                    "method": "notifications/initialized", "params": {}})

    def find(self, query):
        return self._parse(self._post({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "qdrant-find",
                       "arguments": {"query": query}},
        })[0])


def parse_entry(text):
    """Parse '<entry><content>...</content><metadata>...</metadata></entry>'."""
    content = re.search(r"<content>(.*)</content>", text, re.S)
    meta = re.search(r"<metadata>(.*)</metadata>", text, re.S)
    return (
        html.unescape(content.group(1)) if content else text,
        json.loads(html.unescape(meta.group(1))) if meta and meta.group(1) else {},
    )


def main():
    query = " ".join(sys.argv[1:]) or "how to add a new KCL app in workloads"
    client = McpClient(MCP_URL)
    client.connect()
    print(f"Query: {query}\n" + "=" * 70)
    res = client.find(query)
    if not res:
        print("No results.")
        return
    blocks = res.get("content", [])
    # tool returns one text block containing a JSON array of strings
    texts = json.loads(blocks[0]["text"]) if blocks else []
    for raw in texts[1:LIMIT + 1]:
        content, meta = parse_entry(raw)
        path = meta.get("path", "?")
        print(f"\n📄 {path} (chunk {meta.get('chunk', '?')}/{meta.get('total_chunks', '?')})")
        print("-" * 60)
        print(content[:800])
        print()


if __name__ == "__main__":
    sys.exit(main())
