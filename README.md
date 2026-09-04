# Grimoria for KOReader

A spoiler-free, chapter-aware index of the book you're reading — characters,
locations, themes, timeline, historical figures — built from the book's own
text by an AI, on your e-reader.

It reveals itself as you read. Open it on chapter 3 and you see what a reader
on chapter 3 could know. Nothing more.

---

## How it works, and why that matters

Most tools like this send the book's **title** to a model and hope it remembers
the book. That fails on anything obscure, self-published, or translated, and it
has no idea where you are in the story.

This sends the **actual text**, split into chapters, exactly once. In return it
requires the model to tag every single entry with the chapter that entry belongs
to.

That one constraint is what makes the rest work:

- **Hiding what you haven't read is a local operation.** No second request, no
  extra cost, no network. The filter re-runs every time you open a view, so the
  index grows by itself as you turn pages.
- **One request per book, ever.** Not one per chapter, not one per view.
- **It works offline** after that first analysis, which matters on a device you
  read with on a plane.
- **It works on books no model has heard of**, because the text is right there.

### The hard case

A character called Van appears on the island. A man called Morisu Kyoichi
appears on the mainland. On chapter 47 of 56, the book reveals they are the
same person.

A reader on chapter 46 sees **two unrelated people**. On chapter 47 the two
cards fuse into one, carrying the revelation and a history tagged with which
identity did what.

The model reports these connections separately, as `identity_merges`, naming
the chapter where the *text itself* makes the link — and the merge is applied
only from that chapter on. Themes are chapter-tagged and filtered the same way,
because models will cheerfully name the murderer inside a theme description.

Coexisting clones, doubles, split selves, and timeline copies remain separate
characters and never appear in `identity_merges`.

---

## Requirements

- KOReader (Kindle, Kobo, reMarkable, Android, or the desktop build)
- An API key from one of: Google Gemini, OpenAI, OpenRouter, or any
  OpenAI-compatible endpoint
- A working internet connection **for the first analysis of each book only**

## Install

Copy the plugin folder into KOReader's `plugins` directory and restart:

| Device | Path |
|---|---|
| Kindle | `/mnt/us/koreader/plugins/grimoria.koplugin/` |
| Kobo | `.adds/koreader/plugins/grimoria.koplugin/` |
| Desktop / Linux | `~/.config/koreader/plugins/grimoria.koplugin/` |

## Set up a key

Open any book, then **Menu → Grimoria → AI Settings**, and paste a key for the
provider you want.

Keys are written to `<koreader>/settings/grimoria/`, which is **outside the plugin
folder** — so updating or re-copying the plugin can never clobber or leak them.
Never put a key in `config.lua`: that file ships inside the plugin folder and
travels with any copy of it.

| Provider | Get a key | Notes |
|---|---|---|
| **Google Gemini** | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | Has a free tier. Easiest start. |
| **OpenRouter** | [openrouter.ai/keys](https://openrouter.ai/keys) | One key, most models. Use the full slug, e.g. `google/gemini-3.8-flash`. |
| **ChatGPT** | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | Standard OpenAI endpoint. |
| **Custom** | — | Any OpenAI-compatible endpoint: a proxy, a local server. Set the endpoint yourself. |

## Analyse a book

**Menu → Grimoria → Analyze with AI.** You'll get one confirmation showing the
chapter count and a rough token estimate before anything is spent.

Then wait. A novel takes **several minutes** — up to about twenty for a long
one. While it runs:

- The screen stays live. Tap anywhere to cancel; you'll be asked to confirm, so
  a stray touch won't throw away a paid request.
- The device is held awake deliberately, so it can't sleep mid-request and drop
  the connection after the tokens are already spent.

Analyses are stored in the book's own `.sdr` sidecar folder, so they travel
with the book. You can keep **several analyses per book** — from different
models, say — and switch between them offline under
**Menu → Grimoria → Analysis versions**.

**Very long books** can ask for more per-chapter detail than one reply is
allowed to hold, and the fallback is to drop chapters off the end. If that
happens, use **Menu → Grimoria → Analyse a chapter range…** and take the book in
two halves. The chapter numbers stay the book's own, so the halves filter by
your reading position exactly like a full analysis.

An analysis made before quotes existed can pick them up without a full
re-analyse: **Menu → Grimoria → Extract quotes (AI)** patches the current
version in place. Re-analysing a book that already has quotes keeps that list
and spends the request on the rest of the index.

## Once it's analysed

Everything below is local: no network, no cost, and it works with wifi off.

- **Highlight a name on the page → "Look up in Grimoria"** opens that
  character's card. It only searches people you have already met, so it cannot
  be used to ask whether a name matters later.
- **Chapter appearances** — hold a name in the character list, or
  **Menu → Grimoria → Chapter appearances** — draws where in the book that
  person actually shows up, counted from the text itself, with a tap to jump
  there. It stops at the chapter you have reached: knowing somebody is named
  forty times in chapter 50 would tell you they survive to chapter 50.
- **The summary, themes and every card open as a full page** you can turn and
  close when you're done, with a heading per chapter — not a popup that
  disappears after fifteen seconds.
- **Quotes** sit at the bottom of the summary: lines worth keeping, copied
  verbatim from the text, only from chapters you have already finished. A
  short or dry book may have few, or none — 20 is a ceiling, not a target.
  They are also written to `<book>.sdr/grimoria_quotes.lua` for other KOReader
  patches (a sleep-screen set lives in this repo under `patches/`).

## What it costs

Measured on a 56-chapter novel (~420k characters) through OpenRouter before
the September 2026 price change:

| Setting | Historical cost | Time |
|---|---|---|
| `google/gemini-3.7-flash`, no reasoning | $0.081 | 116 s |
| `google/gemini-3.7-flash`, reasoning `high` | $0.107 | 187 s |

Those figures are retained as measurements, not current quotes. OpenRouter
pricing changes independently of the plugin; check the selected model's page
before analysing a large book. The shipped OpenRouter default is
`google/gemini-3.8-flash`.

Once per book. Gemini's free tier can bring that to zero. Reasoning tokens are
billed as output tokens on top of the answer, so lowering the effort is the
main cost lever. Gemini 3.8 supports `low`, `medium`, and `high`; omitting the
field uses its provider default rather than turning reasoning off.

Longer books cost more and take longer; twenty minutes is the realistic ceiling
rather than the norm.

---

## Languages

**The interface** is English or Vietnamese: **Menu → Grimoria → Language**.

**What the AI writes** is a separate setting, and by default it follows **the
book's own language** — a Vietnamese novel gets a Vietnamese index, a French
one gets French, whatever interface you're using. Character and place names
keep their original spelling either way, so they match the page in front of
you.

To force a specific output language, put its plain name in
`<koreader>/settings/grimoria/output_language.txt` (e.g. `English`). Leave it empty
or set `auto` for the default.

## Configuration

Three layers, each overriding the one before:

1. **`config.lua`** — ships inside the plugin folder. Model names and defaults
   only. **Never a key.**
2. **`<koreader>/settings/grimoria/*.txt`** — one plain-text file per setting,
   outside the plugin folder. This is where keys belong, and the main lever for
   debugging.
3. **Environment variables** — checked last, so they win over both.

Useful settings files:

| File | Purpose |
|---|---|
| `<provider>_api_key.txt` | The key |
| `<provider>_model.txt` | Model name or slug |
| `<provider>_endpoint.txt` | Base URL, for OpenAI-compatible providers |
| `<provider>_reasoning_effort.txt` | `minimal`, `low`, `medium`, `high`, `xhigh`, or `none` |
| `default_provider.txt` | `gemini`, `chatgpt`, `openrouter`, `custom` |
| `language.txt` | Interface language: `en` or `vi` |
| `output_language.txt` | What language the AI writes in |
| `max_text_chars.txt` | Cap on how much book text is sent |

Environment variables: `GEMINI_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
`GRIMORIA_CUSTOM_API_KEY`, plus `GRIMORIA_GEMINI_MODEL`, `GRIMORIA_OPENROUTER_MODEL`,
`GRIMORIA_CUSTOM_MODEL`, `GRIMORIA_CUSTOM_ENDPOINT`, `GRIMORIA_OPENROUTER_EFFORT`,
`GRIMORIA_CUSTOM_EFFORT`. On a Kindle, export them near the top of `koreader.sh`.

---

## Limits worth knowing

- **Books with more than 60 chapters** get consecutive table-of-contents
  entries grouped into buckets. The index still covers the whole book; the
  chapter numbers become bucket numbers.
- **The output budget, not the input, is the constraint.** A million-character
  book is comfortably within a modern model's input window, but the model's
  reply — which also has to pay for its own thinking — is not. That's why the
  plugin asks for a terser answer before it ever trims book text, and trims
  from the end when it must.
- **Text extraction needs a table of contents.** A book with no TOC has no
  chapters to tag against.
- **Hiding is the default when the model tells us nothing.** An entry with no
  chapter on it is treated as end-of-book, so a character the model forgot to
  place stays hidden until you finish. That reads as the plugin losing a
  character, and it is the right way round: the other error hands you the plot.
  The whole-book toggle is one tap away.
- **The chapter you are currently in is not shown**, only the ones you have
  finished — so there is nothing on chapter 1, and a chapter you just finished
  appears when you turn into the next one. If you open Characters on chapter 1
  after analysis, Grimoria tells you to finish that chapter rather than asking
  you to analyse again. Set `include_current_chapter.txt` to `1` if you would
  rather have the current chapter included.
- **The model is not perfect.** It occasionally misjudges which chapter a
  revelation lands in. The design limits the blast radius; it can't eliminate
  it.
- **Comic and image-only books** aren't supported. Text only.

## Development

There's no build step. The `grimoria.koplugin/` folder *is* the artifact — copy it
to a device and restart.

Nine test suites run offline with no API key and no book:

```sh
cd grimoria.koplugin/test
lua smoke_openrouter.lua ..   # provider table, routing, entry points
lua test_cancel.lua ..        # the cancel confirmation on an in-flight fetch
lua test_localization.lua ..  # language discovery, .po parity, format specifiers
lua test_wiring.lua ..        # every method resolves after the lib/ mixin
lua test_updater.lua ..       # self-update: staged swap, rollback, revert
lua test_spoiler.lua ..       # the spoiler property, on synthetic fixtures
lua test_mentions.lua ..      # appearance counting, boundary, reading position
lua test_range.lua ..         # chapter-range analyses keep the book's numbering
lua test_legacy.lua .. <fixture>   # reading files from before the rename
```

The full harness runs a real book through the shipped prompt builder, JSON
validator and spoiler filter — see [`grimoria.koplugin/test/README.md`](grimoria.koplugin/test/README.md).
It needs a book fixture that isn't in this repository, for copyright reasons;
that file explains what replacing it would take.

## Credits

Built on [KOReader](https://github.com/koreader/koreader), which is the reason
any of this is possible on a Kindle.

## License

MIT — see [LICENSE](LICENSE).
