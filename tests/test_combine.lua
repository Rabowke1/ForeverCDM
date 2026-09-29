-- Combined icons (seals, stings: one icon lit by whichever is up) and fading the
-- bars out of combat. Loads the real addon against a tiny fake UI. Run from ForeverCDM:
--   lua tests/test_combine.lua
unpack = table.unpack
strlower = string.lower
strtrim = function(s) return s:match('^%s*(.-)%s*$') end
issecretvalue = function() return false end
UISpecialFrames, SlashCmdList = {}, {}

local frames, methods = {}, {}
local function noop() end
local function object(kind, name, parent)
    local f = { kind = kind, parent = parent, scripts = {}, events = {}, shown = true }
    setmetatable(f, { __index = methods })
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
for _, name in ipairs({ 'SetTexCoord', 'ClearAllPoints', 'SetMovable', 'SetClampedToScreen', 'SetDrawEdge',
    'SetHideCountdownNumbers', 'SetDesaturated', 'SetCooldownFromDurationObject', 'SetAllPoints',
    'SetColorTexture', 'RegisterForDrag', 'EnableMouse' }) do methods[name] = noop end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:GetWidth() return self.width or 100 end
function methods:GetEffectiveScale() return 1 end          -- row positioning (Edit Mode anchors)
function methods:GetCenter() return 0, 0 end
function methods:GetNumPoints() return 0 end
function methods:SetText(t) self.textValue = t end
function methods:SetTexture(t) self.texture = t end
function methods:SetAlpha(a) self.alpha = a end
function methods:SetPoint(_, _, _, x) self.x = x end
function methods:SetScript(k, fn) self.scripts[k] = fn end
function methods:RegisterEvent(e) self.events[e] = true end
function methods:RegisterUnitEvent(e) self.events[e] = true end
function methods:CreateTexture() return object('Texture', nil, self) end
function methods:CreateFontString() return object('FontString', nil, self) end
function methods:IsShown() return self.shown end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetShown(v) self.shown = v and true or false end
function methods:SetCooldown(start, dur) self.cdStart, self.cdDur = start, dur end
function methods:Clear() self.cdStart, self.cdDur = nil, nil end

CreateFrame = object
UIParent = object('Frame')
C_Timer = { NewTicker = noop }
local now = 1000
GetTime = function() return now end

-- Spell IDs as Forever has them (Seal of Righteousness Rank 2 is 20287, from Beacon data).
local SOR, SOC, SOTC, RF, SERPENT, SCORPID = 20287, 20375, 21082, 25780, 1978, 3043
local names = { [SOR] = 'Seal of Righteousness', [SOC] = 'Seal of Command', [SOTC] = 'Seal of the Crusader',
    [RF] = 'Righteous Fury', [SERPENT] = 'Serpent Sting', [SCORPID] = 'Scorpid Sting' }
C_Spell = {
    GetSpellName = function(id) return names[id] end,
    GetSpellTexture = function(id) return id end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
    GetSpellCharges = function() return nil end,
    GetSpellDescription = function(id) return (id == SERPENT or id == SCORPID) and 'Stings the target over 15 sec.' or '' end,
}

-- The world: auras on the player, one target at a time, and combat hiding every aura.
local aurasLocked, target, enemy = false, nil, false
local playerAuras, mobDebuffs = {}, {}
UnitExists = function(unit) return unit == 'target' and target ~= nil end
UnitGUID = function(unit) return unit == 'target' and target or nil end
UnitCanAttack = function() return enemy end
C_Secrets = { ShouldAurasBeSecret = function() return aurasLocked end, ShouldSpellAuraBeSecret = function() return aurasLocked end }
C_UnitAuras = {
    GetPlayerAuraBySpellID = function(id)
        if aurasLocked then error('Auras cannot be accessed when secret while tainted') end
        return playerAuras[id]
    end,
    GetAuraDataByIndex = function(unit, i)
        if aurasLocked then error('Auras cannot be accessed when secret while tainted') end
        return (mobDebuffs[target] or {})[i]
    end,
}

-- Righteous Fury first, then three seals combined into one icon; two stings combined.
ForeverCDMDB = { buffs = { RF, SOR, SOC, SOTC }, debuffs = { SERPENT, SCORPID },
    links = { buffs = { SOC, SOTC }, debuffs = { SCORPID } }, buffDurations = { [SOR] = 30, [SOC] = 30, [SOTC] = 30 }, hideInactive = false }
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')
local function fire(event, ...)
    for _, f in ipairs(frames) do if f.events[event] then f.scripts.OnEvent(f, event, ...) end end
end
fire('PLAYER_LOGIN')

local function bar(row)
    local t = {}
    for _, f in ipairs(frames) do if f.parent == row and f.members and f.shown then t[#t + 1] = f end end
    table.sort(t, function(a, b) return a.slot < b.slot end)
    return t
end

-- 1. Four buffs draw as two icons: Righteous Fury, and one icon for the three seals.
local buffs = bar(ForeverCDM_buffs)
assert(#buffs == 2 and buffs[1].spellID == RF and #buffs[2].members == 3, 'the seals were not combined into one icon')
local seal = buffs[2]
assert(seal.alpha == 0.25 and seal.icon.texture == SOR, 'no seal up: the icon should be dim, showing the first seal')

-- 2. Seal of Command is up: the icon wears it, lit, with its real timer.
playerAuras[SOC] = { duration = 30, expirationTime = now + 30, auraInstanceID = 11, applications = 0 }
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(seal.spellID == SOC and seal.icon.texture == SOC and seal.alpha == 1 and seal.cd.cdDur == 30,
    'the combined icon should show the seal that is up')

-- 3. In combat every aura read is refused. Casting Seal of the Crusader replaces Command:
--    the ONE icon switches to it, timed from the cast. (Separate icons would leave
--    Command lit too, because its removal cannot be seen in combat.)
aurasLocked, now = true, 1010
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast', SOTC)
assert(seal.spellID == SOTC and seal.icon.texture == SOTC and seal.alpha == 0.85
    and seal.cd.cdStart == 1010 and seal.cd.cdDur == 30, 'casting another seal in combat should switch the icon to it')
now = 1041
fire('UNIT_AURA', 'player', nil)
assert(seal.alpha == 0.25, 'the seal timer ran out: the icon should dim')
aurasLocked = false
playerAuras = {}
fire('UNIT_AURA', 'player', { isFullUpdate = true })

-- 4. Stings: one icon, and each target remembers which sting it got.
local sting = bar(ForeverCDM_debuffs)[1]
assert(#bar(ForeverCDM_debuffs) == 1 and #sting.members == 2, 'the stings were not combined')
target = 'mob-A'
mobDebuffs['mob-A'] = { { spellId = SCORPID, name = 'Scorpid Sting', duration = 120, expirationTime = now + 120, auraInstanceID = 5 } }
fire('PLAYER_TARGET_CHANGED')
assert(sting.spellID == SCORPID and sting.alpha == 1, 'the combined icon should show the sting on the target')
aurasLocked, now = true, 1100
target = 'mob-B'
fire('PLAYER_TARGET_CHANGED')
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast', SERPENT)
assert(sting.spellID == SERPENT and sting.alpha == 0.85 and sting.cd.cdStart == 1100, 'casting a sting in combat should show it')
target = 'mob-A'
fire('PLAYER_TARGET_CHANGED')
assert(sting.spellID == SCORPID and sting.alpha == 0.85, 'back on the first target, its own sting should show')
aurasLocked = false
fire('PLAYER_REGEN_ENABLED')

-- 5. Taking off the first seal keeps the other two together, and they must not
--    join Righteous Fury before them.
ForeverCDM.RemoveEntry('buffs', 2)
ForeverCDM.Refresh()
buffs = bar(ForeverCDM_buffs)
assert(#buffs == 2 and buffs[1].spellID == RF and #buffs[1].members == 1 and #buffs[2].members == 2,
    'removing the first seal broke the combined icon or merged it into the one before')
-- Moving a combined entry to the front of the bar separates it: nothing is before it.
ForeverCDM.MoveEntry('buffs', 3, -1)
ForeverCDM.MoveEntry('buffs', 2, -1)
ForeverCDM.Refresh()
assert(ForeverCDMDB.buffs[1] == SOTC and not ForeverCDM.IsLinked('buffs', SOTC) and #bar(ForeverCDM_buffs) == 3,
    'an entry moved to the front should stand alone')
-- Clearing a bar clears its combinations too.
ForeverCDM.ClearBar('debuffs')
assert(#ForeverCDMDB.debuffs == 0 and #ForeverCDMDB.links.debuffs == 0, 'clearing a bar left its combinations behind')

-- 6. Out of combat the bars can fade or hide; combat, an enemy target and unlocking bring them back.
local rowAlpha = function() return ForeverCDM_buffs.alpha end
assert(rowAlpha() == 1, 'by default the bars stay shown out of combat')
SlashCmdList.FOREVERCDM('fade fade')
assert(ForeverCDMDB.fade == 'fade' and rowAlpha() == 0.3, 'fade: out of combat the bars should go faint')
fire('PLAYER_REGEN_DISABLED')
assert(rowAlpha() == 1, 'in combat the bars should come back')
fire('PLAYER_REGEN_ENABLED')
assert(rowAlpha() == 0.3, 'after combat the bars should fade again')
target, enemy = 'mob-C', true
fire('PLAYER_TARGET_CHANGED')
assert(rowAlpha() == 1, 'targeting an enemy should bring the bars back')
issecretvalue = function(v) return v == 'SECRET' end
enemy = 'SECRET'
fire('PLAYER_TARGET_CHANGED')
assert(rowAlpha() == 1, 'when the client will not say whether the target is an enemy, show the bars')
issecretvalue = function() return false end
target, enemy = nil, false
fire('PLAYER_TARGET_CHANGED')
assert(rowAlpha() == 0.3, 'without a target the bars should fade again')
ForeverCDM_SetLocked(false)
assert(rowAlpha() == 1, 'unlocked rows should always be shown')
ForeverCDM_SetLocked(true)
SlashCmdList.FOREVERCDM('fade hide')
assert(rowAlpha() == 0 and ForeverCDM_debuffs.alpha == 0, 'hide: out of combat the bars should disappear')
SlashCmdList.FOREVERCDM('fade show')
assert(ForeverCDMDB.fade == nil and rowAlpha() == 1, 'show: the bars should stay as they are')

print('combined seals and stings, removal and ordering, and fade out of combat checks passed')
