#!/usr/bin/env python3
"""
Flatten a sops-decrypted YAML structure into a list of (vault_path, leaf_data) pairs.

Each level of the YAML tree that contains leaf values (non-dict) produces one
vault path. Nested dicts recurse deeper.

Input:  JSON on stdin (the decrypted sops data)
Output: JSON list of {path, data} objects on stdout

Example:
  Input:  {"grafana": {"user": "admin", "pass": "xxx"}, "mnt_users": {"mcmp2": {"host": "x", "pass": "y"}}}
  Output: [
    {"path": "grafana", "data": {"user": "admin", "pass": "xxx"}},
    {"path": "mnt_users/mcmp2", "data": {"host": "x", "pass": "y"}}
  ]
"""
import json
import sys


def flatten(obj, path_parts, strip_prefix=None):
    """Recursively collect leaf dicts at each level.

    If strip_prefix is set (e.g. 'vault_data'), it is removed from the
    beginning of every generated path so that sops keys like
    vault_data.vpn_nl map to the Vault path 'vpn_nl' — matching the
    ref+vault://kv/vpn_nl pattern used in KCL manifests.
    """
    leaves = {}
    nested = []
    for k, v in obj.items():
        if isinstance(v, dict):
            nested.append((k, v))
        else:
            leaves[k] = v
    if leaves:
        path = "/".join(path_parts)
        if strip_prefix and path.startswith(strip_prefix + "/"):
            path = path[len(strip_prefix) + 1:]
        elif path == strip_prefix:
            path = ""
        if path:
            yield {"path": path, "data": leaves}
    for k, v in nested:
        yield from flatten(v, path_parts + [k], strip_prefix)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Flatten sops YAML into vault paths")
    parser.add_argument("--strip-prefix", default=None,
                        help="Strip this prefix from generated paths (e.g. 'vault_data')")
    args = parser.parse_args()

    data = json.load(sys.stdin)
    result = list(flatten(data, [], strip_prefix=args.strip_prefix))
    json.dump(result, sys.stdout, indent=2)
    print()  # trailing newline


if __name__ == "__main__":
    main()
