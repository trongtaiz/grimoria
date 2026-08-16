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
python3 extract_epub.py $FIX/thap-gian-quan.epub $FIX/book_text.txt

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

Step 3 costs real money — about $0.09 per run on `google/gemini-3.7-flash` for
this book with no reasoning asked for, and more with it, since thinking tokens
are billed as output tokens on top of the answer. Steps 4 and 5 are free and can
be re-run against a saved reply as often as you like;
`reply_google_gemini-3.7-flash.json` (no reasoning) and
`reply_google_gemini-3.7-flash_high.json` (`high`) are kept as regression
fixtures and as the two sides of the comparison.

The number to watch in step 3 is the `budget:` line. Thinking and answering come
out of the same 64000-token completion budget, and that is already the model's
ceiling, so a run that leaves little headroom is one truncation away from the
effort step-down in `callChatGPT`.

Five free offline suites need no key and no book:

```sh
lua smoke_openrouter.lua ..   # provider table, routing, main.lua entry points
lua test_cancel.lua ..        # the cancel confirmation on the in-flight fetch
lua test_localization.lua ..  # language discovery, .po parity, format specifiers
lua test_wiring.lua ..        # every method resolves after the lib/ mixin

# reads files written before the plugin was renamed; needs a built fixture
python3 make_legacy_fixture.py tmp_fixture
lua test_legacy.lua .. tmp_fixture
```

`smoke_openrouter.lua` asserts that a provider with an `endpoint` routes to
`callChatGPT` while Gemini does not, that the `custom` provider's placeholder
endpoint names no private host and still routes, and that `main.lua` loads.

`test_localization.lua` covers the interface language end to end: that exactly
`en` and `vi` are discovered, that switching to Vietnamese actually parses
`vi.po` rather than silently falling back to English, that the two `.po` files
carry identical keys, that no key formats differently between them (a `%s` in
one and not the other silently drops the value), and that every `loc:t()` call
site in `main.lua` resolves.

`test_legacy.lua` covers reading what the plugin wrote under its old name --
settings and, more to the point, finished analyses that cost real money. The
rules are: reads prefer the current name and fall back to the old one, writes
always use the current name, and nothing on disk is renamed or deleted. Its
fixture is built by `make_legacy_fixture.py` because pure Lua cannot create a
directory; the files in it are empty markers and a placeholder key, since the
test only ever asks which path gets opened.

`test_wiring.lua` loads the plugin and asserts all 66 methods are present after
the seven `lib/` modules are mixed onto the class. Without it, a module left
off the mixin list loads perfectly and then fails with "attempt to call a nil
value" the first time someone opens that menu.

`test_cancel.lua` covers the widget shown during the request: a tap anywhere —
including on the message itself — must open a confirmation rather than kill the
job, only an explicit "Cancel analysis" kills it, and a request that finishes
while the confirmation is open must not leave a button that resumes a dead
coroutine.

## The fixture — why it is not published

The book these tests were written against is an in-copyright novel, so neither
it nor anything derived from it (the extracted text, the built prompt, the
saved replies) can be published. All of it lives in `private/` at the
repo root, which `.gitignore` excludes in full — present on the machine that
does the testing, absent from every clone.

The consequence is honest and worth stating: **for anyone who clones this
repository, steps 1–5 and `test_filter.lua` cannot run.** The four offline
suites above work out of the box; nothing that needs the book does.

Replacing the fixture is unfinished work, and it is not a file swap. A
replacement needs to be public-domain (Project Gutenberg) *and* contain a
late-revealed identity — a character known under two names whom the text does
not connect until near the end — because that is the only case that exercises
`identity_merges` and the chapter-gated fuse. `validate.py` and
`test_filter.lua` hardcode the current book's names and chapter numbers; those
assertions have to be rewritten with it.

## What "passing" means

The current fixture was chosen because it has the hardest case the design has
to get right: two names that turn out to be one person, with the text
withholding the connection until chapter 47 of 56. A reader on chapter 46 must
still see two unrelated people.

So the tests assert, against a real reply:

- 56 chapters extracted and numbered 1..56, matching the device's TOC handling
- every character has an integer `first_chapter` and in-range `by_chapter` entries
- `identity_merges` only names characters that were actually listed
- at chapter 46: `Van` and `Morisu Kyoichi` are separate cards, no fused card,
  and neither one's text names the other
- at chapter 47: a single `Van (Morisu Kyoichi)` card, carrying the revelation
  and a history tagged with which identity did what
- themes are chapter-tagged objects, so they filter like everything else

## Other books

Steps 1–2 assume an EPUB with a `toc.ncx` whose entries are anchors into a few
XHTML files, which is the common Calibre output. `validate.py` and
`test_filter.lua` hardcode the Van/Morisu expectation, so for another book run
the structural half and read the spoiler half by hand.
