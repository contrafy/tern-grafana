# Investigate

Investigate hands what you are looking at to Tern's default agent: an alert, a query or a dashboard panel, with its
labels, queries, time range, a summary of the recent values and links back to Grafana. Nothing is sent until you
have read the prompt and pressed Send.

## Starting an investigation

| Where | Key | What the prompt carries |
| --- | --- | --- |
| Alerts inbox, selected alert (also the **Investigate (i)** button in its detail) | `i` | Name, severity, state and since when, summary, description, value, labels and annotations (Grafana's internal ones hidden), runbook, dashboard and source links; for a Prometheus alert also its query and the recent values of that query |
| Query block | `I` | The expression, the time range and a summary of the values the block shows, and a Grafana Explore link when the context has Grafana |
| Dashboard or panel block, focused panel | `I` | Dashboard title and uid, panel title and type, every query with dashboard variables filled in, the time range, a summary of the panel's values and a link to the panel in Grafana |

The key opens the **Investigate** preview block beside the source. It shows the exact prompt. An alert's preview
first fetches the recent values of the alert's query (`investigate.range`, default the last hour) and adds them to
the prompt; `r` fetches them again.

| Key | Action |
| --- | --- |
| `enter` | Send to a new agent (once; the **Send again** button sends another) |
| `y` | Copy the prompt |
| `r` | Refresh the alert's recent values |
| `q`, `esc` | Close the preview |

Send starts Tern's default agent (`Settings > Agents`) in a new pane, in the working directory of the preview's pane
(Tern gives blocks the directory of the pane they opened from), or your home directory. The prompt asks for a
read-only investigation: the likely cause, the evidence and next steps, without changing anything before asking.
A toast confirms the start or says why the agent could not start.

## How the prompt travels

The source and preview blocks run on the machine whose panes they serve (possibly a remote Tern host), while the
agent is started by the window on the machine showing it. The plugin's kv store is per machine, so the
investigation travels in the link itself:

1. The source block opens `tern-grafana://investigate?subject=<payload>`, the subject as base64url JSON. When it
   would be longer than 32768 characters, recent-value series are dropped first (the prompt then says how many
   were left out), then long text (queries, summary, labels, annotations) is clipped to 400 characters; a subject
   that still does not fit is refused with a toast.
2. The window opens the preview with that link and a ticket it mints and keeps in memory.
3. Send opens `tern-grafana://investigate?prompt=<payload>&title=<title>&ticket=<ticket>`. The window starts the
   agent only for a ticket it minted in the last 12 hours.

Any other prompt link (one printed in a terminal, or sent by a preview restored after Tern restarted) opens a new
preview of that exact prompt, with a note that it came from a link, instead of starting an agent. So no link on its
own ever starts an agent: you always read the prompt in a preview and press Send.

The preview keeps the subject (names, labels, queries, value statistics), or the prompt of a prompt-only preview,
in its saved state, so a restored preview shows the same prompt; restoring never sends. Links, block arguments and
saved state never contain a credential, a credential source or a header value; links in the subject with userinfo
or a credential-named query parameter (`?token=`, `?api_key=`) are left out.

## Configuration

The optional `investigate` section:

```json
"investigate": { "range": "30m" }
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `range` | duration string | `"1h"` | How far back an alert's preview fetches the recent values of the alert's query, from `1s` to `7d`. A bad value is reported and the default is used. |
