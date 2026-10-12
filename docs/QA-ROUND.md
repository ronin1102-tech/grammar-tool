# J12 — QA Round Brief (Vesper)

**Round:** J12, the final v1 scope item. **Date opened:** 2026-10-12.
**Reviewer:** Vesper (QA lane — you flag, you never fix, you never push).
**Fix lane:** Claude. **Acceptance:** Tracy. **Build/QA support:** Cori (evidence on request).

## Read order (in this repo, in this order — nothing else needed)

1. `docs/HANDOFF-2026-10-11.md` — state of every job J1–J11, port map, rig invariants.
2. `docs/PHASE_0_VERIFICATION_AND_V1_SPEC.md` — Part 3 is the v1 contract (§3.3
   extension, §3.5 job list, §3.6 definition of done). Part 1 is the verified
   hardware/engine baseline your findings can cite.
3. The ONE spec doc for the area you're drilling (below), then that area's source.

## Repo facts

- HEAD as of this brief: `a850b12` (main). Machine: 2012 MBP, Catalina 10.15.7, Chrome 128.
- `vendor/` + `engine/` artifacts are gitignored; reproducible via `scripts/fetch-engine.sh`.
- Extension ID pinned by manifest `key`. **Chrome displays IDs in a letters-only a-p
  alphabet**: on screen it reads `hcnbhjnmgnbpnelbpjakhmegdpinhago`; the same ID in hex
  is `72d179dc6d1fd4b1f90a7c463f8d706e` (that's the form used in docs' port map).

## Suggested drill order (highest user value first)

| # | Area | Spec doc | Source |
|---|---|---|---|
| 1 | Extension core: extraction, debounce, secret guards | `docs/extension-content-script.md` | `extension/content.js`, `extension/background.js` |
| 2 | Overlay + apply (the product promise) | `docs/extension-overlay.md` | `extension/overlay.js` |
| 3 | Gmail surface | `docs/extension-gmail.md` | `extension/gmail.js` |
| 4 | User dictionary | `docs/extension-user-dict.md` | `extension/popup.js`, `popup.html` |
| 5 | Launcher + applet | v1 spec §3.2 | `scripts/launcher.sh`, `scripts/make-app.sh` |
| 6 | Engine setup reproducibility | v1 spec §3.4 | `scripts/fetch-engine.sh`, `scripts/patch-jdk.sh`, `engine/server.properties` |
| 7 | Install walkthrough claims | `README.md` | — (claims vs. scripts) |

## Verified state (do not re-derive; challenge only with evidence)

All batteries green this session set: J6 6/6 · J7 5/5 · J8 7/7 (incl. undo proof on
fixture) · J9 3/3 · J5 red/green · J1–J4 red/green + ~16 checks. J11 evidence battery:
fresh-clone layout, fetch cached path, launcher start/status/stop, make-app build,
extension first health POST in both engine states (ok:false / ok:true 458 ms), stable ID
derived from manifest key. Live-confirmed by Tracy: checking works in Cori chat input
and live Gmail compose. Full claim-by-claim log: git log + `README.md` footer.

## Pre-declared known-open (NOT findings — already owned)

- **Live-Gmail formal checklist** (undo, dialog lifecycle on live Gmail): Tracy's,
  pending. Fixture-proven; live pass informal so far.
- **Docs surface**: deferred to v1.1 by decision (dossier: `docs/extension-docs-spike.md`).
- **iframe-embedded fields** (no `all_frames` in manifest) and **shadow-DOM fields**
  (`document.contains` guard): logged v1.1 candidates from Tracy's field use.
- README footnote already states: manual chrome://extensions flow proven via
  `--load-extension` equivalence, not by clicked clicks.

## What a finding looks like (so fixes land clean)

One finding per block, severity-tagged, routed:
- **S1** = breaks the product promise (apply corrupts text, secrets leak, engine
  exposed beyond loopback) → Claude immediately, Tracy before merge.
- **S2** = wrong-but-recoverable (stale overlay, missed surface, doc claims a command
  that doesn't exist) → Claude fix + battery re-run.
- **S3** = polish/docs → batched into the close-out commit.
Format: `SEVERITY · file:line (or URL) · expected vs observed · suggested fix (you
suggest, Claude decides implementation) · how Claude can verify`.

Corollary for doc findings: every command in README/handoffs was executed this session
set — if one doesn't work for you, that's an S2 environment finding, not a typo.

## Boundaries (standing rules, unchanged)

- Read-only: no edits, no pushes. Findings in chat (paste-able) — Tracy forwards.
- Engine runs on 127.0.0.1:8081 only; `--public` must NEVER appear in any suggested
  command (that flag is the LAN-exposure risk the whole design avoids).
- v1 scope is frozen: findings about missing features route to `docs/v2.txt` parking
  lot, not the fix lane.

## Exit criteria (Tracy accepts when)

- Vesper: findings list delivered (or explicit "no findings at severity").
- Claude: every S1/S2 fixed or explicitly disputed with evidence; batteries re-run.
- Tracy: accepts; handoff updated; v1 formally closed.
