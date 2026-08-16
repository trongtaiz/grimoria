--[[
Prompt sections, assembled by LLM:createPrompt.

Two things changed from the original single-template design:

1. The book's actual text is now sent, so every rule here is about GROUNDING -
   answering from the supplied text instead of from the model's memory of the
   title. The old template did the opposite; its historical_figures rule
   literally ordered the model to invent a figure when the book had none.

2. Output is per-chapter. The AI attributes each character's development to
   the chapter it happens in, which lets the plugin hide later chapters
   locally. That means ONE request per book ever - no re-fetching as the
   reader progresses.

Language files may override any single key; missing keys fall back to these
(see LLM:loadPrompts).
]]

return {

system_instruction = "You are a precise literary analyst. You respond ONLY with a single valid JSON object. No Markdown fences, no commentary before or after the JSON.",

grounding = [[
GROUNDING RULES - these override everything else except AUTHOR_BIO:

1. Analyse ONLY the text between <<<BOOK_TEXT_START>>> and <<<BOOK_TEXT_END>>>.
2. Do NOT use prior knowledge of this title, author, or genre to add
   characters, events, or places that are not in that text. If you think you
   recognise the book, ignore that recollection - it is frequently wrong for
   translated titles, and the supplied text is authoritative.
3. If the text does not support a field, return an empty array or empty
   string. Never pad a list to reach a suggested count.
4. Transcribe every character and place name EXACTLY as spelled in the text.
   Do not translate, romanise, normalise, or "correct" names.
5. Chapter numbers come ONLY from the "=== CHAPTER n: title ===" markers in
   the text. Never guess a chapter number.
6. JSON keys stay exactly as specified, in English. Field VALUES follow the
   OUTPUT LANGUAGE rule at the end of this prompt.
]],

section_chapters = [[
CHAPTERS: One entry per "=== CHAPTER n ===" marker present in the text, in
order. Give the chapter's own title as printed, a 2-4 sentence summary of what
happens in it, and its significant events. Do not merge or split chapters.
]],

section_spoilers = [[
SPOILER DISCIPLINE - the single most important rule set.

ONE TEXTUAL IDENTITY = ONE CHARACTER ENTRY. List characters by the names the
TEXT uses, not by the people behind them. If an unnamed figure appears in a
prologue, that figure is a character ("the mystery man"). If someone lives
under an alias, the alias is a character. If the same person is also known
by their real name in another storyline, that name is ANOTHER character.
Until the text itself confirms two identities are the same person, their
entries must read as unrelated:

1. Write every field of an identity using ONLY what the text has established
   about THAT NAME by the chapter being described. Describing what an
   anonymous figure does is fine - the text does it too. Linking the figure
   to a named character before the text does is the spoiler.
2. Never cross-reference identities that the text has not yet connected -
   not in intros, not in by_chapter entries, not in chapter summaries or
   events, not in locations. Each identity gets only its own mentions.
3. "role" is the role that identity APPEARS to have. A culprit posing as a
   friend is Supporting until the text unmasks them.
4. When the text DOES reveal that identities are one person, record it in
   the top-level "identity_merges" list: which names merge, the chapter the
   TEXT makes the connection, the merged display name, the true role, and a
   1-2 sentence revelation. The reader's app fuses the entries at exactly
   that chapter. A book with no such twist has "identity_merges": [].
5. The same stop-reading rule applies to chapter summaries and events:
   describe each scene as the text presents it at that point, preserving any
   anonymity, disguise, or misdirection the author maintains there.
]],

section_characters = [[
CHARACTERS: Every textual identity who speaks or acts meaningfully in the
text (typically 8-25 - do not invent any to reach a number, and remember:
separate identities of one person are SEPARATE entries, per SPOILER
DISCIPLINE).

For each identity:
  - name: the name the TEXT uses for this identity (an alias, or a
    descriptive name like "the mystery man" for an anonymous figure)
  - role: Protagonist / Supporting / Antagonist as this identity APPEARS
  - gender: only if the text evidences it (pronouns, direct statement);
    otherwise "Unspecified"
  - occupation: only if stated or plainly implied; otherwise ""
  - intro: ONE sentence identifying this identity, written from the
    knowledge of a reader who has only just met them
  - first_chapter: the chapter where this identity first appears
  - by_chapter: an entry ONLY for chapters where this identity actually
    appears or is significantly discussed, 1-2 sentences on what they do IN
    THAT CHAPTER, never referencing an identity the text has not yet linked.
    Skip chapters where they are absent - no filler entries.

Keep by_chapter entries short. A long book with many characters must still
fit in the response budget; brevity per entry matters more than completeness
of prose.
]],

section_merges = [[
IDENTITY_MERGES: One entry per revealed connection between identities.
  - names: the exact "name" values of the character entries being connected
  - chapter: the chapter where THE TEXT confirms the connection (not where
    an attentive reader might guess it)
  - merged_name: how the fused character should be displayed after the
    reveal, e.g. "Van (Morisu Kyoichi)"
  - true_role: the fused character's real role
  - revelation: 1-2 sentences stating what was revealed
Empty list if the book has no hidden-identity twist.
]],

section_locations = [[
LOCATIONS: Only places named or described in the text. Give the name as
spelled, a description drawn from the text, and first_chapter.
]],

section_themes = [[
THEMES: 3-6 themes, each grounded in specific evidence from the text
(recurring imagery, explicit statements, structural patterns). Avoid bare
genre labels such as "love" or "death" unless the text itself develops them.

Themes are shown to a reader who may be anywhere in the book, so THE SPOILER
RULES APPLY HERE TOO - this is the field where they are most often forgotten.
Write the theme itself so it does not reveal who did what: describe the
pattern, not the solution. "Revenge dressed up as justice" is fine; naming the
person behind it is not.

Then set first_chapter: the earliest chapter by which a reader has seen enough
to recognise this theme WITHOUT needing any later revelation. A theme visible
from the opening pages gets 1. A theme that only makes sense once a twist has
landed gets the chapter of that twist. Do not put 1 on a theme that depends on
the ending.
]],

section_historical_figures = [[
HISTORICAL_FIGURES: REAL historical people, and only if the text explicitly
names or unmistakably refers to them. If the text mentions none, return an
empty array. Do NOT add a ruler, era figure, or any other stand-in to avoid an
empty list - inventing one is fabrication, not analysis.
]],

section_author_bio = [[
AUTHOR_BIO - the single exception to the grounding rules: the book text will
not contain the author's biography, so use your general knowledge of the
author "%s" for 2-3 factual sentences. If you do not reliably know this
author, say so plainly in this field instead of inventing biography.
]],

section_language = [[
BOOK_LANGUAGE: Detect the language the book text is written in and name it in
English (for example "Vietnamese", "English", "Japanese").
]],

json_schema = [[
REQUIRED JSON FORMAT - emit exactly these keys, using [] or "" where the text
gives you nothing:
{
  "book_title": "title as it appears in the text",
  "author": "author name",
  "author_bio": "2-3 sentences, or an honest statement of not knowing",
  "book_language": "language of the book text, named in English",
  "chapters": [
    {
      "index": 1,
      "title": "chapter title as printed",
      "summary": "2-4 sentences",
      "events": [ { "event": "what happened", "importance": "why it matters" } ]
    }
  ],
  "characters": [
    {
      "name": "the name THE TEXT uses for this identity",
      "role": "Protagonist / Supporting / Antagonist (as it appears)",
      "gender": "Male / Female / Unspecified",
      "occupation": "",
      "intro": "one sentence, knowing only what a new reader knows",
      "first_chapter": 1,
      "by_chapter": [ { "chapter": 1, "development": "1-2 sentences" } ]
    }
  ],
  "identity_merges": [
    { "names": ["identity A", "identity B"], "chapter": 1,
      "merged_name": "A (B)", "true_role": "", "revelation": "1-2 sentences" }
  ],
  "locations": [
    { "name": "", "description": "", "first_chapter": 1 }
  ],
  "themes": [
    { "theme": "spoiler-free statement of the theme", "first_chapter": 1 }
  ],
  "historical_figures": [
    { "name": "", "role": "", "biography": "",
      "importance_in_book": "", "context_in_book": "" }
  ]
}]],

fallback = {
    unknown_book = "Unknown Book",
    unknown_author = "Unknown Author",
    unnamed_character = "Unnamed Character",
    not_specified = "Not Specified",
    no_description = "No Description",
    unnamed_person = "Unnamed Person",
    no_biography = "No Biography Available",
},

}
