---
name: web-search
description: Provide a systematic approach to finding, extracting, and verifying technical information from the internet using available MCP tools.
---

# Web Research Skill

This skill provides a systematic approach to finding, extracting, and verifying technical information from the internet using available MCP tools. The goal is to move beyond surface-level answers and perform deep diagnostics or research.

## Toolset

| Tool | Purpose | Usage Note |
|---|---|---|
| `mcphub_ddgs-search_text` | Perform broad text searches via DuckDuckGo | Use for discovery, finding documentation links, and identifying community discussions (StackOverflow, GitHub Issues). |
| `mcphub_crawl4ai-md` | Convert a URL into clean Markdown | Use to read the actual content of a page. Always prefer `-md` over raw HTML for better readability and context. |

## Research Workflow

### 1. Discovery Phase (Search)
* **Precise Querying**: Start with specific technical terms, version numbers, and error messages.
* **Iterative Search**: If the first query doesn't yield a direct answer, pivot. Try searching for:
    * "How to [action] in [technology]"
    * "[Error message] solution"
    * "[Technology] [Feature] documentation"
* **Anti-Laziness Rule**: Do NOT stop at the first page of results. Scan all provided snippets carefully. Often, the most technical and accurate answer is hidden in a GitHub issue or a niche blog post on the second or third page.

### 2. Extraction Phase (Deep Dive)
* **Selective Crawling**: Identify 3-5 high-quality links from search results (official docs first, then reputable community sites).
* **Full Content Analysis**: Use `crawl4ai-md` to read the entire page. Do not rely on search snippets.
* **Following Leads**: If a crawled page references another document or an official specification, find that URL and crawl it as well.

### 3. Verification Phase (Synthesis)
* **Cross-Referencing**: Compare information from different sources. If two sources contradict each other, look for a third "tie-breaker" source (usually the official documentation).
* **Validation against Environment**: Once a potential solution is found, verify it against the current system state using `kubectl`, `bash`, or `read` before proposing any changes.

## Checklist for Thoroughness
- [ ] Did I check more than just the first 3 search results?
- [ ] Did I read the actual page content instead of just the snippet?
- [ ] Did I look for official documentation as the primary source of truth?
- [ ] Have I cross-referenced the finding with at least one other independent source?
- [ ] Is the information applicable to the specific versions used in this project?
