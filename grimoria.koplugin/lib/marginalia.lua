-- Marginalia - Personal notes for characters
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local DocSettings = require("docsettings")

local Marginalia = {}

function Marginalia:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--[[
Where this book's notes are.

Writes go to the current name; a file left over from before the plugin was
renamed is read in place rather than migrated, because these are sentences the
reader typed by hand and a rename that half-fails loses them. Once a note is
added or edited the whole set is written under the current name, and the old
file simply stops being consulted.
]]
function Marginalia:getNotesPath(book_path, for_writing)
    if not book_path then
        return nil
    end

    local cache_dir = DocSettings:getSidecarDir(book_path)
    if not cache_dir then return nil end

    local Paths = require("lib/paths")
    local current = cache_dir .. "/" .. Paths:sidecarNames("notes.lua")[1]
    if for_writing then return current end

    return Paths:findSidecar(cache_dir, "notes.lua") or current
end

-- Load all notes for a book
function Marginalia:loadNotes(book_path)
    local notes_file = self:getNotesPath(book_path)
    if not notes_file then
        return {}
    end
    
    local attr = lfs.attributes(notes_file)
    if not attr then
        logger.info("Marginalia: No notes file found")
        return {}
    end
    
    local success, notes = pcall(function()
        return dofile(notes_file)
    end)
    
    if success and notes then
        logger.info("Marginalia: Loaded", self:countNotes(notes), "notes")
        return notes
    end
    
    return {}
end

-- Save notes for a book. Always writes under the current name, even when the
-- set was just read out of a pre-rename file: that is what migrates it.
function Marginalia:saveNotes(book_path, notes)
    local notes_file = self:getNotesPath(book_path, true)
    if not notes_file then
        return false
    end
    
    local success = pcall(function()
        local f = io.open(notes_file, "w")
        if f then
            f:write("-- Grimoria Character Notes\n")
            f:write("return " .. self:serialize(notes))
            f:close()
            logger.info("Marginalia: Saved notes to:", notes_file)
            return true
        end
        return false
    end)
    
    return success
end

-- Get note for a specific character
function Marginalia:getNote(notes, character_name)
    if not notes or not character_name then
        return nil
    end
    
    return notes[character_name]
end

-- Add or update note for a character
function Marginalia:setNote(notes, character_name, note_text)
    if not notes or not character_name then
        return false
    end
    
    notes[character_name] = {
        text = note_text,
        updated_at = os.time(),
    }
    
    logger.info("Marginalia: Updated note for:", character_name)
    return true
end

-- Delete note for a character
function Marginalia:deleteNote(notes, character_name)
    if not notes or not character_name then
        return false
    end
    
    notes[character_name] = nil
    logger.info("Marginalia: Deleted note for:", character_name)
    return true
end

-- Count total notes
function Marginalia:countNotes(notes)
    if not notes then
        return 0
    end
    
    local count = 0
    for _ in pairs(notes) do
        count = count + 1
    end
    
    return count
end

-- Serialize table to string
function Marginalia:serialize(obj, indent)
    indent = indent or ""
    local t = type(obj)
    
    if t == "table" then
        local s = "{\n"
        for k, v in pairs(obj) do
            s = s .. indent .. "  "
            if type(k) == "string" then
                s = s .. "[" .. string.format("%q", k) .. "] = "
            else
                s = s .. "[" .. k .. "] = "
            end
            s = s .. self:serialize(v, indent .. "  ") .. ",\n"
        end
        s = s .. indent .. "}"
        return s
    elseif t == "string" then
        return string.format("%q", obj)
    elseif t == "number" or t == "boolean" then
        return tostring(obj)
    else
        return "nil"
    end
end

return Marginalia
