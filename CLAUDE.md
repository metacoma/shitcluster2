# Claude Code instructions for shitcluster

Follow all rules in [AGENTS.md](./AGENTS.md).

## Claude-specific notes

- Prefer `read_file` and `search_files` over shell commands for file inspection
- Use `patch` for targeted edits; `write_file` only for new files or when patch fails twice
- Run validation commands (`kcl run .`, `make -C ansible ansible_lint`) after changes
- Never read or print `.env` contents — it contains secrets
