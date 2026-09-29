-- Buffs that are shown only while up, and finishers (Slice and Dice) whose
-- length depends on combo points. Loads the real addon against a tiny fake UI.
-- Run from ForeverCDM: lua tests/test_finishers.lua
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

-- Slice and Dice: a finisher whose length depends on the combo points spent.
local SND, OTHER, CHEAP = 5171, 300, 1833
local names = { [SND] = 'Slice and Dice', [OTHER] = 'Sinister Strike', [CHEAP] = 'Cheap Shot' }
local descriptions = {
    [SND] = 'Finishing move that increases melee attack speed by 20%.  Lasts longer per combo point:\r\n'
        .. '   1 point  : 9 seconds\r\n   2 points: 12 seconds\r\n   3 points: 15 seconds\r\n'
        .. '   4 points: 18 seconds\r\n   5 points: 21 seconds',
    [OTHER] = 'An instant strike that causes 3 damage in addition to your normal weapon damage.  Awards 1 combo point.',
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
local combo, comboSecret = 0, false
local SECRET = {}
issecretvalue = function(v) return v == SECRET end
UnitPower = function(unit, power) assert(unit == 'player' and power == 4) if comboSecret then return SECRET end return combo end
local target = 'mob-A'
UnitGUID = function(unit) if unit == 'target' then return target end return 'Player-1' end
UnitExists = function(unit) return unit == 'target' end

local aurasLocked, aura = false, nil
C_Secrets = {
    ShouldAurasBeSecret = function() return aurasLocked end,
    ShouldSpellAuraBeSecret = function() return aurasLocked end,
}
C_UnitAuras = {
    GetPlayerAuraBySpellID = function(id)
        if aurasLocked then error('Auras cannot be accessed when secret while tainted') end
        if aura and id == SND then return aura end
        return nil
    end,
}

-- A fresh install: "hide inactive auras" is the default.
ForeverCDMDB = { buffs = { SND } }
assert(loadfile('ForeverCDM.lua'))('ForeverCDM')
local function fire(event, ...)
    for _, f in ipairs(frames) do if f.events[event] then f.scripts.OnEvent(f, event, ...) end end
end
fire('PLAYER_LOGIN')
assert(ForeverCDMDB.hideInactive == true, 'hide inactive auras should be on by default')

local icon
for _, f in ipairs(frames) do if f.spellID == SND and f.parent == ForeverCDM_buffs then icon = f end end
assert(icon, 'buff icon was not created')

-- 1. Never used: hidden, out of combat and in combat alike.
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(icon.alpha == 0, 'unused buff must be hidden out of combat')
aurasLocked = true
fire('PLAYER_REGEN_DISABLED')
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 0, 'unused buff must be hidden in combat, not shown as "?"')

-- 2. First Slice and Dice ever, in combat, with 3 points. Nothing was learned,
--    so the tooltip's table gives the length. The power update may come after
--    the cast event...
now = 1010
combo = 3 fire('UNIT_POWER_FREQUENT', 'player', 'COMBO_POINTS')
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SND)
combo = 0 fire('UNIT_POWER_FREQUENT', 'player', 'COMBO_POINTS')
assert(icon.alpha == 0.85, 'cast in combat should show the buff')
assert(icon.cd.cdStart == 1010 and icon.cd.cdDur == 15, '3-point Slice and Dice should run 15 s, got ' .. tostring(icon.cd.cdDur))

-- 3. ...or before it: the points spent a moment ago still count.
now = 1020
combo = 5 fire('UNIT_POWER_FREQUENT', 'player', 'COMBO_POINTS')
combo = 0 fire('UNIT_POWER_FREQUENT', 'player', 'COMBO_POINTS')
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SND)
assert(icon.cd.cdStart == 1020 and icon.cd.cdDur == 21, '5-point Slice and Dice should run 21 s')

-- 4. It runs out in combat: hidden again.
now = 1042
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 0 and icon.cd.cdDur == nil, 'expired Slice and Dice must disappear')

-- 5. Out of combat the real aura is read, and its length learned per combo
--    point (talents can make it longer than the tooltip says).
aurasLocked = false
fire('PLAYER_REGEN_ENABLED')
now = 1100
combo = 2 fire('UNIT_POWER_FREQUENT', 'player', 'COMBO_POINTS')
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SND)
aura = { auraInstanceID = 9, duration = 13.8, expirationTime = now + 13.8, applications = 0 }
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(icon.alpha == 1 and icon.cd.cdDur == 13.8, 'readable aura should draw its real timer')
assert(ForeverCDMDB.comboDurations[SND][2] == 13.8, 'length per combo point was not learned')

-- 6. Up when the fight starts, then it runs out while the client hides auras:
--    the expiry read before combat takes it away.
aurasLocked = true
fire('PLAYER_REGEN_DISABLED')
now = 1105
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 0.85, 'buff known before combat should stay while it lasts')
now = 1114
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 0, 'buff known before combat must disappear once its time is up')

-- 7. The learned 2-point length now beats the tooltip in combat.
now = 1200
combo = 2 fire('UNIT_POWER_FREQUENT', 'player', 'COMBO_POINTS')
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SND)
assert(icon.cd.cdDur == 13.8, 'learned per-point length should be used, got ' .. tostring(icon.cd.cdDur))

-- 8. An unrelated cast does not show it.
now = 1300
fire('UNIT_AURA', 'player', nil)
assert(icon.alpha == 0, 'expired again')
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', OTHER)
assert(icon.alpha == 0, 'another spell must not show Slice and Dice')

-- 9. On Forever the combo point count is secret. It is counted from our own
--    casts instead: three Sinister Strikes, then Slice and Dice for 3 points.
comboSecret = true
now = 1400
target = 'mob-C'      -- a fresh target: step 8's point stays on mob-A
for _ = 1, 3 do fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', OTHER) end
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SND)
assert(icon.alpha == 0.85 and icon.cd.cdStart == 1400 and icon.cd.cdDur == 15,
    'counted 3 points should give 15 s, got ' .. tostring(icon.cd.cdDur))
-- A counted value may be off (a dodged strike still casts), so it is not learned.
aurasLocked = false
aura = { auraInstanceID = 10, duration = 16, expirationTime = now + 16, applications = 0 }
fire('UNIT_AURA', 'player', { isFullUpdate = true })
assert(ForeverCDMDB.comboDurations[SND][3] == nil, 'a counted combo point value must not be learned')
aura, aurasLocked = nil, true
fire('UNIT_AURA', 'player', nil)

-- 10. The finisher spent them: the next count starts at zero. Cheap Shot awards
--     two, and the count stops at five.
now = 1500
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', CHEAP)
for _ = 1, 4 do fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', OTHER) end
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SND)
assert(icon.cd.cdStart == 1500 and icon.cd.cdDur == 21, 'counted 5 points (capped) should give 21 s, got ' .. tostring(icon.cd.cdDur))

-- 11. Combo points belong to a target: points built on another one do not count.
now = 1600
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', OTHER)
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', OTHER)
target = 'mob-B'
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', OTHER)
fire('UNIT_SPELLCAST_SUCCEEDED', 'player', 'cast-guid', SND)
assert(icon.cd.cdStart == 1600 and icon.cd.cdDur == 9, 'only the point on the new target counts: 9 s, got ' .. tostring(icon.cd.cdDur))

print('finisher durations by combo point, counted combo points, hidden unused buffs and expiry in combat checks passed')
