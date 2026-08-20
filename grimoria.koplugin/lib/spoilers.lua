--[[
The spoiler filter: what the reader is allowed to see yet.

This is the plugin's whole reason for existing. The AI tags every entry
with a chapter; this decides which of them the reader has earned. One
textual identity is one character entry, and two identities that turn out
to be the same person stay separate until the chapter where the book
itself connects them.

THE GOVERNING RULE

  Every piece of text carries a chapter number and is written as if its
  author had read only up to that chapter. Anything untagged is treated as
  end-of-book and stays hidden.

The second sentence is the one that was missing, and it is why this file was
rewritten. The filter used to copy a character table wholesale --

    for k, v in pairs(c) do copy[k] = v end

-- and rebuild only `description`. Everything else came straight through:
`role`, `occupation` and `gender` are written by a model that read the whole
book, so a reader four chapters in was shown the job a character only takes in
chapter forty-seven. That was reported from real use, and reading the rest of
the path found seven more of the same shape -- untagged data defaulting to
chapter 1, a summary falling back to the whole book, a merge importing a field
from a character not yet met, legacy caches bypassing every rule.

The fix is structural rather than another prompt instruction, because prompt
instructions have already failed twice here: five of six models named the
murderer inside a theme, and one labelled a character `Antagonist` from the
chapter he first appears in. So:

  * VIEWS ARE BUILT FROM A WHITELIST, field by field. A field nobody taught
    this file about cannot reach the UI, whatever a model puts in the JSON.
    Adding a field to the schema means adding it here, deliberately.
  * EVERY DEFAULT FAILS CLOSED. Missing chapter information means end-of-book,
    never chapter 1. Hiding something harmless is the right error for a
    spoiler filter; showing the ending is not.
  * VALUES THAT CHANGE OVER A BOOK ARE CHAPTER-TAGGED LISTS, and resolved
    here to the latest value the reader has earned.

Resolution happens in this file on purpose. lib/ui/views.lua consumes these
fields as plain strings -- it concatenates `char.role` directly -- so handing
it a list would print raw JSON on one card and crash another. Everything that
leaves here is a string the views can use unchanged, which is also what keeps
their "never read self.book_data" property doing the real work.
]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local logger = require("logger")
local _ = require("gettext")
local Screen = require("device").screen

local GrimoriaPlugin = {}

-- --------------------------------------------------------- tagged values ----

-- The book's last chapter, which is what "end-of-book" resolves to.
local function lastChapterOf(data)
    local chs = data.chapters
    if chs and #chs > 0 then
        return tonumber(chs[#chs].index) or #chs
    end
    return 1
end

--[[
When does this item become visible?

`v` is an item's first_chapter as the model wrote it. Anything that is not a
usable chapter number -- absent, zero, a string, a negative -- resolves to the
last chapter, so the item stays hidden until the reader has finished the book.
Defaulting to 1 here is what made a model that simply forgot the field able to
publish its whole answer on page one.
]]
local function visibleFrom(v, last)
    local n = tonumber(v)
    if n and n >= 1 then return math.floor(n) end
    return last
end

--[[
Resolve a chapter-tagged value to the string the reader has earned.

Two shapes arrive here:

  a list   { { value = "Student", first_chapter = 1 },
             { value = "...",     first_chapter = 47 } }
           -- the latest entry at or before the limit wins, so a job, title or
           allegiance taken later in the book simply does not exist yet.

  a string "Student"
           -- what every analysis written before this change contains, with no
           chapter information at all. Treated as end-of-book: visible in
           whole-book view, or once the reader reaches the last chapter.

`limit == nil` means the whole book, so the last value in the list wins.
]]
local function resolveTagged(v, limit, last)
    if v == nil then return "" end

    if type(v) == "string" then
        if limit == nil or limit >= last then return v end
        return ""
    end
    if type(v) ~= "table" then return "" end

    local best_at, best_value = nil, nil
    for _, item in ipairs(v) do
        if type(item) == "table" and type(item.value) == "string" and #item.value > 0 then
            local at = visibleFrom(item.first_chapter, last)
            if limit == nil or at <= limit then
                -- >= rather than > so that list order breaks a tie, which is
                -- the order the model wrote them in.
                if best_at == nil or at >= best_at then
                    best_at, best_value = at, item.value
                end
            end
        elseif type(item) == "string" and #item > 0 then
            -- A model that emitted a bare list of strings. No chapter, so the
            -- same rule as an untagged string applies.
            if limit == nil or limit >= last then
                best_at, best_value = last, item
            end
        end
    end
    return best_value or ""
end

-- ---------------------------------------------------------------- fusing ----

--[[
Fuse identities that the text has already connected.

Books hide people behind aliases and anonymous scenes, so the analysis lists
one entry per TEXTUAL IDENTITY (the mystery man / Van / Morisu are three
characters). Each identity_merges entry names the chapter where the text
itself makes the connection; from that chapter on, the member entries become
one fused card. Before it, they stay unrelated -- that separation IS the
spoiler protection.

The fusion is gated on the merge chapter, but what it IMPORTS has to be gated
too, and used not to be: the fused card adopted the first non-empty
`occupation` from any member, including a member the reader has not met. The
merge being visible says these identities are one person; it does not say the
reader has met every one of them.

limit == nil means "the whole book": every merge applies.
]]
local function fuseCharacters(data, limit, last)
    local chars = data.characters or {}

    --[[
    Merges chain, and one identity can appear in several of them.

    A real analysis of one novel has "Morisu Kyoichi" merging with "Van" at
    chapter 47 and with an anonymous figure at chapter 56. Keyed one-merge-per-
    name, the second entry overwrote the first and the reader ended up with two
    cards for the same person -- "Morisu Kyoichi (Van)" holding only Van, and
    "Morisu Kyoichi (hắn)" holding the other two.

    So the applicable merges are unioned into GROUPS: every name reachable from
    every name, through whichever merges the reader has reached.

    The group takes its display name, role and revelation from the EARLIEST
    applicable merge. That one is the reveal -- the moment the book names the
    person behind the mask -- while a later merge typically folds in an
    anonymous figure ("the man in the raincoat") whose name identifies nobody.
    Taking the latest would title the card after exactly that placeholder.
    ]]
    local group_of = {}   -- identity name -> group table
    local groups = {}
    for _, m in ipairs(data.identity_merges or {}) do
        local at = visibleFrom(m.chapter, last)
        if (not limit) or at <= limit then
            -- Collect any groups these names already belong to, and fold them
            -- together with this merge into one.
            local merged = { names = {}, chapter = at, merged_name = m.merged_name,
                             true_role = m.true_role, revelation = m.revelation }
            local seen = {}
            local function take(name)
                if type(name) ~= "string" or seen[name] then return end
                seen[name] = true
                merged.names[#merged.names + 1] = name
            end
            for _, n in ipairs(m.names or {}) do
                local g = group_of[n]
                if g then
                    for _, gn in ipairs(g.names) do take(gn) end
                    if g.chapter <= merged.chapter then
                        merged.chapter = g.chapter
                        merged.merged_name = g.merged_name
                        merged.true_role = g.true_role
                        merged.revelation = g.revelation
                    end
                end
                take(n)
            end
            groups[#groups + 1] = merged
            for _, n in ipairs(merged.names) do group_of[n] = merged end
        end
    end

    local applies = group_of
    if not next(applies) then return chars end

    -- Has the reader met this identity yet? Only such members may contribute.
    local function met(c)
        return limit == nil or visibleFrom(c.first_chapter, last) <= limit
    end

    --[[
    Collect one member's chapter-tagged values onto the fused card's.

    Union rather than first-wins, which is the change the tagged shape forces
    and also the correct reading: a fused card is ONE PERSON, so their
    occupation over the book is everything each identity showed of it, in
    chapter order. First-wins would pin the card to whichever identity happened
    to be listed first -- so a disguise described as "occupation: unknown" in
    chapter 1 would still say "unknown" three hundred pages after the reader
    learned the man's actual job under his real name.

    resolveTagged then picks the latest entry the reader has earned, so
    collecting a value here is never the same as showing it.
    ]]
    local function collect(dst, v)
        if type(v) == "table" then
            for _, item in ipairs(v) do dst[#dst + 1] = item end
        elseif type(v) == "string" and #v > 0 then
            dst[#dst + 1] = v      -- resolveTagged reads a bare string as end-of-book
        end
    end

    local emitted, out = {}, {}
    for _, c in ipairs(chars) do
        local m = applies[c.name]
        if not m then
            out[#out + 1] = c
        elseif not emitted[m] then
            emitted[m] = true
            -- Fuse every member of the merge, in list order. The first member
            -- encountered anchors the card's position in the list.
            local fused = {
                name = m.merged_name,
                role = {}, gender = {}, occupation = {}, aliases = {},
                intro = nil,
                first_chapter = visibleFrom(c.first_chapter, last),
                by_chapter = {},
                revelation = m.revelation,
                merge_chapter = visibleFrom(m.chapter, last),
            }
            for _, cc in ipairs(chars) do
                if applies[cc.name] == m then
                    fused.first_chapter =
                        math.min(fused.first_chapter, visibleFrom(cc.first_chapter, last))
                    -- Fields are imported only from identities already met.
                    -- The merge being visible says these identities are one
                    -- person; it does not say the reader has met all of them.
                    if met(cc) then
                        collect(fused.occupation, cc.occupation)
                        collect(fused.gender, cc.gender)
                        collect(fused.role, cc.role)
                        if fused.intro == nil then fused.intro = cc.intro end
                        for _, a in ipairs(cc.aliases or {}) do
                            fused.aliases[#fused.aliases + 1] = a
                        end
                        --[[
                        The member's OWN name becomes an alias of the fused
                        card, which is the only place it can still be found.

                        The card is displayed under merged_name ("Van (Morisu
                        Kyoichi)"), so after the reveal neither "Van" nor
                        "Morisu Kyoichi" is any entry's name any more -- and a
                        reader who highlights either word on the page, or types
                        it into the search box, would be told no such character
                        exists. It is safe to add here for the same reason the
                        fusion is: this branch only runs for an identity the
                        reader has met, on a card that only exists from the
                        chapter the book made the connection.
                        ]]
                        fused.aliases[#fused.aliases + 1] = {
                            alias = cc.name,
                            first_chapter = visibleFrom(cc.first_chapter, last),
                        }
                    end
                    for _, bc in ipairs(cc.by_chapter or {}) do
                        fused.by_chapter[#fused.by_chapter + 1] = {
                            chapter = bc.chapter,
                            development = bc.development,
                            as_name = cc.name,   -- which identity did this
                        }
                    end
                end
            end

            -- true_role is revealed BY the merge, so it is earned exactly when
            -- the merge applies -- which is the only way we reached this line.
            -- It describes the fused person, so it supersedes the roles the
            -- separate identities appeared to have.
            if type(m.true_role) == "string" and #m.true_role > 0 then
                fused.role = { { value = m.true_role,
                                 first_chapter = fused.merge_chapter } }
            end
            table.sort(fused.by_chapter, function(a, b)
                return visibleFrom(a.chapter, last) < visibleFrom(b.chapter, last)
            end)
            out[#out + 1] = fused
        end
    end
    return out
end

-- ------------------------------------------------------ whitelist builds ----

--[[
Build the character card the UI renders.

Every field is named here explicitly. This is the rule the reported bug broke:
copying the source table meant that adding a field to the JSON schema silently
added it to the screen, unfiltered, and nobody had to decide anything.

`description` is assembled from what the reader has read -- the intro, the
revelation if the merge has landed, and one line per chapter already reached.
It is never inherited: an analysis that arrives with a `description` written
for the whole book (every pre-versioning cache has one) must not be able to
substitute it in when this rebuild produces nothing.
]]
local function buildCharacter(c, limit, last)
    local bits = {}
    --[[
    `intro` is a PLAIN STRING pinned to the character's first_chapter, and must
    not go through resolveTagged.

    It did, and the cost was total: resolveTagged reads a bare string as
    end-of-book, so every character's opening sentence was blank for every
    reader who had not finished the book -- measured on a real analysis, 14 of
    14 intros written, 0 of 14 ever displayed, at every chapter including the
    last (the limit is `here - 1`, so even standing in chapter 56 of 56 leaves
    it hidden). What the reader saw was a card that began mid-life with "[2]
    Mai explores the lighthouse" and never said who Mai was.

    The pin is what makes showing it correct rather than a hole in the filter.
    The card itself only exists from first_chapter on, the prompt requires the
    sentence to contain nothing the text has not established by that chapter,
    and lib/spoilerguard.lua rule 3 delays the WHOLE CARD when an intro names
    somebody unmet -- so the intro is earned at exactly the moment the card is.
    There is no chapter at which the card is visible and its intro is not.

    Do not "fix" this by teaching resolveTagged that strings are visible. That
    branch is what makes a pre-tagging cache's role/occupation/gender fail
    closed, and loosening it would un-harden every analysis stored before the
    schema changed, on every device, silently.
    ]]
    local intro = type(c.intro) == "string" and c.intro or ""
    if #intro > 0 then bits[#bits + 1] = intro end

    if c.merge_chapter and type(c.revelation) == "string" and #c.revelation > 0 then
        bits[#bits + 1] = string.format("[%d] * %s", c.merge_chapter, c.revelation)
    end

    for _, bc in ipairs(c.by_chapter or {}) do
        local at = visibleFrom(bc.chapter, last)
        local dev = type(bc.development) == "string" and bc.development or ""
        if (limit == nil or at <= limit) and #dev > 0 then
            if bc.as_name and c.merge_chapter then
                -- fused card: say which identity this entry belonged to
                bits[#bits + 1] = string.format("[%d] (%s) %s", at, bc.as_name, dev)
            else
                bits[#bits + 1] = string.format("[%d] %s", at, dev)
            end
        end
    end

    --[[
    The other spellings the reader has already met, deduplicated.

    Dedup matters here rather than upstream because a fused card unions the
    alias lists of several identities AND adds each one's own name, so the same
    string can arrive by two routes -- a nickname the model listed under both
    halves of a person, say. Printed twice on a card it reads as a bug in the
    analysis; matched twice by the highlight lookup it produces a picker
    offering the same character to choose between.

    The card's own name is skipped for the same reason: "Van — also known as:
    Van" is noise.
    ]]
    local aliases, seen = {}, { [type(c.name) == "string" and c.name or ""] = true }
    for _, a in ipairs(c.aliases or {}) do
        if type(a) == "table" and type(a.alias) == "string" and #a.alias > 0
            and not seen[a.alias] then
            if limit == nil or visibleFrom(a.first_chapter, last) <= limit then
                seen[a.alias] = true
                aliases[#aliases + 1] = a.alias
            end
        end
    end

    return {
        name        = type(c.name) == "string" and c.name or "",
        role        = resolveTagged(c.role, limit, last),
        gender      = resolveTagged(c.gender, limit, last),
        occupation  = resolveTagged(c.occupation, limit, last),
        intro       = intro,
        description = table.concat(bits, "\n\n"),
        aliases     = aliases,
        first_chapter = visibleFrom(c.first_chapter, last),
        -- Both of these exist only on a fused card, and a card is only fused
        -- from its merge chapter on -- so by the time either is non-nil the
        -- text has already made the connection they describe.
        merge_chapter = c.merge_chapter,
        revelation  = c.merge_chapter and c.revelation or nil,
        by_chapter  = c.by_chapter,
    }
end

local function buildLocation(l, limit, last)
    return {
        name        = type(l.name) == "string" and l.name or "",
        description = resolveTagged(l.description, limit, last),
        -- `importance` carries no chapter of its own, and it is prose about
        -- what a place turns out to matter for -- which is exactly the kind of
        -- sentence that gives an ending away. End-of-book unless tagged.
        importance  = resolveTagged(l.importance, limit, last),
        first_chapter = visibleFrom(l.first_chapter, last),
    }
end

local function buildFigure(h, limit, last)
    return {
        name               = type(h.name) == "string" and h.name or "",
        role               = resolveTagged(h.role, limit, last),
        biography          = type(h.biography) == "string" and h.biography or "",
        -- What the book does with a real person is book content, so both of
        -- these filter; the biography is general knowledge and does not.
        importance_in_book = resolveTagged(h.importance_in_book, limit, last),
        context_in_book    = resolveTagged(h.context_in_book, limit, last),
        first_chapter      = visibleFrom(h.first_chapter, last),
    }
end

local function buildEvent(ev, last)
    return {
        event         = type(ev.event) == "string" and ev.event or "",
        importance    = type(ev.importance) == "string" and ev.importance or "",
        chapter       = ev.chapter,
        chapter_index = visibleFrom(ev.chapter_index, last),
    }
end

--[[
One heading per chapter inside the summary.

The summary is a full page now (lib/ui/views.lua:showSummary), not a fifteen-
second popup, so it is read rather than glanced at -- and a wall of two-sentence
paragraphs with no landmarks is unreadable at any length. A heading gives the
eye somewhere to land when a reader pages back looking for what happened in
chapter nine, and it makes the boundary between "what I read yesterday" and
"what I read this morning" visible at all.

The chapter's own title is safe to print here twice over: it comes from the
book's table of contents, which the reader can open from KOReader's own menu at
any time, and only chapters they have already finished reach this loop.
]]
local function chapterHeading(loc, index, title)
    local word = (loc and loc.t) and loc:t("chapter") or "Chapter"
    local label = word .. " " .. index
    if type(title) == "string" and #title > 0 and title ~= tostring(index) then
        label = label .. " · " .. title
    end
    return "── " .. label .. " ──"
end

-- ---------------------------------------------------------- the filter ----

function GrimoriaPlugin:applyChapterFilter()
    local data = self.book_data
    if not data then return end

    local last = lastChapterOf(data)

    --[[
    How far has the reader got?

    Three cases, and the third is the one that used to leak. An analysis with
    no chapters at all cannot be filtered against anything, and the explicit
    whole-book toggle is the reader asking to see everything -- both are
    limit == nil, deliberately.

    But getCurrentChapterIndex also returns nil when it simply FAILS: an
    xpointer it cannot resolve, a document mid-close. Treating that as "show
    the whole book" handed over the complete analysis on a transient error.
    It now falls back to the last position that did resolve, and to chapter 1
    if there has never been one.
    ]]
    local has_chapter_data = data.chapters and #data.chapters > 0
    local previous = self.filter_chapter
    local limit = nil
    if has_chapter_data and not self.show_whole_book then
        local BookText = require("lib/booktext")
        local here = BookText:getCurrentChapterIndex(self.ui, self:chapterScheme())
        if not here then
            limit = previous or 0
            logger.warn("Grimoria: current chapter did not resolve; filtering at",
                        limit, "rather than showing the whole book")
        else
            --[[
            THE CURRENT CHAPTER IS NOT SHOWN, and this is the subtle half of
            the whole design.

            getCurrentChapterIndex answers "which chapter is the reader in",
            not "which chapters has the reader finished" -- it is the last
            chapter whose start is at or before their position, so it says 12
            from the first line of chapter 12 onward. Filtering at <= 12 then
            showed chapter 12's summary, its events, and what every character
            does in it, to somebody two paragraphs into it. The plugin was
            spoiling the page being read.

            What a reader has actually finished is chapters 1..k-1, so that is
            the limit. The cost is visible and worth stating: on chapter 1
            there is nothing to show yet, and a chapter you have just finished
            stays hidden until you turn into the next one. Both are the filter
            erring towards silence, which is the direction it is supposed to
            err in -- and `include_current_chapter.txt` is there for a reader
            who disagrees.
            ]]
            limit = self:spoilerIncludesCurrentChapter() and here or (here - 1)
        end
    end
    self.filter_chapter = limit

    local fused = fuseCharacters(data, limit, last)

    local chars = {}
    for _, c in ipairs(fused) do
        if limit == nil or visibleFrom(c.first_chapter, last) <= limit then
            chars[#chars + 1] = buildCharacter(c, limit, last)
        end
    end
    self.characters = chars

    local locs = {}
    for _, l in ipairs(data.locations or {}) do
        if type(l) == "table"
            and (limit == nil or visibleFrom(l.first_chapter, last) <= limit) then
            locs[#locs + 1] = buildLocation(l, limit, last)
        end
    end
    self.locations = locs

    local tl = {}
    for _, ev in ipairs(data.timeline or {}) do
        if type(ev) == "table"
            and (limit == nil or visibleFrom(ev.chapter_index, last) <= limit) then
            tl[#tl + 1] = buildEvent(ev, last)
        end
    end
    self.timeline = tl

    --[[
    The summary is the chapters already read, and nothing else.

    It used to fall back to data.summary when no chapter up to the current one
    carried one -- and data.summary is stitched from EVERY chapter, ending
    included. A book whose first chapters have no summary therefore opened with
    the whole plot. "No summary yet" is the honest answer and now the only one.
    ]]
    local parts = {}
    for _, ch in ipairs(data.chapters or {}) do
        local at = tonumber(ch.index) or last
        if (limit == nil or at <= limit) and type(ch.summary) == "string" and #ch.summary > 0 then
            parts[#parts + 1] = chapterHeading(self.loc, at, ch.title) .. "\n" .. ch.summary
        end
    end
    self.summary = table.concat(parts, "\n\n")

    --[[
    Themes filter like everything else, and the legacy shape fails closed.

    Measured on one book: five of six models named the murderer inside a theme
    string, and one spelled out the hidden-identity twist outright, while this
    view passed them through on the assumption that themes were "book-level and
    harmless". Caches written before that discovery hold plain strings produced
    with no spoiler rule on the field at all -- so those are end-of-book. The
    branch that handled them used to sit OUTSIDE the chapter test and tag them
    chapter 1, four lines below a comment promising the opposite.
    ]]
    local th = {}
    for _, t in ipairs(data.themes or {}) do
        local body, at
        if type(t) == "table" then
            body = type(t.theme) == "string" and t.theme or ""
            at = visibleFrom(t.first_chapter, last)
        elseif type(t) == "string" then
            body, at = t, last
        end
        if body and #body > 0 and (limit == nil or at <= limit) then
            th[#th + 1] = { theme = body, first_chapter = at }
        end
    end
    self.themes = th

    --[[
    Historical figures used to pass through unfiltered, on the reasoning that
    they carry less plot than a theme and had no chapter field to filter on.
    The second half was true and is the actual reason; it is not a reason to
    show them. `context_in_book` is a sentence about what the book does with a
    real person, which on a historical novel is plot. They filter now, and an
    untagged one is end-of-book like everything else.
    ]]
    local figs = {}
    for _, h in ipairs(data.historical_figures or {}) do
        if type(h) == "table"
            and (limit == nil or visibleFrom(h.first_chapter, last) <= limit) then
            figs[#figs + 1] = buildFigure(h, limit, last)
        end
    end
    self.historical_figures = figs

    --[[
    Quotes filter like everything else: a passage is shown only once the
    reader has finished the chapter it appears in. This list -- the one the
    views render -- honours the whole-book toggle like every other list; the
    sidecar export below deliberately does not.
    ]]
    local qs = {}
    for _, q in ipairs(data.quotes or {}) do
        if type(q) == "table" and type(q.quote) == "string" and #q.quote > 0
            and (limit == nil or visibleFrom(q.chapter, last) <= limit) then
            qs[#qs + 1] = {
                quote = q.quote,
                chapter = visibleFrom(q.chapter, last),
                speaker = type(q.speaker) == "string" and q.speaker or "",
            }
        end
    end
    self.quotes = qs

    self:exportQuotesSidecar()
end

--[[
Write the quotes the reader has EARNED to <book>.sdr/grimoria_quotes.lua, for
consumers outside this plugin -- concretely the sleep-screen user patch
(patches/2-sleep-screen-variants.lua in this repo), which shows a random
already-read quote while the device sleeps.

Two deliberate differences from the view filter above:

1. The limit is recomputed here from reading position alone. The whole-book
   toggle widens what the toggle's OWNER sees on screen; a file on disk
   outlives the toggle and is read by code that has no idea it was on, so
   exporting under it would hand the sleep screen quotes from unread chapters.
2. A position that does not resolve exports at the last limit that did (and
   at 0 if none ever has) -- the same fail-closed direction as the filter,
   because the alternative is writing unread quotes to disk on a transient
   error.

The write is skipped when the earned set has not changed: this runs before
every view, and e-ink devices sit on flash that is slow and wears.
]]
function GrimoriaPlugin:exportQuotesSidecar()
    local data = self.book_data
    if not data or type(data.quotes) ~= "table" or #data.quotes == 0 then return end
    local doc = self.ui and self.ui.document
    local book_path = doc and doc.file
    if not book_path then return end

    local last = lastChapterOf(data)
    local limit
    local BookText = require("lib/booktext")
    local here = BookText:getCurrentChapterIndex(self.ui, self:chapterScheme())
    if not here then
        limit = self._quotes_export_limit or 0
    else
        limit = self:spoilerIncludesCurrentChapter() and here or (here - 1)
    end
    self._quotes_export_limit = limit

    local titles = {}
    for _, ch in ipairs(data.chapters or {}) do
        if type(ch) == "table" and ch.index then titles[ch.index] = ch.title end
    end

    local visible = {}
    for _, q in ipairs(data.quotes) do
        if type(q) == "table" and type(q.quote) == "string" and #q.quote > 0
            and visibleFrom(q.chapter, last) <= limit then
            local at = visibleFrom(q.chapter, last)
            visible[#visible + 1] = {
                quote = q.quote,
                chapter = at,
                chapter_title = type(titles[at]) == "string" and titles[at] or "",
                speaker = type(q.speaker) == "string" and q.speaker or "",
            }
        end
    end

    -- Cheap change detection: the limit plus a length fingerprint of the set.
    local fp = tostring(limit) .. ":" .. tostring(#visible)
    for _, q in ipairs(visible) do fp = fp .. ":" .. #q.quote end
    if self._quotes_export_fp == fp then return end

    local Archive = require("lib/archive")
    local archive = Archive:new()
    local dir = archive:getSidecarDir(book_path)
    if not dir then return end
    local path = dir .. "/" .. require("lib/paths").NAME .. "_quotes.lua"
    local ok, err = pcall(function()
        assert(archive:ensureDirectory(path), "no sidecar directory")
        local f = assert(io.open(path, "w"))
        f:write("-- Grimoria quotes, filtered to the chapters already read.\n")
        f:write("-- Consumed by the sleep-screen user patch; safe to delete.\n\n")
        f:write("return " .. archive:serialize({
            format = 1,
            book_title = data.book_title,
            up_to_chapter = limit,
            quotes = visible,
        }))
        f:close()
    end)
    if not ok then
        logger.warn("Grimoria: could not export quotes:", tostring(err))
        return
    end
    self._quotes_export_fp = fp
end

--[[
Should the chapter the reader is currently inside count as read?

No, by default -- see applyChapterFilter. The escape hatch exists because the
safe answer has a visible cost (nothing at all on chapter 1) and a reader who
finds that irritating should not have to edit Lua to change it. Same
convention as every other setting: one plain-text file in settings/grimoria/.

Cached on the instance because applyChapterFilter runs before EVERY view, and
re-reading a file from a Kindle's flash on each menu open is a real cost for a
value that cannot change while the plugin is loaded.
]]
--[[
Which chapter-list scheme this analysis was numbered against.

Stored on analysis_meta at fetch. Absent (every cache written before scheme
2) means scheme 1 -- today's pair-bucketing. Defaulting the other way, to
2, on an old 32-chapter analysis would count `here` on the 13-chapter list
and leak: scheme 1 on a scheme-2 file hides extra (fail closed); scheme 2
on a scheme-1 file shows too much.
]]
function GrimoriaPlugin:chapterScheme()
    local meta = self.book_data and self.book_data.analysis_meta
    local s = type(meta) == "table" and tonumber(meta.chapter_scheme) or nil
    if s == 1 or s == 2 then return s end
    return 1
end

function GrimoriaPlugin:spoilerIncludesCurrentChapter()
    if self._include_current_chapter == nil then
        local ok, v = pcall(function()
            return require("lib/paths"):readSetting("include_current_chapter.txt")
        end)
        v = ok and v or nil
        self._include_current_chapter =
            (v == "1" or v == "true" or v == "yes" or v == "on")
    end
    return self._include_current_chapter
end

--[[
How the current scope reads to the user.

Shared, because filter_chapter can now be 0 -- the reader is inside chapter 1
and has finished nothing -- and "showing up to chapter 0" is not a sentence.
Lua makes this easy to get wrong twice: 0 is TRUTHY, so `if self.filter_chapter`
does not guard it.
]]
function GrimoriaPlugin:describeScope()
    if self.show_whole_book or self.filter_chapter == nil then
        return self.loc:t("showing_whole_book")
    end
    if self.filter_chapter < 1 then
        return self.loc:t("showing_nothing_yet")
    end
    return string.format(self.loc:t("showing_up_to_chapter"), self.filter_chapter)
end

function GrimoriaPlugin:toggleWholeBookView()
    self.show_whole_book = not self.show_whole_book
    self:applyChapterFilter()
    UIManager:show(InfoMessage:new{ text = self:describeScope(), timeout = 2 })
end

return GrimoriaPlugin
