# HANDOFF — J12 target-machine battery re-run (for Cori)

**From:** Claude (fix lane) · **To:** Cori (build/QA, evidence) · **Then:** Vesper close-out → Tracy accepts
**Date:** 2026-10-12 · **Target:** `main`. The code under test is commit `32b7274`, "J12 fixes: Vesper QA round — 5 S2 + 13 S3". Later commits only touch this handoff.

**Read this first.** It replaces the conversation history. If you need detail on any finding, it's in `docs/QA-J12-FIXES.md`. Don't re-derive anything else.

## Why you're needed

All 5 S2s and 13 S3s from Vesper's J12 review are fixed, and every battery is green, but **only on Linux**: Playwright Chromium, a **fake** LT engine on 8081, and stand-ins for `otool`/`xcode-select`. Each new assertion was also shown to fail on the original code, so the tests do catch their bugs.

What hasn't been proven is real Chrome 128 + real LT 6.6 + real otool on the 2012 MBP. **That run is the job. Run and report only: no code fixes, no pushes, no merges.**

## Setup (once)

**No GitHub access needed.** Tracy has already pulled `main` into the local repo. These are local git only, so don't fetch or pull.

```sh
cd ~/workspace/grammar-tool
```
```sh
git branch --show-current
```
Expect: `main`

```sh
git log --oneline -1 -- extension scripts tests
```
Expect: `32b7274 J12 fixes: Vesper QA round — 5 S2 + 13 S3` (the last commit that changed any code)

```sh
git status --short
```
Expect: no output

If any check doesn't match, **stop and ask Tracy**. Don't fix it yourself.

**Preconditions** (all were already true on this machine after J11; confirm, don't redo):
- `engine/LanguageTool-6.6/` present (else run `sh scripts/fetch-engine.sh`)
- `~/jdks/jdk-17.0.20.1+1` patched, and `~/jdks/temurin17-jdk.tar.gz` still cached (L1 extracts a fresh, **unpatched** copy from it)
- `vendor/lwa-extension.pem` present (dict-battery derives the extension ID from it)
- CommandLineTools installed: `xcode-select -p` prints a path (otherwise L1 SKIPs by design)
- Nothing of yours on ports 8082, 8083, or 8091. The batteries kill whatever listens on 8082/8083.

## Run (in this order, ~5 min total)

`/tmp/lwa-capture.jsonl` and `/tmp/lwa-driver-report.json` get overwritten by the next battery, so **copy them right after any battery that fails** (command below).

```sh
mkdir -p /tmp/j12
```
```sh
sh scripts/launcher-battery.sh 2>&1 | tee /tmp/j12/launcher.txt
```
(No Chrome; uses port 8091 and never touches the engine on 8081.)

```sh
sh scripts/forms-battery.sh 2>&1 | tee /tmp/j12/forms.txt
```
```sh
sh scripts/overlay-battery.sh 2>&1 | tee /tmp/j12/overlay.txt
```
```sh
sh scripts/gmail-battery.sh 2>&1 | tee /tmp/j12/gmail.txt
```
```sh
sh scripts/dict-battery.sh 2>&1 | tee /tmp/j12/dict.txt
```

**After any FAIL**, before running the next battery (replace `NAME` with the battery name):
```sh
mkdir -p /tmp/j12/NAME-fail
```
```sh
cp /tmp/lwa-capture.jsonl /tmp/lwa-driver-report.json /tmp/j12/NAME-fail/
```

## Expected (green = these exact lines)

| Battery | Expect | New this round (the J12 proof) |
|---|---|---|
| launcher | `LAUNCHER BATTERY: ALL GREEN`, L1–L4 PASS | all four (S2-5) |
| forms | `FORMS BATTERY: ALL GREEN`, T1–T8 PASS | T7 retype (S2-1), T8 cc-* textarea (S3-1); T5/T6 are back (J6 driver restored) |
| overlay | `OVERLAY BATTERY: ALL GREEN`, O1–O7 PASS | O6/O7 two fields at once (S2-2) |
| gmail | `GMAIL BATTERY: ALL GREEN`, G1–G8 + privacy PASS | G7 minimize clears, G8 restore re-renders (S2-3) |
| dict | `DICT BATTERY: ALL GREEN`, U1–U5 PASS | U4/U5 live page follows dict add/remove (S2-4) |

## Where a real-machine failure is most likely (check these first)

1. **O1 / O4: LT match ordering.** The assertions are unchanged from J7 (green then), but the fake engine only imitated LT. A FAIL here where `counts=` / `richAfter=` shows a different first match means ordering, not the fix.

2. **L1 / L2: real `otool` output.**
   - If L1 fails with `preflight ok`, re-extract by hand (the battery deletes its copy) and send the output of these three:
     ```sh
     mkdir /tmp/j12/jdk
     ```
     ```sh
     tar xzf ~/jdks/temurin17-jdk.tar.gz -C /tmp/j12/jdk
     ```
     ```sh
     otool -L /tmp/j12/jdk/jdk-17.0.20.1+1/Contents/Home/lib/libawt.dylib
     ```
   - If L2 fails (the *patched* JDK reported as unpatched), that's the important one. Send the output of:
     ```sh
     grep -l JavaRuntimeSupport ~/jdks/jdk-17.0.20.1+1/Contents/Home/lib/*.dylib
     ```
     ```sh
     otool -L ~/jdks/jdk-17.0.20.1+1/Contents/Home/lib/libawt.dylib
     ```

3. **T5 (debounce exactly-one) on the slow chip.** It was fragile in J6 too. The popup dictionary driver used to run in every battery; now it runs only in dict-battery, so T5 should be *less* noisy than before. If it fails anyway, include the `part5=` / `part1-4=` numbers from the FAIL line.

4. **U4/U5 timing.** The popup waits up to 20 s for the fixture's first underlines, and up to 10 s after each add/remove. A cold engine on the first run could miss the 20 s budget: re-run dict-battery **once** with the engine already warm. A second fail is real.

5. **G7/G8 timing.** These rely on ResizeObserver + one animation frame within 400 ms / 800 ms. The fixture tab is in the foreground, so this should hold. If not, include the `rectsBeforeMinimize` / `clearedAfterMinimize` / `afterRestore` numbers.

The rule from the brief still holds: "flake" is not a root cause. One re-run per battery max, and only if the failure looks like a cold start (engine warmup, first Chrome launch).

## Quick manual smoke (optional, ~2 min)

Tracy has already reloaded the extension in her daily Chrome. In that profile:
- Type `Their was a obvious mistake.` in two different text boxes on any page: **both** keep their underlines.
- Popup → add a flagged misspelled word to the dictionary → its underline disappears without typing.

## Report back (paste to Tracy, she routes it)

```
J12 target re-run — code 32b7274 — <date>
launcher: <ALL GREEN | FAIL Lx: line>
forms:    <...>
overlay:  <...>
gmail:    <...>
dict:     <...>
re-runs used: <none | battery + reason>
attachments: /tmp/j12/*.txt (+ *-fail/ folders)
```

**All green** → Vesper finishes the close-out pass on code commit `32b7274` (it may already be under way).
**Any red** → back to Claude with the failing line and its `-fail/` capture files.

## Still open, not yours

- **S3-12:** wording of the 8082 battery-entry paragraph in spec §3.3. Tracy approves.
- **Live-Gmail checklist** (`docs/extension-gmail.md`, now with minimize → restore). Tracy's, pre-declared.
- S3-2 (per-field abort) and S3-6 (2nd-compose id suffix) were verified by review only. No battery observes them, and that's documented.
