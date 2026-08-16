--[[
The last line of defence: catching a leak the model wrote into the text itself.

lib/spoilers.lua guarantees the STRUCTURE -- a field with a chapter number
later than the reader's position cannot be displayed, and a field nobody
whitelisted cannot be displayed at all. That is worth a great deal and it is
not enough, because it says nothing about what is INSIDE a field that is
allowed through.

The shape of the gap: a by_chapter entry belonging to chapter 12, shown to a
reader who has finished chapter 12 -- correctly, by every structural rule --
which names the other half of an identity the book does not reveal until
chapter 30. No amount of whitelisting catches that; the leak is in the prose.
test/test_spoiler.lua carries that exact case as a fixture, because it is the
one thing here that nothing else in the design can do.

An honest note on how much this fires in practice: on three real analyses of a
mystery novel it re-tagged **nothing** on two of them and one card by one
chapter on the third. An earlier version of this module, which folded
diacritics, appeared to catch a genuine leak on that book -- and did not: it
was matching the Vietnamese "nghi vấn" ("suspicion") against a character named
Van. That is why the matching rule below is what it is, and why the value of
this module is measured by the case it provably catches rather than by a count
of things it moved.

WHAT THIS DOES

Two rules, both applied by moving text LATER rather than deleting it:

  1. IDENTITY. A character who is a member of an identity_merge must not name
     another member of that merge before the chapter the book itself makes the
     connection. Any field of theirs that does is re-tagged to the reveal
     chapter -- so it appears, in full, exactly when the reader earns it.

  2. UNMET ENTITIES. A chapter-tagged value must not name a character or place
     the reader has not met. Such a value is re-tagged to the chapter that
     entity appears in.

  3. ALIASES ARE NOT A BACK DOOR. An alias is displayed from its own
     first_chapter with no reveal attached, so an alias that happens to be
     another character's name -- or a merge sibling's -- would print the
     connection the moment the card appears. Those are re-tagged to the
     chapter the book itself makes the link. This one is not a matter of prose
     going wrong: it is the single shape in which the alias field can hand
     over a hidden identity, and it is checked by comparing names rather than
     by searching text, so it neither misses nor false-positives.

Re-tag, never delete: the model's sentence is usually correct and useful, it
is simply timed wrongly, and a reader who reaches the reveal should get the
whole card. Deleting would also make the guard destructive on a false
positive, which for something that runs unattended on every analysis is the
wrong risk to take.

WHAT THIS CANNOT DO, stated plainly rather than implied

It matches NAMES. A semantic leak carrying no name -- "he would come to regret
this", a theme phrased as a hint, a summary that foreshadows in the abstract --
is invisible here, and stays the responsibility of the prompt's per-chapter
discipline. This module narrows the hole; it does not close it.

MATCHING IS WHOLE-WORD, CASE-INSENSITIVE, AND NOT DIACRITIC-FOLDED

Both halves of that were learned the hard way, and the second one twice.

Without the word boundary, "Van" matches inside "Vantage" and the guard buries
half the analysis.

Folding diacritics looks obviously right and is obviously wrong for the
language these books are mostly in. Vietnamese diacritics are not decoration:
"Văn" (literature), "Vấn" (to ask) and "Van" (a name) are three different
words, and folding makes them one. Measured on a real analysis, a guard that
folded held back two characters because their introductions said "sinh viên
khoa Văn" -- a LITERATURE student -- which it read as naming a character
called Van. test/validate.py had already reached the same conclusion and
recorded it; this module rediscovered it by hiding people who had done nothing
wrong.

The cost is real and accepted: a model that writes "Van" for a character named
"Vân" slips past. That is a miss on a spelling the model itself is
inconsistent about, against a guarantee that hiding a character costs the
reader something on every page.
]]

local logger = require("logger")

local SpoilerGuard = {}

--[[
Case only -- deliberately not diacritics; see the header.

string.lower touches ASCII bytes and leaves the UTF-8 sequences alone, which is
exactly what is wanted: "Van" and "van" are the same name, "Văn" is a different
word. Applied identically to needle and haystack, so the comparison stays
consistent whatever it does to a given byte.
]]
function SpoilerGuard.fold(s)
    return tostring(s or ""):lower()
end

--[[
Whole-word containment.

The boundary test is "the character either side is not an ASCII letter or
digit". A Vietnamese word carrying a diacritic has a non-ASCII byte at that
position, which does not match %w and so reads as a boundary -- meaning "Van"
would still be found inside "Văn" if the two ever shared a byte prefix. They do
not: "Văn" is V + a multi-byte ă, so a literal search for "van" cannot match it
at all. That is the whole reason dropping the fold works.

Needles under three characters are refused outright: a two-letter identity name
matches somewhere in almost any paragraph, and a guard that re-tags everything
hides the book.
]]
function SpoilerGuard.mentions(haystack, needle)
    local h, n = SpoilerGuard.fold(haystack), SpoilerGuard.fold(needle)
    if #n < 3 or #h == 0 then return false end
    local from = 1
    while true do
        local s, e = h:find(n, from, true)
        if not s then return false end
        local before = s > 1 and h:sub(s - 1, s - 1) or " "
        local after = e < #h and h:sub(e + 1, e + 1) or " "
        if not before:match("%w") and not after:match("%w") then return true end
        from = s + 1
    end
end

local function toInt(v, d)
    local n = tonumber(v)
    return (n and n >= 1) and math.floor(n) or d
end

--[[
Run both rules over one analysis, in place.

Returns the analysis and the number of fields re-tagged, so the caller can log
it. Deliberately tolerant of shapes it does not recognise: this runs on every
analysis ever stored, including ones written years before it existed, and a
guard that errors on an unfamiliar payload would make that analysis unopenable.
]]
function SpoilerGuard.scan(data)
    if type(data) ~= "table" then return data, 0 end

    local last = 1
    for i, ch in ipairs(data.chapters or {}) do
        if type(ch) == "table" then last = math.max(last, toInt(ch.index, i), i) end
    end

    --[[
    Rule 1's map: member name -> LIST of { reveal, others }.

    A list, not a single entry, because one identity can belong to several
    merges -- and that is not a corner case. A real analysis of one novel has
    "Morisu Kyoichi" in two: with "Van" at chapter 47, and with an anonymous
    figure at chapter 56. Keyed by name with a single value, the second merge
    silently replaced the first, Van stopped counting as a sibling, and the
    guard walked straight past the one leak in the file it was written to
    catch.
    ]]
    local member = {}
    for _, m in ipairs(data.identity_merges or {}) do
        if type(m) == "table" and type(m.names) == "table" then
            local reveal = toInt(m.chapter, last)
            for _, n in ipairs(m.names) do
                if type(n) == "string" then
                    local others = {}
                    for _, o in ipairs(m.names) do
                        if o ~= n and type(o) == "string" then others[#others + 1] = o end
                    end
                    member[n] = member[n] or {}
                    member[n][#member[n] + 1] = { reveal = reveal, others = others }
                end
            end
        end
    end

    -- Rule 2's map: entity name -> the chapter the reader meets it.
    local meets = {}
    local function note(name, at)
        if type(name) ~= "string" or #name < 3 then return end
        local n = toInt(at, last)
        if meets[name] == nil or n < meets[name] then meets[name] = n end
    end
    -- Which character owns a given name, so an alias can be told apart from a
    -- reference to somebody else. Built before the alias pass below needs it.
    local owner_of = {}
    for _, c in ipairs(data.characters or {}) do
        if type(c) == "table" then
            note(c.name, c.first_chapter)
            if type(c.name) == "string" then owner_of[c.name] = c end
        end
    end
    for _, l in ipairs(data.locations or {}) do
        if type(l) == "table" then note(l.name, l.first_chapter) end
    end

    local retagged = 0

    --[[
    RULE 3, applied first because it decides which alias spellings count as
    "met" for rules 1 and 2.

    An alias carries no reveal chapter. It appears the moment its own
    first_chapter is reached, next to the character's name, which is precisely
    what makes it dangerous: "Van — also known as: Morisu Kyoichi" from chapter
    one is the whole twist, printed on a card with no prose in it for the text
    matcher to find. So an alias that IS another character's name, or a merge
    sibling of its owner, is moved to the chapter the book makes that link:

      * a merge sibling  -> that merge's reveal chapter
      * any other character's name -> the chapter that character appears, which
        is the earliest point at which the reader can even tell the two names
        refer to one person

    Exact name comparison, not the text matcher: an alias field holds one name,
    so there is nothing to search and no boundary to get wrong.
    ]]
    for _, c in ipairs(data.characters or {}) do
        if type(c) == "table" and type(c.aliases) == "table" then
            for _, a in ipairs(c.aliases) do
                if type(a) == "table" and type(a.alias) == "string" then
                    local now = toInt(a.first_chapter, last)
                    local safe = now

                    for _, group in ipairs(member[c.name] or {}) do
                        for _, other in ipairs(group.others) do
                            if other == a.alias and group.reveal > safe then
                                safe = group.reveal
                            end
                        end
                    end

                    local other_owner = owner_of[a.alias]
                    if other_owner and other_owner ~= c then
                        local meet = toInt(other_owner.first_chapter, last)
                        if meet > safe then safe = meet end
                    end

                    if safe > now then
                        a.first_chapter = safe
                        retagged = retagged + 1
                        logger.info("SpoilerGuard: alias", a.alias, "of",
                                    tostring(c.name), "held back from ch", now,
                                    "to ch", safe, "-- it names another identity")
                    end
                end
            end
        end
    end

    --[[
    Alias spellings the reader HAS met count as names for rules 1 and 2, so a
    development that says "Lizzy" is measured the same way as one that says
    "Elizabeth". An alias never makes a name available EARLIER than the
    character themselves -- the whole card is hidden until first_chapter -- so
    the later of the two is the honest answer.

    alias_owner is what stops that from firing on the owner's OWN card. Rule 2
    exempts a text from its owner's name; without the same exemption for the
    owner's other spellings, a chapter-8 development of Elizabeth's that says
    "Lizzy" would be held back to whatever chapter the alias is tagged with --
    the guard hiding a sentence for naming the very person it is about.
    ]]
    local alias_owner = {}
    for _, c in ipairs(data.characters or {}) do
        if type(c) == "table" then
            for _, a in ipairs(c.aliases or {}) do
                if type(a) == "table" and type(a.alias) == "string" then
                    note(a.alias, math.max(toInt(a.first_chapter, last),
                                           toInt(c.first_chapter, last)))
                    alias_owner[a.alias] = c.name
                end
            end
        end
    end

    --[[
    The chapter a piece of text may not be shown before.

    `owner` is the entity the text belongs to, so neither its own name nor any
    of its own aliases counts against it. The answer is the latest of: the
    reveal chapter of any merge sibling it names, and the first chapter of any
    entity it names.
    ]]
    local function earliestSafe(text, owner_name, current)
        local at = current
        for _, group in ipairs(member[owner_name] or {}) do
            for _, other in ipairs(group.others) do
                if group.reveal > at and SpoilerGuard.mentions(text, other) then
                    at = group.reveal
                end
            end
        end
        for name, meet in pairs(meets) do
            -- Spelled out rather than folded into one comparison because
            -- owner_name is nil for a theme, which belongs to nobody -- and
            -- `alias_owner[name] ~= nil` would then exempt every alias in the
            -- book from the field models spoil most often.
            local mine = (name == owner_name)
                or (owner_name ~= nil and alias_owner[name] == owner_name)
            if not mine and meet > at and SpoilerGuard.mentions(text, name) then
                at = meet
            end
        end
        return at
    end

    local function guardTagged(list, owner_name, what)
        if type(list) ~= "table" then return end
        for _, item in ipairs(list) do
            if type(item) == "table" and type(item.value) == "string" then
                local now = toInt(item.first_chapter, last)
                local safe = earliestSafe(item.value, owner_name, now)
                if safe > now then
                    item.first_chapter = safe
                    retagged = retagged + 1
                    logger.info("SpoilerGuard: held back", what, "of",
                                tostring(owner_name), "from ch", now, "to ch", safe)
                end
            end
        end
    end

    for _, c in ipairs(data.characters or {}) do
        if type(c) == "table" then
            guardTagged(c.role, c.name, "role")
            guardTagged(c.occupation, c.name, "occupation")
            guardTagged(c.gender, c.name, "gender")

            --[[
            by_chapter is where the measured leak actually was. An entry is
            bound to the chapter it describes, so moving it later is the only
            correction available -- and it is the right one: the sentence
            stays, it simply waits until the reader is allowed to read a
            character's name in it.
            ]]
            for _, bc in ipairs(c.by_chapter or {}) do
                if type(bc) == "table" and type(bc.development) == "string" then
                    local now = toInt(bc.chapter, last)
                    local safe = earliestSafe(bc.development, c.name, now)
                    if safe > now then
                        bc.chapter = safe
                        retagged = retagged + 1
                        logger.info("SpoilerGuard: held back a development of",
                                    tostring(c.name), "from ch", now, "to ch", safe)
                    end
                end
            end

            --[[
            `intro` has no chapter of its own -- it is pinned to the character's
            first_chapter, which is the point at which the whole card appears.
            So the only correction available is to delay the card itself, and
            that is a heavier hammer than the others: it hides a character
            rather than a sentence. It is still the right way round, and it
            only fires when an introduction names somebody it should not.
            ]]
            if type(c.intro) == "string" and #c.intro > 0 then
                local now = toInt(c.first_chapter, last)
                local safe = earliestSafe(c.intro, c.name, now)
                if safe > now then
                    c.first_chapter = safe
                    retagged = retagged + 1
                    logger.info("SpoilerGuard: held back", tostring(c.name),
                                "from ch", now, "to ch", safe, "-- its intro names someone else")
                end
            end
        end
    end

    for _, l in ipairs(data.locations or {}) do
        if type(l) == "table" then
            guardTagged(l.description, l.name, "description")
            guardTagged(l.importance, l.name, "importance")
        end
    end

    for _, h in ipairs(data.historical_figures or {}) do
        if type(h) == "table" then
            guardTagged(h.role, h.name, "role")
            guardTagged(h.importance_in_book, h.name, "importance")
            guardTagged(h.context_in_book, h.name, "context")
        end
    end

    --[[
    Themes carry a single first_chapter rather than a tagged list, and are the
    field models most often spoil: five of six named the murderer inside one.
    ]]
    for _, t in ipairs(data.themes or {}) do
        if type(t) == "table" and type(t.theme) == "string" then
            local now = toInt(t.first_chapter, last)
            local safe = earliestSafe(t.theme, nil, now)
            if safe > now then
                t.first_chapter = safe
                retagged = retagged + 1
                logger.info("SpoilerGuard: held back a theme from ch", now, "to ch", safe)
            end
        end
    end

    if retagged > 0 then
        logger.warn("SpoilerGuard: re-tagged", retagged,
                    "field(s) that named something the reader had not reached")
    end
    return data, retagged
end

return SpoilerGuard
