#!/usr/bin/env python3
"""Index the local repo into Qdrant via the qdrant-mcp MCP server (qdrant-store).

Minimal dependency: Python stdlib only. Speaks streamable-http MCP protocol.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
import uuid

MCP_URL = os.environ.get("QDRANT_MCP_URL", "https://qdrant-mcp.mansion.metacoma.org/mcp/")
REPO_ROOT = os.path.abspath(os.path.dirname(os.path.dirname(__file__)))
MAX_FILE_SIZE = 200 * 1024  # skip files larger than 200KB
CHUNK_SIZE = 4000
CHUNK_OVERLAP = 200

# Skip encrypted / generated / lock / env / binary-ish files
SKIP_PATTERNS = [
    r"secrets/.*\.sops\.yaml",
    r"\.env$",
    r"\.lock$",
    r"\.mod$",
    r"kcl\.mod\.lock",
    r"\.sops\.yaml$",
    r"\.sops\.yaml\.new$",
]


def is_text(path):
    try:
        with open(path, "rb") as f:
            f.read(1024).decode("utf-8")
        return True
    except (UnicodeDecodeError, OSError):
        return False


def chunk_text(text, path):
    """Split text into ~CHUNK_SIZE chunks with overlap."""
    if len(text) <= CHUNK_SIZE:
        return [text]
    chunks = []
    start = 0
    while start < len(text):
        end = min(start + CHUNK_SIZE, len(text))
        chunks.append(text[start:end])
        if end >= len(text):
            break
        start = end - CHUNK_OVERLAP
    return chunks


def collect_chunks():
    """Return list of (path, chunk_index, total_chunks, chunk_text)."""
    out = subprocess.run(
        ["git", "ls-files"], cwd=REPO_ROOT, capture_output=True, text=True
    ).stdout.splitlines()
    branch = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=REPO_ROOT,
        capture_output=True, text=True
    ).stdout.strip()

    result = []
    for rel in sorted(out):
        if any(re.search(p, rel) for p in SKIP_PATTERNS):
            continue
        full = os.path.join(REPO_ROOT, rel)
        if not os.path.isfile(full):
            continue
        size = os.path.getsize(full)
        if size > MAX_FILE_SIZE:
            print(f"  skip (large {size}): {rel}")
            continue
        if not is_text(full):
            print(f"  skip (binary): {rel}")
            continue
        with open(full, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        chunks = chunk_text(text, rel)
        for i, c in enumerate(chunks):
            result.append({
                "path": rel,
                "branch": branch,
                "repo": "shitcluster2",
                "chunk": i,
                "total_chunks": len(chunks),
                "type": os.path.splitext(rel)[1].lstrip(".") or "txt",
                "text": c,
            })
    return result


class McpClient:
    def __init__(self, url):
        self.url = url
        self.session_id = None

    def _post(self, payload, timeout=120):
        req = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode(),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                **({"Mcp-Session-Id": self.session_id} if self.session_id else {}),
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode()
            hdrs = {k.lower(): v for k, v in r.headers.items()}
            return body, hdrs

    def _parse_result(self, body):
        for line in body.splitlines():
            if line.startswith("data:"):
                msg = json.loads(line[6:].strip())
                if "result" in msg:
                    return msg["result"]
                if "error" in msg:
                    raise RuntimeError(msg["error"])
        raise RuntimeError(f"no result in response: {body[:200]}")

    def connect(self):
        body, hdrs = self._post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "repo-indexer", "version": "1.0"}},
        })
        self.session_id = hdrs.get("mcp-session-id")
        if not self.session_id:
            raise RuntimeError(f"no session id: {body[:200]}")
        # notify initialized
        self._post({"jsonrpc": "2.0", "id": 2,
                    "method": "notifications/initialized", "params": {}})
        print(f"  connected, session={self.session_id[:8]}...")

    def store(self, information, metadata):
        result = self._parse_result(self._post({
            "jsonrpc": "2.0", "id": uuid.uuid4().int % (2**31),
            "method": "tools/call",
            "params": {"name": "qdrant-store",
                       "arguments": {"information": information,
                                     "metadata": metadata}},
        })[0])
        return result


def main():
    print("Collecting chunks from repo...")
    chunks = collect_chunks()
    print(f"  {len(chunks)} chunks collected")
    if not chunks:
        print("Nothing to index.")
        return

    client = McpClient(MCP_URL)
    client.connect()

    ok = 0
    for i, c in enumerate(chunks, 1):
        meta = {k: c[k] for k in ("path", "repo", "branch", "chunk",
                                  "total_chunks", "type")}
        try:
            client.store(c["text"], meta)
            ok += 1
        except Exception as e:
            print(f"  [{i}/{len(chunks)}] FAIL {c['path']}#{c['chunk']}: {e}")
        if i % 20 == 0:
            print(f"  [{i}/{len(chunks)}] stored {ok} ok")
    print(f"Done: {ok}/{len(chunks)} chunks stored.")


if __name__ == "__main__":
    sys.exit(main())
