# Usage export for other tools

AgentMeter writes this Mac's 30-day token and cost totals to:

```
~/Library/Application Support/AgentMeter/agentmeter-usage.json
```

It sits next to `agentmeter-summary.json`, which holds the live limits. This file holds what the
Claude and Codex tabs show below the account cards. It is rewritten after each cost refresh and
each claude-swap refresh, only when cost tracking is on. Mode 0600, readable by this user only.

## Schema 1

```
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-05T15:52:00Z",
  "windowDays": 30,
  "all":    Scope or null,
  "claude": Scope or null,
  "codex":  Scope or null
}
```

A `Scope`:

| Field | Meaning |
| --- | --- |
| `tokens`, `costUSD` | 30-day totals |
| `todayTokens`, `todayCostUSD` | today, local time |
| `byUser` | one row per macOS user sharing counters |
| `bySubscription` | Claude only: per claude-swap account name |
| `topModels` | per model |
| `tokenTypes` | input, output, cache read, cache write |
| `dailyTokens` | one number per day, oldest first |

Each row is `{"label": "...", "tokens": 123, "costUSD": 1.23}`.

Costs are API-equivalent estimates, not what a subscription bills. Labels are display names
(account aliases, macOS user names, model names). No emails, account ids or tokens are written;
the write is refused if anything that looks like a secret appears.

## Examples

```
jq '.claude.bySubscription' ~/Library/Application\ Support/AgentMeter/agentmeter-usage.json
```

```
jq -r '.all | "\(.todayTokens) tokens today, $\(.todayCostUSD)"' ~/Library/Application\ Support/AgentMeter/agentmeter-usage.json
```

```
jq '.codex.topModels[:3]' ~/Library/Application\ Support/AgentMeter/agentmeter-usage.json
```
