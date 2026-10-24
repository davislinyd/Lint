# Prompt: let an AI agent use Lint's local model

Lint 0.16.0 and later can share its local model with other apps on the same Mac (Settings → Model → **Other Apps**,
off by default). The text below the line is a prompt for an AI agent (Claude Code, Codex, Cursor and the like): paste it
into the agent's instructions (for example `CLAUDE.md` or `AGENTS.md`), or point the agent at this file. Then give the
agent the key: in Lint, Settings → Model → Other Apps → Key → **Copy**, and set it as the environment variable
`LINT_API_KEY` where the agent runs. Human-oriented details are in the README and the guide's
[Other apps](https://davislinyd.github.io/Lint/guide.html#local-api) section.

---

## Using Lint's local model

You can send text to a small language model that runs on this Mac. It is served by **Lint**, a menu bar app, through an
OpenAI-compatible HTTP API. Use it for small text jobs where keeping the text on this Mac matters, or to save calls to a
remote model. The user's own use of Lint always comes first, so your requests can be delayed or interrupted.

### What it is

- A local model, usually Gemma 4 E4B (about 4B parameters); the user may have chosen Qwen3 4B or Gemma 4 12B instead.
  It has no internet access and no tools.
- By default the context is about 8,000 tokens in all, prompt and answer together.
- It answers one request at a time. The text you send stays on this Mac.
- It works only while Lint is running, its source is the local model, and Other Apps is turned on.

### Connecting

- Base URL: the environment variable `LINT_API_BASE_URL` if it is set, otherwise `http://127.0.0.1:8001/v1`.
  The user can change the port in Lint's settings.
- Key: the environment variable `LINT_API_KEY`. Send it as `Authorization: Bearer <key>` (or `X-Api-Key: <key>`).
- Host: use `127.0.0.1` (or `localhost`). Any other host name is refused, and the port listens only on `127.0.0.1`
  (not `::1`, not the LAN).
- Routes, and nothing else:

  | Route | Key | Use |
  |---|---|---|
  | `GET /health` | no | Is Lint's API port on? Answers `{"status":"ok"}`. |
  | `GET /v1/models` | yes | The model's id; also tells you the key works. |
  | `POST /v1/chat/completions` | yes | Chat requests. `"stream": true` streams Server-Sent Events. |
  | `POST /v1/completions` | yes | Plain text completion. |

  Everything else (embeddings, images, audio, `/props`, `/slots` and so on) answers `404 unknown_endpoint`.
- `model`: use the `id` from `GET /v1/models`. Lint runs one model, so another name still reaches the same model.
- The request body needs a `Content-Length` (no chunked uploads) and must stay under 4 MiB. Normal HTTP clients
  already do this.

### Before the first request

1. `GET {base without /v1}/health`. If the connection is refused, Lint is not running or Other Apps is off. Ask the
   user to open Lint, choose **Local llama.cpp** under Settings → Model → Model Source, and turn on
   **Let other apps use the local model** under Other Apps. Do not try to start or configure Lint yourself.
2. `GET /v1/models` with the key. `401 invalid_api_key` (or no `LINT_API_KEY` at all) means you need the key. Ask the
   user to copy it (Settings → Model → Other Apps → Key → Copy) and set it as `LINT_API_KEY` in your environment,
   rather than pasting it into the conversation.

### Making requests

```bash
curl -sS --max-time 300 "${LINT_API_BASE_URL:-http://127.0.0.1:8001/v1}/chat/completions" \
  -H "Authorization: Bearer $LINT_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"system","content":"Fix the grammar. Reply with the corrected text only."},
                   {"role":"user","content":"She go to school yesterday."}],
       "max_tokens":200,"temperature":0.2}'
```

Streaming (`-N` turns off curl's buffering; the stream ends with `data: [DONE]`):

```bash
curl -sS -N --max-time 300 "${LINT_API_BASE_URL:-http://127.0.0.1:8001/v1}/chat/completions" \
  -H "Authorization: Bearer $LINT_API_KEY" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Summarize in one sentence: ..."}],"max_tokens":120,"stream":true}'
```

Python with the `openai` package:

```python
import os
from openai import OpenAI

client = OpenAI(
    base_url=os.environ.get("LINT_API_BASE_URL", "http://127.0.0.1:8001/v1"),
    api_key=os.environ["LINT_API_KEY"],
    timeout=300,
    max_retries=0,  # retry yourself, following the rules below
)
model = client.models.list().data[0].id
reply = client.chat.completions.create(
    model=model,
    messages=[{"role": "user", "content": "Translate into French: Thanks for your help."}],
    max_tokens=200,
)
print(reply.choices[0].message.content)
```

- Always set `max_tokens`, and keep prompts short: long inputs crowd out the answer and take long to read in.
- Send requests one after another, never in parallel. Parallel requests only wait in line (at most 8 can wait), and
  every waiting request delays the user's own.
- Allow at least 300 seconds before a client timeout. Closing the connection cancels the request, including a request
  that is still waiting its turn.

### Lint comes first

- While the user types, while Lint is using the model, and for 3 seconds after, your request waits, for up to 120
  seconds in all. This is normal; do not cancel and resend.
- If Lint needs the model while your request runs and you have not received any of the answer yet, Lint stops your
  request and sends it again by itself when it is done. You only see a longer wait.
- If a streamed answer was already arriving, the stream ends with an event like
  `data: {"error":{"message":"…","type":"server_error","code":"preempted_by_lint"}}` and no `data: [DONE]`. Throw away
  the partial answer and send the whole request again. A stream that ends without `data: [DONE]` for any other reason
  is incomplete too.

### Errors

Errors use the OpenAI shape `{"error":{"message":"…","type":"…","code":"…"}}`. Every `503` carries `Retry-After`.

| Status | `code` | What to do |
|---|---|---|
| 401 | `invalid_api_key` | The key is missing or wrong, or the user regenerated it. Ask for the new key; do not retry. |
| 403 | `invalid_host` | Use `127.0.0.1` or `localhost` as the host. |
| 403 | `origin_not_allowed` | A web page whose site is not in Lint's Allowed websites (see below). |
| 404 | `unknown_endpoint` | The route does not exist here. Use one of the four routes. |
| 405 | `method_not_allowed` | Use the method in the table above. |
| 411, 413, 431, 400 | `length_required`, `payload_too_large`, `request_header_fields_too_large`, `bad_request` | Send a normal request with `Content-Length`, a body under 4 MiB and ordinary headers. |
| 503 | `lint_busy`, `queue_full`, `restarting`, `model_not_running`, `api_stopped`, `too_many_connections`, `key_unavailable` | Wait `Retry-After` seconds and try again. `model_not_running` with `Retry-After: 60` means Lint is not using its local model: tell the user. |
| 502 | `upstream_error` | The model's answer failed or was cut off. Try again once. |
| 504 | `upstream_timeout` | The model went silent for 5 minutes. Shorten the request or tell the user. |

Retry at most 3 times per request, waiting as `Retry-After` says. If it still fails, stop and tell the user what the
error was; do not keep retrying in a loop.

### What it is good for

- Good: short rewriting, proofreading, translation, summaries of a few paragraphs, classification and pulling fields
  out of short text.
- Weak: long reasoning, math, facts about the world, current events and large amounts of code. Check what it returns.
- For structured output, ask for JSON in the prompt, give a short example, and parse the reply defensively (it may add
  text around the JSON). Do not rely on tool or function calling.

### Rules

- Treat the key as a password. Never print it, log it, write it into files, commit it, or put it in a URL. Read it from
  `LINT_API_KEY` when you need it.
- Do not look for the key anywhere else: not in the Keychain, in Lint's files or settings, or in running processes.
- Never call port 8000. It is Lint's internal model server, which accepts only Lint's own key; going around Lint's API
  would also go around the user's priority.
- Do not change Lint's settings, restart it or stop its model. Ask the user instead.
- Send only the text the job needs. Even though it stays on this Mac, leave out passwords, keys and other secrets.

### Web pages

- A web page can call the API only if its site is in Lint's **Allowed websites** (by default pages served from this
  Mac: `http://localhost`, `http://127.0.0.1` and `https://localhost`, any port). The user can add `https` websites.
- Safari does not let any `https` page reach this Mac's `http` address, so in Safari only pages served from this Mac
  work. Chrome and Brave let allowed `https` websites in.
- The key ends up in the page's JavaScript. Use it only in pages the user runs for themselves on this Mac, never in a
  page served to other people.
