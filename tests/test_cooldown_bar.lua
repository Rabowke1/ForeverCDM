-- Cooldown bar showing only spells on cooldown, and icons centred on their bars.
-- Loads the real addon against a tiny fake UI. Run from ForeverCDM:
--   lua tests/test_cooldown_bar.lua
unpack = table.unpack
strlower = string.lower
strtrim = function(s) return s:match('^%s*(.-)%s*$') end
local SECRET = setmetatable({}, { __tostring = function() return 'secret' end })
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

-- remember where each icon sits: offset from the row's centre
function methods:SetPoint(point, rel, relPoint, x) if rel == UIParent then return end self.anchor, self.x = point .. '/' .. relPoint, x end

local now = 1000
GetTime = function() return now end

-- Kick (10 s cooldown), Sinister Strike (no cooldown), Evasion (30 s cooldown); Slice and Dice buff.
local KICK, SS, EVASION, SND, BLADE = 1766, 1752, 5277, 5171, 13877
local names = { [KICK] = 'Kick', [SS] = 'Sinister Strike', [EVASION] = 'Evasion', [SND] = 'Slice and Dice', [BLADE] = 'Blade Flurry' }
local cooldowns = {}          -- spellID -> { start, duration }
local timingSecret = false    -- combat: the client hides cooldown timings from addons
C_Spell = {
    GetSpellName = function(id) return names[id] end,
    GetSpellTexture = function(id) return id end,
    GetSpellCooldown = function(id)
        if timingSecret then return { startTime = SECRET, duration = SECRET, isEnabled = SECRET, modRate = SECRET } end
        local c = cooldowns[id]
        if c and now < c[1] + c[2] then return { startTime = c[1], duration = c[2], isEnabled = true } end
        return { startTime = 0, duration = 0, isEnabled = true }
    end,
    GetSpellCooldownDuration = function() return {} end,
    GetSpellCharges = function() return nil end,
}
local auraUp = {}
C_Secrets = { ShouldAurasBeSecret = function() return false end }
C_UnitAuras = {
    GetPlayerAuraBySpellID = function(id)
        if auraUp[id] then return { auraInstanceID = id, duration = 20, expirationTime = now + 20, applications = 0 } end
    end,
}

-- A fresh install: "hide ready cooldowns" and "hide inactive auras" are the defaults.
ForeverCDMDB = { cds = { KICK, SS, EVASION }, buffs = { SND, BLADE } }
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')
local function fire(event, ...)
    for _, f in ipairs(frames) do if f.events[event] then f.scripts.OnEvent(f, event, ...) end end
end
fire('PLAYER_LOGIN')
assert(ForeverCDMDB.hideReady == true, 'hide ready cooldowns should be on by default')

local icon = {}
for _, f in ipairs(frames) do
    if f.spellID and (f.parent == ForeverCDM_cds or f.parent == ForeverCDM_buffs) then icon[f.spellID] = f end
end
local STEP = 36 + 4     -- icon size + spacing

-- 1. Nothing on cooldown: the bar is empty.
fire('SPELL_UPDATE_COOLDOWN')
assert(icon[KICK].alpha == 0 and icon[SS].alpha == 0 and icon[EVASION].alpha == 0, 'ready spells must be hidden')

-- 2. One spell on cooldown sits in the middle; two spread evenly to both sides.
cooldowns[EVASION] = { now, 30 }
fire('SPELL_UPDATE_COOLDOWN')
assert(icon[EVASION].alpha == 1 and icon[EVASION].anchor == 'CENTER/CENTER' and icon[EVASION].x == 0,
    'a single icon should be centred, got x=' .. tostring(icon[EVASION].x))
cooldowns[KICK] = { now, 10 }
fire('SPELL_UPDATE_COOLDOWN')
assert(icon[KICK].x == -STEP / 2 and icon[EVASION].x == STEP / 2, 'two icons should sit evenly around the centre, in list order')
assert(ForeverCDMDB.cdLengths[KICK] == 10 and ForeverCDMDB.cdLengths[EVASION] == 30, 'cooldown lengths were not learned')

-- 3. A spell without a cooldown: after the global cooldown it is known to have none.
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast', SS)
now = now + 1.5
fire('SPELL_UPDATE_COOLDOWN')
assert(ForeverCDMDB.cdLengths[SS] == 0, 'a spell with no cooldown should be learned as such')
assert(icon[SS].alpha == 0, 'a spell with no cooldown must stay hidden')

-- 4. Combat hides the timings. Kick was due at 1010: it stays until then, then goes.
timingSecret = true
now = 1005
fire('SPELL_UPDATE_COOLDOWN')
assert(icon[KICK].alpha == 1 and icon[EVASION].alpha == 1, 'cooldowns running before combat stay visible')
now = 1011
fire('SPELL_UPDATE_COOLDOWN')
assert(icon[KICK].alpha == 0, 'a cooldown due before combat ended must disappear')
assert(icon[EVASION].x == 0, 'the remaining icon moves to the middle')

-- 5. Casting in combat: Kick shows for its learned 10 s, Sinister Strike never.
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast', KICK)
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast', SS)
assert(icon[KICK].alpha == 1 and icon[SS].alpha == 0, 'our own cast should show a spell with a cooldown, not one without')
now = 1022
fire('SPELL_UPDATE_COOLDOWN')
assert(icon[KICK].alpha == 0, 'the estimated cooldown ran out')

-- 6. Buffs are centred the same way.
auraUp[BLADE] = true
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(icon[SND].alpha == 0 and icon[BLADE].alpha == 1 and icon[BLADE].x == 0, 'the only buff up should be centred')
auraUp[SND] = true
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(icon[SND].x == -STEP / 2 and icon[BLADE].x == STEP / 2, 'two buffs should sit evenly around the centre')

-- 7. Unlocked, every icon keeps its place so the bar can be dragged.
timingSecret = false
ForeverCDM_SetLocked(false)
fire('SPELL_UPDATE_COOLDOWN')
assert(icon[KICK].alpha == 1 and icon[KICK].x == -STEP and icon[SS].x == 0 and icon[EVASION].x == STEP,
    'unlocked rows should show every icon')

print('cooldown bar: ready spells hidden, combat estimates, centred icons checks passed')
