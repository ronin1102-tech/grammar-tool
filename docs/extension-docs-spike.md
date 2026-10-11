# J10 — Google Docs canvas spike: ship-or-defer (decision dossier)

**DECIDED (Tracy, 2026-10-12): DEFER Google Docs to v1.1.** Recorded in `docs/v2.txt`
  (parking lot). The probe kit (§4) is the re-entry path if v1.1 picks this up.
**Round type:** decision, not feature build. Half-session, per HANDOFF-2026-10-11 queue
item 1. Deferral to v1.1 is the stated fallback in the v1 spec (§3.3: "highest-risk v1
item; if it proves unstable, Docs ships as v1.1") and is an acceptable outcome.

**Decision owner:** Tracy. This doc supplies the evidence and a recommendation;
it does not make the call (matches the v1 spec's Open Decision Matrix pattern).

---

## 1. The question

The product is extract → check → underline → one-click apply. Gmail + forms ship all
four steps on real editable DOM. The Docs canvas breaks step 1 (text is painted on
`<canvas>`; no textarea/contenteditable to observe) and possibly step 4 (apply). The
spike answers: **is there a stable-enough extract+apply path to justify building the
Docs module in v1 — or does Docs defer to v1.1?**

## 2. Facts (verified this session, with sources)

- **Market prior:** LanguageTool's own funded extension supports Google Docs, and its
  public support record shows recurring breakage specifically on Docs (support.google.com
  thread 441336929; forum.languagetool.org threads 11996, 9231, 10749). Not a reason to
  skip Docs — but it sets the stability prior: this surface breaks *even funded teams*.
- **The known technique** (ZisCoding/gdocs-editor, MIT, single-commit POC — source read
  in full this session, `content-scripts/helper/gdocs-helper.ts`):
  - **Extraction:** the canvas accessibility layer exposes each rendered text line as an
    SVG `rect[aria-label="<line text>"]` inside `.kix-canvas-tile-content` SVGs; the
    selection layer's `rect[fill]` elements carry the same `transform`, which is how the
    POC isolates selected lines. Sorts by y then x, groups lines. This is DOM-readable —
    no pixel OCR — but it is Google's *internal* accessibility markup, not a contract.
  - **Apply:** synthetic (untrusted) `KeyboardEvent`s dispatched into
    `.docs-texteventtarget-iframe` — `Delete` clears the selection, then **one keypress
    event per character**. This is the same event path LT's extension races on.
  - **Scope limit:** the POC only does selected-text→replace. Document-wide extraction
    and offset mapping (what our pipeline actually needs) do not exist in it — that part
    is ours, and it is the harder half (see gate G3).
- **POC self-assessment:** "proof-of-concept… Not production-ready… may break if Google
  changes their editor structure." 1 commit, 5 stars, no maintenance.

## 3. What this rig can and cannot prove (honest split)

- **Cannot prove locally:** anything about live Docs. The canvas tiles are painted by
  Google's own app JS; a local fixture mimicking the kix DOM would only verify our
  assumptions back to us (same caveat as gmail.md's fixture note, but total here: the
  fixture *is* the thing under test, so it proves nothing).
- **Can prove locally:** nothing useful *before* the decision. Pipeline-fit code
  (module shape, dispatch, overlay-at-rect) is only worth building **if the decision is
  SHIP** — building it now is the speculative work the spike exists to prevent.
- **Therefore:** the probe kit below is a live-doc checklist (owner: Tracy — needs a
  logged-in Google account and network), same pattern as the live-Gmail pass. ~3 minutes.

## 4. Probe kit (live Docs, ~3 min, with the extension loaded)

Setup: `scripts/launcher.sh start` → load the extension (same isolated-profile command
pattern as ext-battery.sh, but navigating to a real `docs.google.com/document/...`).
Paste two sentences into a blank doc, one with a planted error:
`Their going to the store. Then they will return home.`

| # | Probe | Pass signal | Feeds gate |
|---|---|---|---|
| P1 | Run `document.querySelectorAll('rect[aria-label]').length` in DevTools on the doc | ≥ number of visible text lines; labels contain the pasted text | G1 |
| P2 | Select the error sentence with the mouse; re-run the POC's selection query shape (rects sharing `transform` with selection-layer rects) | selection text reads back exactly `Their going to the store.` | G1 |
| P3 | Dispatch the POC's Delete+keypress sequence into `.docs-texteventtarget-iframe` targeting the selection (or simply verify our apply path lands) | text replaced, no dropped/duplicated chars, undo (⌘Z) restores in one step | G2 |
| P4 | With module built (only post-SHIP): full loop — underline appears, click applies, re-check fires | end-to-end green | G3 |

P1–P3 are decision evidence; P4 is post-decision build proof.

## 5. Decision gate

- **SHIP** iff P1+P2+P3 all pass AND the extraction maps to a stable offset space
  (line-rect text concatenation is deterministic across re-renders — check by scrolling
  and re-running P1: same concatenation). Then: module spec + battery-first build next
  round, P4 as its battery anchor.
- **DEFER** if any of: extraction text lacks stable geometry/offsets; apply drops or
  duplicates characters; undo breaks; or the technique requires a patch cadence against
  Google drift that v1 (one maintainer, 2012 MBP) can't commit to. On DEFER: line goes
  in `v2.txt` (parking lot already names it: "Google Docs if deferred from v1"), no code
  is written, and this doc records the decision date + evidence.

## 6. Recommendation (Cori, 2026-10-12) — **DEFER to v1.1**, confidence moderate-high

Reasoning, ranked by weight:
1. **The only known write path is per-character untrusted synthetic events into an
   undocumented event target.** Google actively hardens this exact surface (it is the
   path every automation tool races). Any hardening pass breaks apply *silently* —
   and apply-breaks means we've shipped an underline the user cannot act on, which is
   worse than no Docs support at all (our product promise is one-click apply, not hints).
2. **Extraction (read) is genuinely promising** — aria-label rects are clean text and
   would likely survive into v1.1 fine. The weak half is the write, and the product
   needs both.
3. **Maintenance shape:** LT's funded team still takes recurring Docs breakage reports;
   our rig is one maintainer on a 2012 MBP with a Chrome-128 ceiling (frozen browser on
   Catalina actually *helps* stability here — Chrome 128 is pinned — but the drift risk
   is on Google's server-rendered app JS, which we don't control even with a pinned
   browser).
4. **v1 value math (per the v1 spec's own words):** "Gmail + standard forms cover the
   daily core." Docs adds real value, but it is the only scope item with a live-drift
   failure mode; v1.1 lets it land after the QA round hardens the four shipped surfaces.

Confidence is moderate-high, not certain: P1–P3 might well pass today. The deferral case
is about *maintenance exposure over weeks*, not whether the trick works once.

**What flips this to SHIP:** Tracy runs P1–P3, all pass, and he judges the drift
maintenance acceptable for v1. The probe kit above is the whole cost of finding out.

## 7. Owner-flagged (unverified, by definition)

- All live-Docs probes (P1–P3): **Tracy** — requires logged-in Google account.
- Chrome 128 behavior on the kix aria-label layer: unverified anywhere; P1 doubles as
  its check (frozen Chrome makes this a one-time check, not ongoing drift).

---
*Spike by Cori, 2026-10-12. Sources: support.google.com/docs/thread/441336929;
forum.languagetool.org/t/11996, /t/9231, /t/10749; github.com/ZisCoding/gdocs-editor
(source read in full, MIT); docs/PHASE_0_VERIFICATION_AND_V1_SPEC.md §3.3.*
