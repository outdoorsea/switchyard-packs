# ChatGPT (Apps & Connectors)

ChatGPT driving switchyard through the **remote MCP connector** — a URL and a
browser consent, no binary, no token. This is the path for chatgpt.com and the
ChatGPT apps; for **Codex** and a ChatGPT desktop app that launches a local MCP
server, use [`openai-desktop.md`](openai-desktop.md) instead. The contract this
rides is [`docs/chatgpt-connector.md`](../../docs/chatgpt-connector.md).

## 1 · Add the connector

**Settings → Apps & Connectors → Advanced settings → Developer mode** (on), then
**Create**:

| Field | Value |
|---|---|
| Name | `Switchyard` |
| MCP server URL | `https://<install>/mcp/<tenant>/<project>` — pinned to one project (recommended for ChatGPT), or `https://<install>/mcp` for every workspace the grant reaches |
| Authentication | **OAuth** — no client id or secret; the client registers itself |

Your install's URLs, filled in, are on **Tools → Remote MCP connector**
(`/dashboard/tools#remote-connector`).

## 2 · Consent

ChatGPT opens Switchyard's consent screen in the browser. Sign in, tick the
workspaces the connector may reach, click **Allow**. Nothing to paste.

## 3 · Instructions

Paste [`AGENTS.md`](AGENTS.md) into the chat (or a Project's instructions) when
you want ChatGPT to run the full orient → triage → author → deliver → validate
loop. For a read-only research question over PRDs and Pitches it needs nothing:
`search` and `fetch` are what it calls on its own.

## 4 · Verify

With the connector enabled in a chat, ask for `whoami`: `credential.source` reads
`connector`, and a pinned URL shows its project with `source: connector`. Then
`get_project_briefing`. Account + briefing = wired.

## Notes

- **Reads run unprompted; every write asks first.** ChatGPT reads each tool's
  annotations — `list_*`, `get_*`, `search`, `fetch` are read-only; `claim`,
  `claim_action`, `draft_prd` and the rest are writes it confirms before running.
- **Outside Developer mode ChatGPT calls only `search` and `fetch`.** That is
  the deep-research and chat-connector surface: a title search over PRDs,
  Pitches and Discussions, and the one-record fetch behind it.
- **Revoke** under Switchyard → Account → Authorized apps; the connector's next
  call is sent back through consent.
