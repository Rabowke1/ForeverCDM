-- Combo points counted with the help of the combat log: misses, dodges and
-- parries take a builder back, a dodged finisher keeps its points, logged
-- combo point gains replace the tooltip count. Run from ForeverCDM:
--   lua tests/test_combat_log.lua
unpack = table.unpack
strlower = string.lower
strtrim = function(s) return s:match('^%s*(.-)%s*$') end
local SECRET = {}
issecretvalue = function(v) return v == SECRET end
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
-- widget calls the addon makes that the test does not care about
for _, name in ipairs({ 'SetTexCoord', 'ClearAllPoints', 'SetMovable', 'SetClampedToScreen', 'SetDrawEdge',
    'SetHideCountdownNumbers', 'SetDesaturated', 'SetCooldownFromDurationObject', 'SetAllPoints',
    'SetColorTexture', 'RegisterForDrag', 'SetPoint', 'SetTexture', 'EnableMouse' }) do methods[name] = noop end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:GetWidth() return self.width or 100 end
function methods:GetEffectiveScale() return 1 end
function methods:SetText(t) self.textValue = t end
function methods:SetAlpha(a) self.alpha = a end
function methods:SetScript(k, fn) self.scripts[k] = fn end
function methods:RegisterEvent(e) self.events[e] = true end
function methods:RegisterUnitEvent(e) self.events[e] = true end
function methods:CreateTexture() return object('Texture', nil, self) end
function methods:CreateFontString() return object('FontString', nil, self) end
function methods:IsShown() return self.shown end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetShown(v) self.shown = v and true or false end
-- record what the cooldown widget was told
function methods:SetCooldown(start, dur) self.cdStart, self.cdDur = start, dur end
function methods:Clear() self.cdStart, self.cdDur = nil, nil end

CreateFrame = object
UIParent = object('Frame')
C_Timer = { NewTicker = noop }

local now = 1000
GetTime = function() return now end

local SND, SS, EVIS, RUPTURE, CHEAP = 5171, 1752, 2098, 1943, 1833
local names = { [SND] = 'Slice and Dice', [SS] = 'Sinister Strike', [EVIS] = 'Eviscerate', [RUPTURE] = 'Rupture', [CHEAP] = 'Cheap Shot' }
local descriptions = {
    [SND] = 'Finishing move that increases melee attack speed by 20%.  Lasts longer per combo point:\r\n'
        .. '   1 point  : 9 seconds\r\n   2 points: 12 seconds\r\n   3 points: 15 seconds\r\n'
        .. '   4 points: 18 seconds\r\n   5 points: 21 seconds',
    [EVIS] = 'Finishing move that causes damage per combo point:\r\n   1 point  : 6-10 damage\r\n   2 points: 12-16 damage',
    [RUPTURE] = 'Finishing move that causes damage over time.  Lasts longer per combo point:\r\n'
        .. '   1 point  : 40 damage over 8 secs\r\n   2 points: 60 damage over 10 secs',
    [SS] = 'An instant strike that causes 3 damage in addition to your normal weapon damage.  Awards 1 combo point.',
    [CHEAP] = 'Stuns the target for 4 sec.  Must be stealthed.  Awards 2 combo points.',
}
C_Spell = {
    GetSpellName = function(id) return names[id] end,
    GetSpellTexture = function(id) return id end,
    GetSpellDescription = function(id) return descriptions[id] end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
    GetSpellCharges = function() return nil end,
}
Enum = { PowerType = { ComboPoints = 4 } }
UnitPower = function() return SECRET end            -- Forever: the combo point count is secret
UnitGUID = function(unit) if unit == 'target' then return 'mob-A' end return 'Player-1' end
UnitExists = function(unit) return unit == 'target' end
C_Secrets = { ShouldAurasBeSecret = function() return true end, ShouldSpellAuraBeSecret = function() return true end }
C_UnitAuras = {
    GetPlayerAuraBySpellID = function() error('Auras cannot be accessed when secret while tainted') end,
    GetAuraDataByIndex = function() error('Auras cannot be accessed when secret while tainted') end,
}

-- The combat log, as COMBAT_LOG_EVENT_UNFILTERED hands it out.
local logEntry, logSecret = {}, false
CombatLogGetCurrentEventInfo = function()
    if logSecret then return 0, SECRET, false, SECRET end
    return unpack(logEntry)
end

ForeverCDMDB = { buffs = { SND }, debuffs = { RUPTURE } }
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')
local function fire(event, ...)
    for _, f in ipairs(frames) do if f.events[event] then f.scripts.OnEvent(f, event, ...) end end
end
fire('PLAYER_LOGIN')
fire('PLAYER_REGEN_DISABLED')

local snd, rupture
for _, f in ipairs(frames) do
    if f.spellID == SND and f.parent == ForeverCDM_buffs then snd = f end
    if f.spellID == RUPTURE and f.parent == ForeverCDM_debuffs then rupture = f end
end
assert(snd and rupture, 'icons were not created')

-- each cast takes a global cooldown (one second here)
local function cast(id) now = now + 1 fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', id) end
local function log(sub, id, ...)
    logEntry = { now, sub, false, 'Player-1', 'Me', 0, 0, 'mob-A', 'Mob', 0, 0, id, names[id], 1, ... }
    fire('COMBAT_LOG_EVENT_UNFILTERED')
end

-- 1. Three Sinister Strikes, the second one dodged (the log entry comes after the cast):
--    2 points, so Slice and Dice runs 12 s.
cast(SS)  log('SPELL_DAMAGE', SS, 50)
cast(SS)  log('SPELL_MISSED', SS, 'DODGE')
cast(SS)  log('SPELL_DAMAGE', SS, 50)
cast(SND)
assert(snd.cd.cdStart == 1004 and snd.cd.cdDur == 12, 'a dodged builder must not count: expected 12 s, got ' .. tostring(snd.cd.cdDur))

-- 2. The log entry can also come BEFORE the cast event: a parried strike still counts nothing.
now = 1101
log('SPELL_MISSED', SS, 'PARRY')  fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SS)
now = 1102
cast(SS)  cast(SS)
cast(SND)
assert(snd.cd.cdDur == 12, 'a parried builder logged before its cast must not count: expected 12 s, got ' .. tostring(snd.cd.cdDur))

-- 3. A dodged finisher spends nothing: the points are still there for the next one.
now = 1200
cast(CHEAP)  cast(SS)                            -- 3 points
cast(EVIS)   log('SPELL_MISSED', EVIS, 'DODGE')
cast(SND)
assert(snd.cd.cdStart == 1204 and snd.cd.cdDur == 15, 'a dodged finisher must keep the points: expected 15 s, got ' .. tostring(snd.cd.cdDur))

-- 4. A dodged Rupture puts no debuff up, so it starts no timer; a landed one does.
now = 1300
cast(SS)  cast(SS)
cast(RUPTURE)  log('SPELL_MISSED', RUPTURE, 'DODGE')
fire('UNIT_AURA', 'target', nil)
assert(rupture.inactive, 'a dodged Rupture must not show a timer')
cast(RUPTURE)
fire('UNIT_AURA', 'target', nil)
assert(not rupture.inactive and rupture.cd.cdDur == 10, 'Rupture with the 2 points kept should run 10 s, got ' .. tostring(rupture.cd.cdDur))

-- 5. Where the log reports combo point gains (Seal Fate crits...), those are
--    counted instead of the tooltips: a crit giving 2 points counts 2.
now = 1400
cast(SS)  log('SPELL_ENERGIZE', SS, 2, 0, 4)
cast(SS)  log('SPELL_ENERGIZE', SS, 1, 0, 4)
cast(SND)
assert(snd.cd.cdStart == 1403 and snd.cd.cdDur == 15, 'logged gains should give 3 points: expected 15 s, got ' .. tostring(snd.cd.cdDur))

-- 6. Other players' entries change nothing.
now = 1500
cast(SS)
logEntry = { now, 'SPELL_MISSED', false, 'Player-2', 'Other', 0, 0, 'mob-A', 'Mob', 0, 0, SS, names[SS], 1, 'DODGE' }
fire('COMBAT_LOG_EVENT_UNFILTERED')
log('SPELL_ENERGIZE', SS, 1, 0, 4)
cast(SND)
assert(snd.cd.cdDur == 9, "another player's miss must not take our point back, got " .. tostring(snd.cd.cdDur))

-- 7. A log whose entries are secret is left alone, and the diagnostic reports it.
logSecret = true
fire('COMBAT_LOG_EVENT_UNFILTERED')
local printed = {}
local oldPrint = print
print = function(line) printed[#printed + 1] = line end
SlashCmdList.FOREVERCDM('combo')
print = oldPrint
assert(printed[1]:find('<secret>', 1, true) and printed[2]:find('its entries are secret', 1, true), '/fcdm combo should report the state')

print('combat log: dodged and parried builders, dodged finishers and debuffs, logged gains checks passed')
