# Loop SDK conformance cases

Shared, platform-neutral test cases that define how every Loop SDK behaves.
Each platform has a runner that loads these JSON files and drives its own SDK
through them:

| Platform | Runner |
|---|---|
| Dart (reference) | `loop-sdk-flutter/test/conformance_test.dart` |

Cases live in `cases/<area>/NN-slug.json` (today only `cases/analytics/`).
`schema.json` is a JSON Schema (draft 2020-12) for a case file.

## Case format

A case file is one JSON object:

```json
{
  "name": "human-readable title",
  "options": { "flushQueueSize": 30, "flushIntervalMs": 30000, "minTimeBetweenSessionsMs": 300000,
               "maxQueueSize": 1000, "maxBatchSize": 100, "legacyDeviceId": null },
  "steps": [ { "op": "…" } ],
  "expect": { "requests": [ … ], "queueLength": 0 }
}
```

All `options` keys are optional (defaults above). The runner's fixed environment:

| Thing | Value |
|---|---|
| API key | `loop_pk_test` |
| Server | `https://loop.test` |
| Clock start | `1767225600000` ms (`2026-01-01T00:00:00.000Z`); only `advance` moves it |
| Event ids | `00000000-0000-4000-8000-000000000001`, `…002`, … (counter shared across restarts within a case) |
| New device ids | `DEVICE-1R`, `DEVICE-2R`, … (counter shared across restarts) |
| Context source | `{"platform":"iOS","osName":"ios","osVersion":"18.0","appVersion":"1.0.0","appBuild":"1","deviceModel":"iPhone15,3","deviceManufacturer":"Apple","isTablet":false,"locale":"en-GB"}` — the SDK adds `purchaserId` and `sdk` itself |
| Lifecycle | app starts in the foreground on every (re)start |
| HTTP | each request is recorded (gzip-decoded JSON body + headers); reply = next queued `respond`, else `202 {"accepted":<n>,"dropped":0}` |
| Storage | persists across `restart` within a case; empty at case start |

After **every** step the runner waits until the SDK is idle (no upload in flight, all writes done).

Ops:

| op | fields | meaning |
|---|---|---|
| `track` | `name`, `props` (object, optional), `fill` (optional `{"key":K,"count":N}` → sets `props[K]` to `"x"` repeated N times) | `track(name, props)` |
| `setUserId` | `userId` (string or null) | |
| `setUserProperties` | `props` | |
| `setPurchaserId` | `purchaserId` (string or null) | |
| `flush` | | `await flush()` |
| `reset` | | `await reset()` |
| `setOptOut` | `optOut` (bool) | |
| `advance` | `ms` | move the clock forward; fire every periodic flush timer that came due, in order |
| `lifecycle` | `state`: `foreground` \| `background` | |
| `respond` | `status`, `headers` (optional object), `body` (optional string) — or `{"op":"respond","error":"network"}` | queue the reply for the next request |
| `restart` | `options` (optional, replaces the case options) | dispose the instance and start a new one over the same storage |
| `check` | `requests` (int, optional), `queueLength` (int, optional) | assert the running totals now |

`expect` keys (all optional): `requests` — array matched one-to-one, in order, against all recorded request bodies (count must be equal); `queueLength` — events still queued at the end.

Matching: objects match **exactly** (same key set) unless the expected object contains `"$partial": true`, in which case only the listed keys are compared. Arrays match exactly (same length, element-wise). Special expected values:
- `"<uuid>"`, `"<int>"`, `"<iso8601>"`, `"<any>"` — any UUID string / integer / ISO-8601 string / any value present.
- `{"$stringLength": N}` — a string of length N.
- `{"$sameAs": "requests[0].events"}` — deep-equal to that path of the **actual** recorded requests.

Every recorded request must also have path `/api/ingest/analytics/batch`, `Authorization: Bearer loop_pk_test` and `Content-Encoding: gzip` (the runner asserts this for every case).

## Writing a runner

- Map each `options` key onto the SDK's own option (`flushIntervalMs` and
  `minTimeBetweenSessionsMs` are milliseconds); the server URL is always
  `https://loop.test`.
- Drive all time from one fake clock so `advance` is deterministic; never
  sleep for real.
- Response header names are case-insensitive.
- A case the SDK under test is known to fail stays in the suite; the runner
  skips it with a reason that names the bug.
