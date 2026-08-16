# Off-device test harness

Runs a whole book through the real analysis path without a Kindle, so a prompt
change, a model change or a provider change can be judged before it is copied to
a device. Nothing here is loaded by KOReader — the plugin only ever loads
`main.lua`, so this folder is inert on the device.

It exercises **shipped code, not copies of it**: `lib/llm.lua`'s `createPrompt`
and `validateAndCleanData`, and `main.lua`'s `applyChapterFilter`/`fuseCharacters`,
are loaded from the plugin folder with KOReader's own modules stubbed out.

Needs `lua` and `python3` on PATH. No Lua dependencies — the reply is converted
to a Lua literal instead of parsed, so `json` never has to be available.

## Run it

The book, and everything derived from it, live in `private/fixtures/`
at the repo root, which `.gitignore` excludes in full. See *The fixture* below.
Every step reads and writes there; nothing large or book-derived is written
into the plugin folder.

```sh
cd test
export OPENROUTER_API_KEY=sk-or-v1-...
FIX=../../private/fixtures

# 1. book -> chapter-marked text, the way lib/booktext.lua does it
python3 extract_epub.py $FIX/book.epub $FIX/book_text.txt

# 2. text -> the exact prompt lib/llm.lua would send
lua build_prompt.lua .. $FIX/book_text.txt $FIX/prompt.txt

# 3. one request, same body and SSE handling as callChatGPT.
#    Second argument is the reasoning effort, default "high" to match the
#    provider table. "none" sends no reasoning field, which is the provider's
#    own default rather than off -- thinking cannot be disabled on this model.
#    Reads $FIX/prompt.txt and writes $FIX/reply_<model>[_<effort>].json;
#    override the directory with GRIMORIA_TEST_WORK=<dir>.
python3 call_openrouter.py google/gemini-3.7-flash high

# 4. structural + spoiler checks on the reply
python3 validate.py $FIX/reply_google_gemini-3.7-flash.json

# 5. the same reply through the shipped Lua filter
python3 json_to_lua.py $FIX/reply_google_gemini-3.7-flash.json $FIX/reply.lua
lua test_filter.lua .. $FIX/reply.lua
```

Step 3 costs real money — order of $0.08–0.11 per run of a full-length novel
on `google/gemini-3.7-flash`, more with reasoning raised, since thinking tokens
are billed as output tokens on top of the answer. Steps 4 and 5 are free and can
be re-run against a saved reply as often as you like;
`reply_google_gemini-3.7-flash.json` (no reasoning) and
`reply_google_gemini-3.7-flash_high.json` (`high`) are kept as regression
fixtures and as the two sides of the comparison.

The number to watch in step 3 is the `budget:` line. Thinking and answering come
out of the same 64000-token completion budget, and that is already the model's
ceiling, so a run that leaves little headroom is one truncation away from the
effort step-down in `callChatGPT`.

Nine free offline suites need no key and no book:

```sh
lua smoke_openrouter.lua ..   # provider table, routing, main.lua entry points
lua test_cancel.lua ..        # the cancel confirmation on the in-flight fetch
lua test_localization.lua ..  # language discovery, .po parity, format specifiers
lua test_wiring.lua ..        # every method resolves after the lib/ mixin
lua test_updater.lua ..       # self-update: swap, rollback, revert
lua test_spoiler.lua ..       # the governing rule, on synthetic fixtures
lua test_mentions.lua ..      # appearance counting, the scan boundary, position restore
lua test_range.lua ..         # section analyses keep the book's own chapter numbers

# reads files written before the plugin was renamed; needs a built fixture
python3 make_legacy_fixture.py tmp_fixture
lua test_legacy.lua .. tmp_fixture
```

`test_spoiler.lua` also takes a saved reply, and that is where it earns its
keep — see below.

`smoke_openrouter.lua` asserts that a provider with an `endpoint` routes to
`callChatGPT` while Gemini does not, that the `custom` provider's placeholder
endpoint names no private host and still routes, and that `main.lua` loads.

`test_localization.lua` covers the interface language end to end: that exactly
`en` and `vi` are discovered, that switching to Vietnamese actually parses
`vi.po` rather than silently falling back to English, that the two `.po` files
carry identical keys, that no key formats differently between them (a `%s` in
one and not the other silently drops the value), and that every `loc:t()` call
site resolves — across `main.lua` **and every file in `lib/`**. It read
`main.lua` alone until Phase 3, which stopped being right when the plugin was
split: almost every user-facing string is built in `lib/` now. The file list is
written by hand inside the suite, so a new module has to be added to it.

**Rebuild the legacy fixture before every run.** `test_legacy.lua` exercises
*writes* as well as reads, so it mutates the fixture it was given; a second run
against the same directory fails on checks that passed the first time.
`make_legacy_fixture.py` deletes and recreates the tree, so re-running it is
the whole fix.

`test_legacy.lua` covers reading what the plugin wrote under its old name --
settings and, more to the point, finished analyses that cost real money. The
rules are: reads prefer the current name and fall back to the old one, writes
always use the current name, and nothing on disk is renamed or deleted. Its
fixture is built by `make_legacy_fixture.py` because pure Lua cannot create a
directory; the files in it are empty markers and a placeholder key, since the
test only ever asks which path gets opened.

`test_wiring.lua` loads the plugin and asserts all 95 methods are present after
the ten `lib/` modules are mixed onto the class. Without it, a module left
off the mixin list loads perfectly and then fails with "attempt to call a nil
value" the first time someone opens that menu.

`test_mentions.lua` covers Chapter Appearances, and the three things it has to
get right are each invisible when wrong. Counting a PERSON rather than a string:
"Ellery Queen said. Ellery nodded." is two mentions, not three, so the spans
every spelling matches are merged before counting. The BOUNDARY: the scan stops
at the reader's position, because "appears 40× in chapter 50" says the character
is alive in chapter 50 — the suite asserts that a character who only appears
past the limit has no count anywhere in the result. And the reading POSITION,
which building the chapter list moves and the scan has to put back.

`test_range.lua` covers section analyses, and really covers one number. Asking
for chapters 30-40 must emit `=== CHAPTER 30 ===` first, never renumbering the
range to start at 1 — renumbering is the obvious implementation and breaks
everything quietly, because the model tags its answer with the numbers it was
given and the spoiler filter compares those against `getChapterList`. It also
checks that a whole-book run reports no range at all, since that is what decides
whether the prompt tells the model it is only seeing part of the book.

`test_spoiler.lua` is the acceptance test for the spoiler design. Where
`test_filter.lua` checks that one known reveal is handled correctly,
this one asserts the general property — **at chapter *k*, no visible field may
name an entity the reader has not met, and no value tagged later than *k* may
render** — sweeping every chapter of whatever reply it is given, over
characters, locations, themes, timeline entries and historical figures. Every
leak found in this plugin so far was a case nobody had thought to test.

Given a reply it runs the sweep **twice**: once on the analysis as the model
wrote it, then again after `lib/spoilerguard`. The raw number is reported
rather than asserted — a model writing a leak into its prose is a fact about
the model — but the guarded pass must come back clean, and a separate check
fails if the guard is ever holding back more than a small fraction of the
analysis, so "0 leaks" can never be bought by hiding the book.

```sh
lua test_spoiler.lua .. ../../private/fixtures/reply.lua
```

`reply_tagged.lua` is the first reply produced under the chapter-tagged schema
(`google/gemini-3.7-flash`, no reasoning, $0.079, 110.9s, 21,202 of 64,000
completion tokens). It is the fixture that proves the schema is one a model
actually follows: 42 of 42 character fields and 7 of 7 locations came back as
`[{value, first_chapter}]` lists, and one field came back genuinely
multi-valued — a character whose role is `Supporting` from chapter 12 and
`Antagonist` from chapter 47, which is exactly the leak that started this work.

Three things it deliberately does *not* treat as leaks, all three learned by
running it and watching it cry wolf:

- **A name in prose bound to a chapter the reader has read.** If chapter 12
  says "they plan to go to Ajimu tomorrow", hiding that hides the book from
  itself. Only *unbound* text — an intro, a role, a theme — is checked against
  unmet names.
- **A merge member's name as such.** The members of an identity merge are
  usually all met early, so what is secret is the **connection**, not the
  names. Checking the names flagged 548 non-leaks on one book.
- **Diacritic-folded matches.** Folding looks obviously right for Vietnamese
  and is obviously wrong: `Văn` (literature), `Vấn` (suspicion) and `Van` (a
  name) are three different words. A folded matcher reported a leak on
  `nghi vấn` and hid two characters introduced as literature students.
  `validate.py` had already recorded this; the Lua side rediscovered it.

The suite states its own blind spot too: it matches names, so a semantic leak
carrying no name — a summary that foreshadows in the abstract — is invisible
to it, and stays the prompt's responsibility.

`test_updater.lua` covers the self-update, and the property it proves is not
"the happy path works" — it is that **no failure leaves a half-installed
plugin**. A botched update produces a Kindle whose plugin no longer loads, with
the paid analyses still on it and no console to find out why, so the test runs
the updater against an in-memory filesystem and injects a rename failure at the
exact instant when half of the new version is in place and half of the old one
is in the backup. It then asserts every file of the old version is back byte
for byte. It also covers the unrecoverable case — a filesystem that stops
accepting renames entirely, where the rollback cannot run either — and asserts
the updater *reports* that and names the backup folder rather than claiming a
rollback that did not happen. Plus: manifest paths that try to escape the
plugin folder are rejected, `test/` is never touched in either direction,
settings and `.sdr` analyses survive an update and a revert, and a file the new
release drops is removed from the install but kept in the backup.

`test_cancel.lua` covers the widget shown during the request: a tap anywhere —
including on the message itself — must open a confirmation rather than kill the
job, only an explicit "Cancel analysis" kills it, and a request that finishes
while the confirmation is open must not leave a button that resumes a dead
coroutine.

## The fixture

Steps 1–5 need a book, and no book ships with this repository — redistributing
one is not ours to do. Put your own EPUB at `$FIX/book.epub`; anything derived
from it (extracted text, built prompt, model replies) is written beside it in
`private/`, which `.gitignore` excludes in full.

The consequence is worth stating plainly: **for a fresh clone, steps 1–5 and
`test_filter.lua` cannot run.** The nine offline suites above work out of the
box; nothing that needs a book does.

## Choosing one

Not any book will do. The design's hardest case is a *late-revealed identity* —
a character the text presents under two names and does not connect until near
the end. That is the only shape that exercises `identity_merges` and the
chapter-gated fuse, which is the whole point of the plugin: a reader stopped
just before the reveal must still see two unrelated people, and one chapter
later a single merged card.

A public-domain book with that structure would let the harness ship runnable to
everyone, and finding one is open work.

## What "passing" means

Against a real reply, the tests assert:

- every chapter extracted and numbered 1..N, matching the device's TOC handling
- every character has an integer `first_chapter` and in-range `by_chapter` entries
- `identity_merges` only names characters that were actually listed
- before the reveal chapter: the two identities are separate cards, no fused
  card exists, and neither one's text names the other
- at the reveal chapter: a single merged card carrying the revelation, with a
  history tagged by which identity did what
- themes are chapter-tagged objects, so they filter like everything else

`validate.py` and `test_filter.lua` take the expected names and chapter numbers
from the reply and from constants at the top of each file; point them at a
different book and those constants are what you change.

## Other books

Steps 1–2 assume an EPUB with a `toc.ncx` whose entries are anchors into a few
XHTML files, which is the common Calibre output.
