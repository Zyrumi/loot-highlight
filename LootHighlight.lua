-- Loot Highlight: core
-- Makes nearby pickable/lootable things easy to notice.
--
-- Addons cannot scan the world for objects, but the game itself tracks the
-- nearest interactable thing ("soft interact target"). This addon:
--   1. Turns on the game's own soft-interact settings so an icon and a name
--      float above the nearest herb, ore, chest, quest object or corpse.
--   2. Works out what kind of thing it is from the mouse cursor the game would
--      show for it (flower = herb, pick = ore, gear = chair/door, ...), and only
--      alerts for the kinds the player wants.
--   3. Draws twinkling glints on the object, shows a banner and plays a ping.
--
-- The settings page lives in Options.lua.

local ADDON_NAME, ns = ...

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

-- Starting color per type. Players can change each one on the settings
-- page (the game's color picker). Used for the glints and the banner.
ns.DEFAULT_COLORS = {
    herbs    = { 0.55, 1.00, 0.55 },
    ore      = { 1.00, 0.65, 0.35 },
    skinning = { 0.95, 0.78, 0.55 },
    loot     = { 1.00, 0.85, 0.30 },
    corpses  = { 1.00, 0.96, 0.72 },
    other    = { 0.75, 0.80, 0.90 },
}

-- What the player can choose to be alerted about.
ns.CATEGORIES = {
    { key = "herbs",    label = "Herbs",            heading = "Herb nearby",               icon = "Interface\\Icons\\INV_Misc_Herb_07", skill = 182, profession = "Herbalism" },
    { key = "ore",      label = "Ore veins",        heading = "Ore vein nearby",           icon = "Interface\\Icons\\INV_Ore_Copper_01", skill = 186, profession = "Mining" },
    { key = "skinning", label = "Skinnable corpses", heading = "Skinnable corpse nearby",  icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01", skill = 393, profession = "Skinning" },
    { key = "loot",     label = "Chests and quest objects", heading = "Something to pick up nearby", icon = "Interface\\Icons\\INV_Misc_Bag_10" },
    { key = "corpses",  label = "Corpses with loot", heading = "Corpse with loot nearby",  icon = "Interface\\Icons\\INV_Misc_Bag_10" },
    { key = "other",    label = "Chairs, doors, mailboxes", heading = "Something to use nearby", icon = "Interface\\Icons\\INV_Misc_Gear_01" },
}
local CATEGORY_BY_KEY = {}
for _, c in ipairs(ns.CATEGORIES) do
    CATEGORY_BY_KEY[c.key] = c
end

-- Outline Mode values the game uses: 0 off, 1 good, 2 high.
ns.OUTLINE_VALUES = { high = "2", good = "1", off = "0" }

local MAX_GLINTS = 24
local STAR_TEXTURE = "Interface\\Cooldown\\star4"
ns.STAR_TEXTURE = STAR_TEXTURE

local DEFAULTS = {
    enabled = true,
    -- "auto" = only if the character has the matching profession.
    show = {
        herbs = "auto",
        ore = "auto",
        skinning = "auto",
        loot = "on",
        corpses = "on",
        other = "off",
    },
    marker = true,        -- glints drawn over the object in the world
    gameIcon = true,      -- the game's own interact icon (pickaxe, flower...)
    style = "glints",     -- "glints" or "star"
    glints = 18,
    markerSize = 110,     -- width of the glint cloud
    -- The game only tells addons where its interact icon is, which sits
    -- above the object. This moves the cloud down from there onto it.
    markerOffset = -110,
    colors = ns.DEFAULT_COLORS, -- copied into the saved settings on load
    -- The game's own outline around the targeted object (Outline Mode).
    -- "keep" leaves the player's graphics setting alone.
    outline = "keep",
    banner = true,
    sound = true,
    questSparkle = true,  -- keep the game's quest item sparkle on at low graphics
    range = 30,           -- yards asked for; the game caps it at its own maximum
    ignore = {},          -- object names that should not trigger alerts
    savedCVars = nil,     -- the player's own values, restored when turned off
}

local db
local pendingCVarAction -- "apply" or "restore", run after combat
-- Soft interact is switched off for a moment while it points at a living
-- player or NPC, and during combat, so spells cast without a target land on
-- you and not on them. nil, "unit" or "combat".
local interactPaused
local lastGUID
local lastSoundTime = 0

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Print(msg)
    print("|cff66ccffLoot Highlight:|r " .. msg)
end
ns.Print = Print

-- Midnight-era clients can hand addons "secret" values that may not be
-- compared or sliced. Treat those as unknown instead of erroring.
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function GetCVarSafe(name)
    if C_CVar and C_CVar.GetCVar then
        return C_CVar.GetCVar(name)
    end
    return GetCVar(name)
end

-- Writes only when the value changes: every write runs Blizzard's own
-- setting handlers in our name, which can taint them (error popups that
-- blame this addon), so needless writes are worth avoiding.
local function SetCVarSafe(name, value)
    value = tostring(value)
    local ok = pcall(function()
        local current = GetCVarSafe(name)
        if current ~= nil and (current == value
            or (tonumber(current) ~= nil and tonumber(current) == tonumber(value))) then
            return
        end
        if C_CVar and C_CVar.SetCVar then
            C_CVar.SetCVar(name, value)
        else
            SetCVar(name, value)
        end
    end)
    return ok
end

-- Fills in missing settings without touching ones the player already has.
local function MergeDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            if k ~= "ignore" then
                MergeDefaults(v, dst[k])
            end
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

-- Puts every saved setting back in a usable range, so a damaged or hand-
-- edited save file can never break the addon.
local function Sanitize()
    local function Num(key, lo, hi, fallback)
        local v = tonumber(db[key])
        if not v or v ~= v then -- missing or NaN
            v = fallback
        end
        db[key] = math.max(lo, math.min(hi, math.floor(v + 0.5)))
    end
    Num("range", 5, 60, DEFAULTS.range)
    Num("glints", 1, MAX_GLINTS, DEFAULTS.glints)
    Num("markerSize", 24, 300, DEFAULTS.markerSize)
    Num("markerOffset", -300, 60, DEFAULTS.markerOffset)

    local VALID_SHOW = { auto = true, on = true, off = true }
    for _, c in ipairs(ns.CATEGORIES) do
        local v = db.show[c.key]
        if v == true then
            v = "on"
        elseif v == false then
            v = "off"
        end
        if not VALID_SHOW[v] or (v == "auto" and not c.skill) then
            v = DEFAULTS.show[c.key]
        end
        db.show[c.key] = v
    end

    for key, def in pairs(ns.DEFAULT_COLORS) do
        local c = db.colors[key]
        local ok = type(c) == "table"
        if ok then
            for i = 1, 3 do
                local v = tonumber(c[i])
                if not v then
                    ok = false
                else
                    c[i] = math.max(0, math.min(1, v))
                end
            end
        end
        if not ok then
            db.colors[key] = { def[1], def[2], def[3] }
        end
    end

    if db.style ~= "glints" and db.style ~= "star" then
        db.style = DEFAULTS.style
    end
    if db.outline ~= "keep" and not ns.OUTLINE_VALUES[db.outline] then
        db.outline = DEFAULTS.outline
    end
    for _, key in ipairs({ "enabled", "marker", "gameIcon", "banner", "sound", "questSparkle" }) do
        if type(db[key]) ~= "boolean" then
            db[key] = DEFAULTS[key]
        end
    end
    -- leftovers from the minimap scanner (removed in 2.9.2)
    db.minimapNodes, db.scanReport = nil, nil
    if type(db.ignore) ~= "table" then
        db.ignore = {}
    end
    if db.savedCVars ~= nil and type(db.savedCVars) ~= "table" then
        db.savedCVars = nil
    end
end

-------------------------------------------------------------------------------
-- Professions
-------------------------------------------------------------------------------

-- True when the character has the profession with this skill line ID.
local function KnowsSkill(skillLine)
    if not skillLine or not GetProfessions or not GetProfessionInfo then
        return true -- cannot tell, so do not hide anything
    end
    local ok, result = pcall(function()
        local p1, p2 = GetProfessions()
        for _, index in ipairs({ p1 or 0, p2 or 0 }) do
            if index ~= 0 then
                local line = select(7, GetProfessionInfo(index))
                if line == skillLine then
                    return true
                end
            end
        end
        return false
    end)
    return not ok or result
end
ns.KnowsSkill = KnowsSkill

-- The character's current skill in a profession: a number, false when the
-- profession is not learned, or nil when the game cannot tell us.
local function SkillRank(skillLine)
    if not skillLine or not GetProfessions or not GetProfessionInfo then
        return nil
    end
    local ok, rank = pcall(function()
        local p1, p2 = GetProfessions()
        for _, index in ipairs({ p1 or 0, p2 or 0 }) do
            if index ~= 0 then
                local _, _, r, _, _, _, line = GetProfessionInfo(index)
                if line == skillLine then
                    return tonumber(r) or 0
                end
            end
        end
        return false
    end)
    if ok then
        return rank
    end
    return nil
end
ns.SkillRank = SkillRank

-- Skill needed to gather classic nodes (English names). Used to tell "skill
-- too low" apart from "too far away", which look the same to addons.
local NODE_SKILL = {
    ore = {
        ["Copper Vein"] = 1, ["Tin Vein"] = 65, ["Incendicite Mineral Vein"] = 65,
        ["Silver Vein"] = 75, ["Lesser Bloodstone Deposit"] = 75, ["Iron Deposit"] = 125,
        ["Indurium Mineral Vein"] = 150, ["Gold Vein"] = 155, ["Mithril Deposit"] = 175,
        ["Truesilver Deposit"] = 230, ["Dark Iron Deposit"] = 230, ["Small Thorium Vein"] = 245,
        ["Hakkari Thorium Vein"] = 245, ["Rich Thorium Vein"] = 275, ["Thorium Vein"] = 245,
    },
    herbs = {
        ["Peacebloom"] = 1, ["Silverleaf"] = 1, ["Earthroot"] = 15, ["Mageroyal"] = 50,
        ["Briarthorn"] = 70, ["Stranglekelp"] = 85, ["Bruiseweed"] = 100, ["Wild Steelbloom"] = 115,
        ["Grave Moss"] = 120, ["Kingsblood"] = 125, ["Liferoot"] = 150, ["Fadeleaf"] = 160,
        ["Goldthorn"] = 170, ["Khadgar's Whisker"] = 185, ["Wintersbite"] = 195, ["Firebloom"] = 205,
        ["Purple Lotus"] = 210, ["Arthas' Tears"] = 220, ["Sungrass"] = 230, ["Blindweed"] = 235,
        ["Ghost Mushroom"] = 245, ["Gromsblood"] = 250, ["Golden Sansam"] = 260, ["Dreamfoil"] = 270,
        ["Mountain Silversage"] = 280, ["Plaguebloom"] = 285, ["Icecap"] = 290, ["Black Lotus"] = 300,
    },
}

local function NodeRequirement(category, name)
    local list = NODE_SKILL[category]
    if not list or type(name) ~= "string" or IsSecret(name) then
        return nil
    end
    return list[name] or list[(name:gsub("^Ooze Covered ", ""))]
end

-- Is this category switched on (taking "auto" into account)?
local function CategoryOn(key)
    local v = db.show[key]
    if v == "auto" then
        return KnowsSkill(CATEGORY_BY_KEY[key].skill)
    end
    return v == "on" or v == true
end
ns.CategoryOn = CategoryOn

-------------------------------------------------------------------------------
-- Game settings
-------------------------------------------------------------------------------

-- Game settings this addon changes. Values are strings, as the CVar API wants.
local function WantedCVars()
    local wanted = {
        SoftTargetInteract = interactPaused and "0" or "3", -- soft interact on (see interactPaused)
        SoftTargetInteractArc = "2",         -- anywhere around you, not only in front
        SoftTargetInteractRange = tostring(db.range),
        SoftTargetInteractOnlyInRange = "0", -- pick things a few steps away too
        SoftTargetIconGameObject = "1",      -- icon over objects (herbs, ore, chests)
        SoftTargetIconInteract = "0",        -- no icons over NPCs (objects use the line above)
        -- SoftTargetNameplateInteract is switched per target, see SetObjectPlate.
    }
    if db.questSparkle then
        wanted.outlineModeShowLootEffectWhenDisabled = "1"
    end
    local outline = ns.OUTLINE_VALUES[db.outline]
    if outline then
        wanted.graphicsOutlineMode = outline
        wanted.raidGraphicsOutlineMode = outline
    end
    return wanted
end

local function ApplyCVars()
    if InCombatLockdown() then
        pendingCVarAction = "apply"
        return
    end
    local wanted = WantedCVars()
    -- Remember the player's own value of each setting the first time we
    -- touch it, so turning the addon off can put them back.
    db.savedCVars = db.savedCVars or {}
    for name in pairs(wanted) do
        if db.savedCVars[name] == nil then
            db.savedCVars[name] = GetCVarSafe(name)
        end
    end
    -- Settings we no longer change (quest sparkle or outline switched back):
    -- hand the player's own value back.
    for name, value in pairs(db.savedCVars) do
        if wanted[name] == nil then
            SetCVarSafe(name, value)
            db.savedCVars[name] = nil
        end
    end
    for name, value in pairs(wanted) do
        -- Skip settings this client does not have.
        if GetCVarSafe(name) ~= nil then
            SetCVarSafe(name, value)
        end
    end
end
ns.ApplyCVars = ApplyCVars

-- The glints hang on the target's name plate, but a name plate on an NPC
-- shows a health bar. So the plate is only switched on while the target
-- is something we highlight, and off again for everything else.
local platePinned = nil
local function SetObjectPlate(on, force)
    on = on and true or false
    if (on == platePinned and not force) or InCombatLockdown() then
        return -- in combat: fixed up by the update after combat
    end
    local current = GetCVarSafe("SoftTargetNameplateInteract")
    if current == nil then
        return
    end
    -- Remember the player's own value once, and use it as "off", so a
    -- player who likes NPC name plates keeps them.
    if db.plateOriginal == nil then
        db.plateOriginal = current
    end
    SetCVarSafe("SoftTargetNameplateInteract", on and "1" or db.plateOriginal)
    platePinned = on
end
ns.SetObjectPlate = SetObjectPlate

local function RestoreCVars()
    if InCombatLockdown() then
        pendingCVarAction = "restore"
        return
    end
    interactPaused = nil
    if db.savedCVars then
        for name, value in pairs(db.savedCVars) do
            SetCVarSafe(name, value)
        end
        db.savedCVars = nil
    end
    if db.plateOriginal ~= nil then
        SetCVarSafe("SoftTargetNameplateInteract", db.plateOriginal)
        platePinned = nil
    end
end

-- The range the game reports back after we asked for db.range.
function ns.GameRange()
    return tonumber(GetCVarSafe("SoftTargetInteractRange"))
end

-------------------------------------------------------------------------------
-- Banner
-- A dark band that fades out at both ends, thin double lines in the
-- category's color, a framed icon with a turning glow, a few twinkles, a
-- shine that sweeps across when something new shows up, and soft
-- entrance/exit animations. Only textures that ship with the game are used.
-------------------------------------------------------------------------------

-- The color for a type. The banner text always names the type too, so
-- color is never the only clue.
local function CategoryColor(key)
    local c = db.colors[key] or ns.DEFAULT_COLORS[key] or ns.DEFAULT_COLORS.loot
    return c
end
ns.CategoryColor = CategoryColor

function ns.ResetColors()
    for key, c in pairs(ns.DEFAULT_COLORS) do
        db.colors[key] = { c[1], c[2], c[3] }
    end
end

local GREY = { 0.6, 0.6, 0.6 }

local BANNER_W, BANNER_H = 380, 66
local EDGE = BANNER_W * 0.24 -- width of the faded ends

local banner = CreateFrame("Frame", "LootHighlightBanner", UIParent)
banner:SetSize(BANNER_W, BANNER_H)
banner:SetPoint("TOP", UIParent, "TOP", 0, -140)
banner:SetFrameStrata("HIGH")
banner:Hide()

-- Horizontal color gradient, with a flat fallback if the API is missing.
local function Gradient(tex, r, g, b, a1, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if CreateColor and tex.SetGradient then
        local ok = pcall(tex.SetGradient, tex, "HORIZONTAL", CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
        if ok then
            return
        end
    end
    tex:SetColorTexture(r, g, b, (a1 + a2) / 2)
end

-- A strip across the banner that fades out at both ends.
local function Strip(layer, sublevel, height, side, y)
    local s = {}
    s.left = banner:CreateTexture(nil, layer, nil, sublevel)
    s.left:SetSize(EDGE, height)
    s.left:SetPoint(side .. "LEFT", banner, side .. "LEFT", 0, y)
    s.right = banner:CreateTexture(nil, layer, nil, sublevel)
    s.right:SetSize(EDGE, height)
    s.right:SetPoint(side .. "RIGHT", banner, side .. "RIGHT", 0, y)
    s.mid = banner:CreateTexture(nil, layer, nil, sublevel)
    s.mid:SetPoint("TOPLEFT", s.left, "TOPRIGHT")
    s.mid:SetPoint("BOTTOMRIGHT", s.right, "BOTTOMLEFT")
    function s.SetColor(r, g, b, a)
        Gradient(s.left, r, g, b, 0, a)
        s.mid:SetColorTexture(r, g, b, a)
        Gradient(s.right, r, g, b, a, 0)
    end
    return s
end

local band = Strip("BACKGROUND", 0, BANNER_H, "TOP", 0)
band.SetColor(0, 0, 0, 0.82)
local edgeLines = {
    { strip = Strip("ARTWORK", 0, 2, "TOP", 0), alpha = 0.95 },
    { strip = Strip("ARTWORK", 0, 1, "TOP", -4), alpha = 0.35 },
    { strip = Strip("ARTWORK", 0, 2, "BOTTOM", 0), alpha = 0.95 },
    { strip = Strip("ARTWORK", 0, 1, "BOTTOM", 4), alpha = 0.35 },
}

-- Icon with a thin colored frame and a slowly turning glow behind it.
local ICON_X = EDGE - 6
local iconGlow = banner:CreateTexture(nil, "BORDER")
iconGlow:SetSize(96, 96)
iconGlow:SetPoint("CENTER", banner, "LEFT", ICON_X + 22, 0)
iconGlow:SetTexture(STAR_TEXTURE)
iconGlow:SetBlendMode("ADD")

local iconFrame = banner:CreateTexture(nil, "ARTWORK", nil, 1)
iconFrame:SetSize(44, 44)
iconFrame:SetPoint("LEFT", banner, "LEFT", ICON_X, 0)
local iconInner = banner:CreateTexture(nil, "ARTWORK", nil, 2)
iconInner:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 1, -1)
iconInner:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -1, 1)
iconInner:SetColorTexture(0, 0, 0, 1)
local bannerIcon = banner:CreateTexture(nil, "ARTWORK", nil, 3)
bannerIcon:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 2, -2)
bannerIcon:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -2, 2)
bannerIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the icon's own border

local heading = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
heading:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 12, -3)
heading:SetPoint("RIGHT", banner, "RIGHT", -EDGE * 0.5, 0)
heading:SetJustifyH("LEFT")
heading:SetWordWrap(false) -- long reasons get "..." instead of a second line

-- The name goes in its own line so a secret name can be shown as-is
-- (SetText accepts it; string joining might not).
local nameText = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
nameText:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMRIGHT", 12, 1)
nameText:SetPoint("RIGHT", banner, "RIGHT", -EDGE * 0.5, 0)
nameText:SetJustifyH("LEFT")
nameText:SetWordWrap(false)
do
    local font, _, flags = nameText:GetFont()
    if font then
        nameText:SetFont(font, 19, flags)
    end
    nameText:SetShadowOffset(1, -1)
    nameText:SetShadowColor(0, 0, 0, 1)
end

-- Turning glow.
local glowSpin = iconGlow:CreateAnimationGroup()
glowSpin:SetLooping("REPEAT")
do
    local a = glowSpin:CreateAnimation("Rotation")
    a:SetDegrees(-360)
    a:SetDuration(9)
end

-- A few twinkles around the icon, each on its own beat.
-- { x, y, size, seconds }
local TWINKLE_SPOTS = { { -6, 20, 14, 1.1 }, { 44, -18, 10, 1.6 }, { 40, 22, 8, 0.9 } }
local twinkles = {}
for i, spot in ipairs(TWINKLE_SPOTS) do
    local t = banner:CreateTexture(nil, "OVERLAY")
    t:SetTexture(STAR_TEXTURE)
    t:SetBlendMode("ADD")
    t:SetSize(spot[3], spot[3])
    t:SetPoint("CENTER", iconFrame, "LEFT", spot[1], spot[2])
    t:SetAlpha(0)
    local group = t:CreateAnimationGroup()
    group:SetLooping("REPEAT")
    local up = group:CreateAnimation("Alpha")
    up:SetFromAlpha(0)
    up:SetToAlpha(1)
    up:SetDuration(spot[4] / 2)
    up:SetStartDelay(i * 0.35)
    up:SetOrder(1)
    local down = group:CreateAnimation("Alpha")
    down:SetFromAlpha(1)
    down:SetToAlpha(0)
    down:SetDuration(spot[4] / 2)
    down:SetOrder(2)
    twinkles[i] = { tex = t, group = group }
end

-- Shine: a soft light band sweeping left to right, clipped to the banner.
local shineClip = CreateFrame("Frame", nil, banner)
shineClip:SetAllPoints()
shineClip:SetClipsChildren(true)
local shine = CreateFrame("Frame", nil, shineClip)
shine:SetSize(70, BANNER_H)
shine:SetPoint("RIGHT", shineClip, "LEFT", 0, 0)
do
    local l = shine:CreateTexture(nil, "OVERLAY")
    l:SetPoint("TOPLEFT")
    l:SetPoint("BOTTOMRIGHT", shine, "BOTTOM", 0, 0)
    l:SetBlendMode("ADD")
    Gradient(l, 1, 1, 1, 0, 0.22)
    local r = shine:CreateTexture(nil, "OVERLAY")
    r:SetPoint("TOPLEFT", shine, "TOP", 0, 0)
    r:SetPoint("BOTTOMRIGHT")
    r:SetBlendMode("ADD")
    Gradient(r, 1, 1, 1, 0.22, 0)
end
local shineSweep = shine:CreateAnimationGroup()
do
    local a = shineSweep:CreateAnimation("Translation")
    a:SetOffset(BANNER_W + 70, 0)
    a:SetDuration(0.9)
    a:SetStartDelay(0.15)
    a:SetSmoothing("IN_OUT")
end

-- Entrance: grow in slightly while fading in. Exit: fade out, then hide.
local enter = banner:CreateAnimationGroup()
do
    local a = enter:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    a:SetDuration(0.25)
    local s = enter:CreateAnimation("Scale")
    s:SetScaleFrom(0.92, 0.92)
    s:SetScaleTo(1, 1)
    s:SetDuration(0.25)
    s:SetSmoothing("OUT")
end

local function StopLoops()
    glowSpin:Stop()
    shineSweep:Stop()
    for _, t in ipairs(twinkles) do
        t.group:Stop()
    end
end

local leave = banner:CreateAnimationGroup()
do
    local a = leave:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    a:SetDuration(0.35)
    leave:SetScript("OnFinished", function()
        StopLoops()
        banner:Hide()
    end)
end

-- state: "ready" (in reach), "far" (walk closer), "low" (skill too low).
-- fresh = replay the entrance and shine.
local function ShowBanner(category, name, state, detail, fresh)
    local low = state == "low"
    local c = low and GREY or CategoryColor(category.key)
    local r, g, b = c[1], c[2], c[3]
    for _, l in ipairs(edgeLines) do
        l.strip.SetColor(r, g, b, l.alpha)
    end
    iconFrame:SetColorTexture(r, g, b, 1)
    iconGlow:SetVertexColor(r, g, b, 0.55)
    for _, t in ipairs(twinkles) do
        t.tex:SetVertexColor(r, g, b, 1)
    end

    local text = category.heading
    if low then
        text = text .. " (" .. (detail or "skill too low") .. ")"
    end
    heading:SetText(text:upper())
    heading:SetTextColor(r, g, b)
    bannerIcon:SetTexture(category.icon)
    bannerIcon:SetDesaturated(low)
    if IsSecret(name) then
        nameText:SetText(name) -- the game allows showing it, not reading it
    else
        nameText:SetText(name or "")
    end

    if leave:IsPlaying() then
        leave:Stop()
    end
    local wasShown = banner:IsShown()
    banner:Show()
    if fresh or not wasShown then
        enter:Stop()
        enter:Play()
        shineSweep:Stop()
        shineSweep:Play()
    end
    if not glowSpin:IsPlaying() then
        glowSpin:Play()
    end
    for _, t in ipairs(twinkles) do
        if not t.group:IsPlaying() then
            t.group:Play()
        end
    end
end

local function HideBanner()
    if banner:IsShown() and not leave:IsPlaying() then
        enter:Stop()
        leave:Play()
    end
end

-------------------------------------------------------------------------------
-- World marker
-- The game draws a name plate over the soft interact target. We attach our
-- marker to that plate, so it follows the object on screen.
--   "glints": a cloud of small stars that each fade in, turn and fade out at
--             their own pace, then reappear somewhere else.
--   "star":   one large spinning, pulsing star.
-------------------------------------------------------------------------------

local marker = CreateFrame("Frame", "LootHighlightMarker", UIParent)
marker:SetSize(64, 64)
marker:Hide()

-- Glint cloud ----------------------------------------------------------------
-- Each glint: wait a random moment, pop in while turning, drift upward,
-- fade out, then start again at a new random spot.

local glints = {}

local function SeedGlint(g)
    local size = db.markerSize
    -- Most glints land on a ring around the object (so it looks surrounded),
    -- a few inside it. The ring is an ellipse, a bit wider than tall.
    local angle = math.random() * 2 * math.pi
    local dist
    if math.random() < 0.75 then
        dist = 0.7 + math.random() * 0.3 -- outer ring
    else
        dist = math.random() * 0.7       -- inside
    end
    local x = math.cos(angle) * dist * size * 0.5
    local y = math.sin(angle) * dist * size * 0.4
    -- Small stars, with the odd bigger one.
    local s = 7 + math.random() * 9
    if math.random() < 0.15 then
        s = s + 8
    end
    g.tex:ClearAllPoints()
    g.tex:SetPoint("CENTER", marker, "CENTER", x, y)
    g.tex:SetSize(s, s)

    local wait = math.random() * 1.2
    local half = 0.3 + math.random() * 0.4
    g.fadeIn:SetStartDelay(wait)
    g.fadeIn:SetDuration(half)
    g.growIn:SetStartDelay(wait)
    g.growIn:SetDuration(half)
    g.fadeOut:SetStartDelay(wait + half)
    g.fadeOut:SetDuration(half)
    g.growOut:SetStartDelay(wait + half)
    g.growOut:SetDuration(half)
    g.turn:SetStartDelay(wait)
    g.turn:SetDuration(half * 2)
    g.drift:SetStartDelay(wait)
    g.drift:SetDuration(half * 2)
    g.drift:SetOffset((math.random() - 0.5) * 6, 6 + math.random() * 14)
end

for i = 1, MAX_GLINTS do
    local tex = marker:CreateTexture(nil, "ARTWORK")
    tex:SetTexture(STAR_TEXTURE)
    tex:SetBlendMode("ADD")
    tex:SetAlpha(0) -- only visible while its animation runs
    local group = tex:CreateAnimationGroup()
    local g = { tex = tex, group = group }

    -- All parts run side by side (order 1); start delays line them up.
    local function Part(kind)
        local a = group:CreateAnimation(kind)
        a:SetOrder(1)
        return a
    end
    g.fadeIn = Part("Alpha")
    g.fadeIn:SetFromAlpha(0)
    g.fadeIn:SetToAlpha(1)
    g.growIn = Part("Scale")
    g.growIn:SetScaleFrom(0.2, 0.2)
    g.growIn:SetScaleTo(1, 1)
    g.fadeOut = Part("Alpha")
    g.fadeOut:SetFromAlpha(1)
    g.fadeOut:SetToAlpha(0)
    g.growOut = Part("Scale")
    g.growOut:SetScaleFrom(1, 1)
    g.growOut:SetScaleTo(0.2, 0.2)
    g.turn = Part("Rotation")
    g.turn:SetDegrees(-60)
    g.drift = Part("Translation")

    group:SetScript("OnFinished", function()
        if g.active then
            SeedGlint(g)
            group:Play()
        end
    end)
    glints[i] = g
end

-- Single star ------------------------------------------------------------------

local star = marker:CreateTexture(nil, "ARTWORK")
star:SetPoint("CENTER")
star:SetTexture(STAR_TEXTURE)
star:SetBlendMode("ADD")

local core = marker:CreateTexture(nil, "OVERLAY")
core:SetPoint("CENTER")
core:SetTexture(STAR_TEXTURE)
core:SetBlendMode("ADD")

local spin = star:CreateAnimationGroup()
spin:SetLooping("REPEAT")
local turn = spin:CreateAnimation("Rotation")
turn:SetDegrees(-360)
turn:SetDuration(4)

local throb = marker:CreateAnimationGroup()
throb:SetLooping("BOUNCE")
local grow = throb:CreateAnimation("Scale")
grow:SetScaleFrom(0.8, 0.8)
grow:SetScaleTo(1.15, 1.15)
grow:SetDuration(0.5)
grow:SetSmoothing("IN_OUT")

-- Marker control ---------------------------------------------------------------

local function StopGlints()
    for _, g in ipairs(glints) do
        g.active = false
        g.group:Stop()
        g.tex:Hide()
    end
end

-- The game draws its interact icon (pickaxe, flower...) on the object's name
-- plate. We keep the game setting on (the plate, which the glints hang on,
-- depends on it) and just make that icon invisible when the player wants.
local hiddenIcon
local function FindIconFrame(plate)
    local uf = type(plate) == "table" and plate.UnitFrame
    for _, f in ipairs({
        type(uf) == "table" and uf.SoftTargetFrame or nil,
        type(plate) == "table" and plate.SoftTargetFrame or nil,
    }) do
        if type(f) == "table" and f.SetAlpha then
            return f
        end
    end
    return nil
end
ns.FindIconFrame = FindIconFrame

-- Frames we made invisible; they get their alpha back when we let go.
local hiddenFrames = {}

local function Unhide(f)
    if hiddenFrames[f] then
        hiddenFrames[f] = nil
        f.lhHide = false
        pcall(f.SetAlpha, f, 1)
    end
end

local function KeepHidden(f)
    if type(f) ~= "table" or not f.SetAlpha then
        return
    end
    -- Keep it hidden even if the game sets its alpha again.
    if not f.lhHooked and hooksecurefunc then
        f.lhHooked = true
        hooksecurefunc(f, "SetAlpha", function(self, value)
            if self.lhHide and value ~= 0 then
                self:SetAlpha(0)
            end
        end)
    end
    f.lhHide = true
    hiddenFrames[f] = true
    f:SetAlpha(0)
end

local function RestoreGameIcon()
    for f in pairs(hiddenFrames) do
        Unhide(f)
    end
end

-- body = true on a corpse: its plate would show an empty health bar, so the
-- whole plate body goes invisible and only our glints stay.
local function ApplyGameIcon(plate, body)
    local want = {}
    local uf = type(plate) == "table" and plate.UnitFrame
    if body and type(uf) == "table" and uf.SetAlpha then
        want[uf] = true
    end
    local icon = FindIconFrame(plate)
    if icon and not db.gameIcon then
        want[icon] = true
    end
    for f in pairs(hiddenFrames) do
        if not want[f] then
            Unhide(f)
        end
    end
    for f in pairs(want) do
        KeepHidden(f)
    end
end

local function HideMarker()
    RestoreGameIcon()
    StopGlints()
    spin:Stop()
    throb:Stop()
    marker:Hide()
    marker:SetParent(UIParent)
    marker:ClearAllPoints()
end

-- Returns true when the marker could be placed on the object.
local function ShowMarker(state, key, body)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit
        and C_NamePlate.GetNamePlateForUnit("softinteract")
    if not plate or (plate.IsForbidden and plate:IsForbidden()) then
        HideMarker()
        return false
    end

    local c = CategoryColor(key)
    local r, g, b = c[1], c[2], c[3]
    local a = 1
    if state == "low" then
        r, g, b = 0.6, 0.6, 0.6 -- grey: the character cannot gather this yet
    elseif state == "far" then
        a = 0.45                -- dim: walk closer
    end

    ApplyGameIcon(plate, body)
    marker:SetParent(plate)
    if marker.SetIgnoreParentAlpha then
        marker:SetIgnoreParentAlpha(true) -- the plate may fade; our glints set their own
    end
    marker:ClearAllPoints()
    marker:SetPoint("CENTER", plate, "CENTER", 0, db.markerOffset)
    marker:SetFrameLevel(plate:GetFrameLevel() + 10)
    local wasShown = marker:IsShown()
    marker:Show()

    if db.style == "star" then
        StopGlints()
        local size = db.markerSize
        star:SetSize(size, size)
        star:SetVertexColor(r, g, b, a)
        star:Show()
        core:SetSize(size * 0.45, size * 0.45)
        core:SetVertexColor(1, 1, 1, a * 0.9)
        core:Show()
        if not spin:IsPlaying() then spin:Play() end
        if not throb:IsPlaying() then throb:Play() end
    else
        spin:Stop()
        throb:Stop()
        star:Hide()
        core:Hide()
        local count = math.max(1, math.min(MAX_GLINTS, db.glints))
        for i, gl in ipairs(glints) do
            gl.tex:SetVertexColor(r, g, b, a)
            if i <= count then
                if not gl.active or not wasShown then
                    gl.active = true
                    gl.tex:Show()
                    SeedGlint(gl)
                    gl.group:Stop()
                    gl.group:Play()
                end
            else
                gl.active = false
                gl.group:Stop()
                gl.tex:Hide()
            end
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- What is the soft interact target?
-------------------------------------------------------------------------------

-- true / false from a game function, or nil if it fails or will not say.
local function SafeFlag(fn, ...)
    if not fn then
        return nil
    end
    local ok, v = pcall(fn, ...)
    if not ok or IsSecret(v) then
        return nil
    end
    if v == true or v == false then
        return v
    end
    return v and true or false
end
ns.SafeFlag = SafeFlag

-- A living player or NPC (not an object, not a corpse)?
local function IsLivingUnit()
    return SafeFlag(UnitExists, "softinteract") == true
        and SafeFlag(UnitIsDead, "softinteract") == false
        and SafeFlag(UnitIsGameObject, "softinteract") ~= true
end

-- The game picks a different mouse cursor for each kind of object. Blizzard's
-- SetUnitCursorTexture puts that cursor on a texture; we read its name back.
local probe = UIParent:CreateTexture(nil, "BACKGROUND")
probe:Hide()

-- Returns a lower-case description of the cursor, or nil.
local function CursorKey()
    if not SetUnitCursorTexture then
        return nil
    end
    local ok, has = pcall(SetUnitCursorTexture, probe, "softinteract")
    if not ok or not has then
        return nil
    end
    local atlas = probe.GetAtlas and probe:GetAtlas()
    local tex = probe:GetTexture()
    local key = atlas or tex
    if key == nil or IsSecret(key) then
        return nil
    end
    return tostring(key):lower()
end

-- Cursor name fragments, checked in order.
local CURSOR_RULES = {
    { "herb", "herbs" },
    { "mine", "ore" },
    { "mining", "ore" },
    { "skin", "skinning" },
    { "loot", "loot" },
    { "pickup", "loot" },
    { "lock", "loot" },
    { "quest", "loot" },
    { "mail", "other" },
    { "interact", "other" },
    { "speak", "other" },
    { "inspect", "other" },
    { "taxi", "other" },
    { "repair", "other" },
    { "innkeeper", "other" },
    { "trainer", "other" },
    { "buy", "other" },
    { "directions", "other" },
}

-- Returns categoryKey, unable (skill too low) for a cursor key, or nil.
local function CategoryFromCursor(key)
    if not key then
        return nil
    end
    for _, rule in ipairs(CURSOR_RULES) do
        if key:find(rule[1], 1, true) then
            return rule[2], key:find("unable", 1, true) ~= nil
        end
    end
    return nil
end

-- Returns categoryKey, unable, cursorKey for the current soft interact target.
local function Classify(guid)
    local cursorKey = CursorKey()
    local fromCursor, unable = CategoryFromCursor(cursorKey)

    local kind
    if IsSecret(guid) then
        -- No ID to read: ask the game what kind of thing it is instead.
        local object = SafeFlag(UnitIsGameObject, "softinteract")
        local dead = SafeFlag(UnitIsDead, "softinteract")
        if object == true then
            kind = "GameObject"
        elseif object == false and dead ~= nil then
            kind = "Creature"
        else
            return fromCursor or "loot", unable, cursorKey -- nothing known
        end
    else
        kind = strsplit("-", guid)
    end

    if kind == "GameObject" then
        -- Unknown cursor: count it as something to pick up, so nothing that
        -- matters goes missing. /lh what shows the cursor so it can be added.
        if fromCursor == nil or fromCursor == "skinning" or fromCursor == "corpses" then
            return "loot", unable, cursorKey
        end
        return fromCursor, unable, cursorKey
    end

    if (kind == "Creature" or kind == "Vehicle") and SafeFlag(UnitIsDead, "softinteract") == true then
        -- CanLootUnit: is there loot, and is it ours to take (not another
        -- player's kill)?
        local hasLoot, canLoot = true, true
        if CanLootUnit then
            local ok, h, c = pcall(CanLootUnit, guid)
            if ok then
                hasLoot, canLoot = h, c
            end
        end
        if IsSecret(hasLoot) or IsSecret(canLoot) then
            return "corpses", false, cursorKey
        end
        if hasLoot and canLoot ~= false then
            return "corpses", false, cursorKey
        end
        if fromCursor == "skinning" then
            return "skinning", unable, cursorKey
        end
    end
    return nil, false, cursorKey -- living NPCs, players, looted corpses
end

local function IsIgnored(name)
    if not name or IsSecret(name) then
        return false
    end
    return db.ignore[name] == true
end

-------------------------------------------------------------------------------
-- Update
-------------------------------------------------------------------------------

-- Works out "ready" / "far" / "low" (+ a short reason) for the target.
-- inRange: the game's own "can you reach it" answer (true/false/nil).
local function TargetState(category, name, unable, inRange)
    if inRange == false then
        return "far"
    end
    if not unable then
        return "ready"
    end
    local info = CATEGORY_BY_KEY[category]
    if inRange == true then
        -- In reach but the game says no: skill too low, or locked.
        if info.skill then
            local have = SkillRank(info.skill)
            if have == false then
                return "low", "needs " .. info.profession
            end
            local need = NodeRequirement(category, name)
            if have and need and have < need then
                return "low", string.format("need %s %d, you have %d", info.profession, need, have)
            end
            if have and need then
                return "low", "can't gather it right now" -- skill is fine; busy or locked
            end
            return "low", "skill too low"
        end
        return "low", "can't open it yet"
    end
    -- The game would not say if it is in reach. The "can't" cursor means
    -- either "too far" or "skill too low"; the character's skill decides.
    if info.skill then
        local have = SkillRank(info.skill)
        if have == nil then
            return "far" -- the game would not say; do not blame the skill
        elseif have == false then
            return "low", "needs " .. info.profession
        end
        local need = NodeRequirement(category, name)
        if need and have < need then
            return "low", string.format("need %s %d, you have %d", info.profession, need, have)
        end
    end
    return "far"
end
ns.TargetState = TargetState
ns.Sanitize = function() Sanitize() end

-- Objects already announced: coming back to the same one within 5 minutes
-- (for example between loots on one vein) does not pop the banner again.
local announced = {}
local QUIET_SECONDS = 300
-- The game may hide the object's ID, or hand out a new one after each loot.
-- So we also remember the last highlighted thing by name and by where the
-- player stood: same name, player has not walked away, seen moments ago =
-- the same object.
local SAME_SPOT_YARDS = 8
local SAME_SPOT_SECONDS = 30
local NO_SPOT_SECONDS = 10 -- when the game will not tell us where we are
local lastSeenName, lastSeenTime, lastSpot

-- Where the player stands, in yards: map id, x, y. nil if the game won't say.
local function PlayerSpot()
    local ok, map, x, y = pcall(function()
        if UnitPosition then
            local py, px, _, inst = UnitPosition("player")
            if py and px and not IsSecret(py) and not IsSecret(px) then
                return inst or 0, px, py
            end
        end
        if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition
            and C_Map.GetWorldPosFromMapPos then
            local m = C_Map.GetBestMapForUnit("player")
            local pos = m and C_Map.GetPlayerMapPosition(m, "player")
            if pos then
                local cont, world = C_Map.GetWorldPosFromMapPos(m, pos)
                if cont and world then
                    local wx, wy = world:GetXY()
                    if wx and wy and not IsSecret(wx) and not IsSecret(wy) then
                        return cont, wx, wy
                    end
                end
            end
        end
    end)
    if ok and map and type(x) == "number" and type(y) == "number" then
        return { map = map, x = x, y = y }
    end
    return nil
end
ns.PlayerSpot = PlayerSpot

-- Safe self-cast ------------------------------------------------------------
-- With soft interact on, a spell cast without a target can land on the
-- player or NPC soft interact picked next to you. So while it points at a
-- living unit (and during combat) it is switched off, and on again once you
-- have walked a few steps (or after a few seconds if the game won't say
-- where you are). Players who had the interact key on before us keep the
-- game's own behavior.
local RESUME_YARDS = 5
local RESUME_SECONDS = 3
local pausedAt, pausedSpot

local function SelfCastGuard()
    local own = db.savedCVars and db.savedCVars.SoftTargetInteract
    return own == nil or own == false or tostring(own) == "0"
end

local function PauseInteract(reason)
    if interactPaused then
        if reason == "combat" then
            interactPaused = "combat"
        end
        return
    end
    if not db.enabled or not SelfCastGuard() or InCombatLockdown() then
        return
    end
    interactPaused = reason
    pausedAt = GetTime()
    pausedSpot = PlayerSpot()
    SetCVarSafe("SoftTargetInteract", "0")
end

local function ResumeInteract()
    if not interactPaused or InCombatLockdown() then
        return
    end
    interactPaused = nil
    if db.enabled then
        SetCVarSafe("SoftTargetInteract", "3")
    end
end

local function ReadyToResume()
    if interactPaused ~= "unit" then
        return false
    end
    local spot = PlayerSpot()
    if spot and pausedSpot and spot.map == pausedSpot.map then
        local dx, dy = spot.x - pausedSpot.x, spot.y - pausedSpot.y
        return dx * dx + dy * dy >= RESUME_YARDS * RESUME_YARDS
    end
    return GetTime() - pausedAt >= RESUME_SECONDS
end
ns.InteractPaused = function() return interactPaused end

-- Is this (by name) the thing we highlighted a moment ago, from about here?
local function SameAsLastSeen(name, spot, now)
    if not lastSeenName or name == nil or IsSecret(name) or name ~= lastSeenName then
        return false
    end
    local age = now - lastSeenTime
    if spot and lastSpot then
        if spot.map ~= lastSpot.map then
            return false
        end
        local dx, dy = spot.x - lastSpot.x, spot.y - lastSpot.y
        return age < SAME_SPOT_SECONDS and (dx * dx + dy * dy) < SAME_SPOT_YARDS * SAME_SPOT_YARDS
    end
    return age < NO_SPOT_SECONDS
end
local lastState, lastDetail
local pendingState, pendingSince = nil, 0
local STATE_HOLD = 0.2
local bannerQuiet = false
local hasTarget = false   -- something highlighted right now
local targetChanges = 0   -- bumped every time the game picks a new target
local seenChanges = -1    -- value of targetChanges at the last update
local testUntil = 0       -- while a test banner shows, leave the banner alone

local function Update()
    if not db then
        return
    end
    if not db.enabled then
        hasTarget = false
        HideBanner()
        HideMarker()
        SetObjectPlate(false)
        return
    end
    local testing = GetTime() < testUntil

    local ok, category, unable, name, guid = pcall(function()
        local g = UnitGUID("softinteract")
        if not g then
            return nil
        end
        local c, u = Classify(g)
        if not c or not CategoryOn(c) then
            return nil
        end
        return c, u, UnitName("softinteract"), g
    end)

    if not ok or not category or IsIgnored(name) then
        lastGUID = nil
        lastState = nil
        hasTarget = false
        if not testing then
            HideBanner()
        end
        HideMarker()
        SetObjectPlate(false) -- NPCs and anything we skip: no plate
        if ok and not category and IsLivingUnit() then
            PauseInteract("unit")
        end
        return
    end
    SetObjectPlate(db.marker or not db.gameIcon)

    local inRange = SafeFlag(UnitIsInInteractRange, "softinteract")
    local state, detail = TargetState(category, name, unable, inRange)
    local now = GetTime()
    local secret = IsSecret(guid)
    local spot = PlayerSpot()
    local sameAsLast = SameAsLastSeen(name, spot, now)
    -- "Still the same target": no new target since the last update, the very
    -- same ID again, or (ID hidden) same name from the same spot.
    local continuing = hasTarget and (seenChanges == targetChanges
        or (not secret and guid == lastGUID) or (secret and sameAsLast))
    -- "Seen it already": same ID within 5 minutes, or the same thing coming
    -- back after a loot (same name, player did not walk away).
    local recent = (not secret and announced[guid] and now - announced[guid] < QUIET_SECONDS)
        or sameAsLast
    -- At the edge of reach the answer can flip back and forth; a new state
    -- for the same target shows only once it held for a moment.
    if continuing and lastState and state ~= lastState then
        if pendingState ~= state then
            pendingState, pendingSince = state, now
        end
        if now - pendingSince < STATE_HOLD then
            state, detail = lastState, lastDetail
        else
            pendingState = nil
        end
    else
        pendingState = nil
    end
    local reachedIt = continuing and lastState ~= "ready" and state == "ready"
    lastGUID = (not secret) and guid or nil -- never keep a hidden value
    lastState, lastDetail = state, detail
    hasTarget = true
    seenChanges = targetChanges
    if name ~= nil and not IsSecret(name) then
        lastSeenName, lastSeenTime, lastSpot = name, now, spot
    else
        lastSeenName, lastSeenTime, lastSpot = nil, nil, nil
    end

    if not continuing then
        bannerQuiet = recent and true or false
        if not secret then
            announced[guid] = now
            -- Forget old entries now and then.
            for k, t in pairs(announced) do
                if now - t > QUIET_SECONDS then
                    announced[k] = nil
                end
            end
        end
    end

    local info = CATEGORY_BY_KEY[category]

    local body = category == "corpses" or category == "skinning"
    if db.marker then
        ShowMarker(state, category, body)
    else
        HideMarker()
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit
            and C_NamePlate.GetNamePlateForUnit("softinteract")
        if plate and not (plate.IsForbidden and plate:IsForbidden()) then
            ApplyGameIcon(plate, body)
        end
    end

    if testing then
        -- a test banner is showing; leave it for its 3 seconds
    elseif db.banner and not bannerQuiet then
        -- New find: full entrance. Walking into reach: shine again.
        ShowBanner(info, name, state, detail, (not continuing) or reachedIt)
    else
        HideBanner()
    end

    if not continuing and not recent and state ~= "low" and db.sound and now - lastSoundTime > 2 then
        lastSoundTime = now
        if PlaySound and SOUNDKIT and SOUNDKIT.MAP_PING then
            PlaySound(SOUNDKIT.MAP_PING, "SFX")
        end
    end
end
ns.Update = Update
-- For tests and /lh what: is something highlighted, and its state.
function ns.CurrentState()
    return hasTarget, lastState
end

-------------------------------------------------------------------------------
-- Actions used by the settings page and slash commands
-------------------------------------------------------------------------------

function ns.SetEnabled(on)
    db.enabled = on and true or false
    if db.enabled then
        ApplyCVars()
    else
        RestoreCVars()
    end
    Update()
end

local SAMPLE_NAMES = {
    herbs = "Peacebloom", ore = "Copper Vein", skinning = "Young Wolf",
    loot = "Battered Chest", corpses = "Young Wolf", other = "Wooden Chair",
}
local testToken = 0

-- Shows the banner for a type (herbs if none) for 3 seconds.
function ns.TestBanner(key)
    local category = CATEGORY_BY_KEY[key] or CATEGORY_BY_KEY.herbs
    ShowBanner(category, SAMPLE_NAMES[category.key], "ready", nil, true)
    testUntil = GetTime() + 3
    testToken = testToken + 1
    local mine = testToken
    C_Timer.After(3, function()
        if mine == testToken then -- a newer preview restarts the 3 seconds
            testUntil = 0
            local ok, err = pcall(Update)
            if not ok then
                ns.Report(err)
            end
        end
    end)
end

-- Adds the current target's name to the ignore list. Returns the name or nil.
function ns.IgnoreCurrent()
    local name = UnitName("softinteract")
    if not name or IsSecret(name) then
        return nil
    end
    db.ignore[name] = true
    Update()
    return name
end

function ns.IgnoredNames()
    local names = {}
    for name in pairs(db.ignore) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Account-synced game settings can arrive after login and undo ours.
events:RegisterEvent("VARIABLES_LOADED")
-- Combat: close the object plate before the game locks settings.
events:RegisterEvent("PLAYER_REGEN_DISABLED")
-- The object's plate can appear a moment after the target changes.
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
-- Learning or dropping a profession changes what "auto" means.
events:RegisterEvent("SKILL_LINES_CHANGED")

local ticker = CreateFrame("Frame")
local tickWait = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    tickWait = tickWait + elapsed
    if tickWait < 0.25 then
        return
    end
    tickWait = 0
    if db and db.enabled and interactPaused == "unit" then
        local ok, err = pcall(function()
            if ReadyToResume() then
                ResumeInteract()
                Update()
            end
        end)
        if not ok then
            ns.Report(err)
        end
    end
    if hasTarget and db and db.enabled then
        local ok, err = pcall(Update)
        if not ok then
            ns.Report(err) -- said once, not four times a second
        end
    end
end)

-- Says an error once in chat instead of a game error popup every time.
local function Report(err)
    if not ns.reportedError then
        ns.reportedError = true
        Print("something went wrong: " .. tostring(err))
    end
end
ns.Report = Report

local function OnEvent(event, arg1)
    if event == "PLAYER_SOFT_INTERACT_CHANGED" then
        targetChanges = targetChanges + 1
    end
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            LootHighlightDB = MergeDefaults(DEFAULTS, LootHighlightDB or {})
            db = LootHighlightDB
            ns.db = db
            if not db.v2 then
                db.v2 = true
                if db.range < 30 then
                    db.range = 30 -- ask the game for more; it caps it anyway
                end
            end
            -- Version 2.3 moved the glints down onto the object and made the
            -- cloud bigger. Only replace values the player never changed.
            if not db.v23 then
                db.v23 = true
                if db.markerOffset == -30 then db.markerOffset = -110 end
                if db.markerSize == 64 then db.markerSize = 110 end
                if db.glints == 12 then db.glints = 18 end
            end
            -- 2.9.3: the banner is on by default; switch it back on once for
            -- saves that had it off. It can still be turned off afterwards.
            if not db.v293 then
                db.v293 = true
                db.banner = true
            end
            Sanitize() -- also turns version 1's true/false into on/off
        end
    elseif not db then
        return -- our settings failed to load; nothing else can work
    elseif event == "PLAYER_LOGIN" then
        if db.enabled then
            ApplyCVars()
        end
        if ns.BuildOptions then
            ns.BuildOptions()
        end
        C_Timer.After(5, function()
            local ok, err = pcall(function()
                if db.enabled and not InCombatLockdown() then
                    ApplyCVars() -- late account settings
                end
                ns.WarnOtherSparkleAddons()
            end)
            if not ok then
                Report(err)
            end
        end)
    elseif event == "VARIABLES_LOADED" or event == "PLAYER_ENTERING_WORLD" then
        if db.enabled and not InCombatLockdown() then
            ApplyCVars()
        end
        Update()
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Left open, every corpse with loot would keep an empty health bar
        -- until the fight ends. The game still allows this right now.
        hasTarget = false
        HideMarker()
        SetObjectPlate(false, true)
        PauseInteract("combat")
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingCVarAction == "apply" then
            pendingCVarAction = nil
            ApplyCVars()
        elseif pendingCVarAction == "restore" then
            pendingCVarAction = nil
            RestoreCVars()
        end
        if interactPaused == "combat" then
            ResumeInteract()
        end
        -- Settings that could not change during combat catch up now.
        Update()
        if ns.openOptionsAfterCombat and ns.OpenOptions then
            ns.openOptionsAfterCombat = false
            ns.OpenOptions()
        end
    else
        Update()
    end
end

events:SetScript("OnEvent", function(_, event, arg1)
    local ok, err = pcall(OnEvent, event, arg1)
    if not ok then
        Report(err)
    end
end)

-- Other addons that drive the same soft interact settings fight with us.
local OTHER_SPARKLE_ADDONS = {
    { folder = "ForeverLootSparkles_Coloring", title = "Forever Loot Sparkles - Herbs & Ores" },
    { folder = "Sparkles_Forever", title = "Sparkles" },
    { folder = "Lueur", title = "Lueur" },
    { folder = "ForeverLootSparkles", title = "Forever Loot Sparkles 1.x", before = 2 },
}

function ns.WarnOtherSparkleAddons()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if not loaded then
        return
    end
    local found = {}
    for _, a in ipairs(OTHER_SPARKLE_ADDONS) do
        local ok, on = pcall(loaded, a.folder)
        if ok and on then
            local clash = true
            if a.before and meta then
                -- only old versions still change the soft interact settings
                local okV, v = pcall(meta, a.folder, "Version")
                local major = okV and type(v) == "string" and tonumber(v:match("^(%d+)"))
                clash = major ~= nil and major < a.before
            end
            if clash then
                found[#found + 1] = a.title
            end
        end
    end
    if #found > 0 then
        Print(table.concat(found, " and ") .. (#found == 1 and " also changes" or " also change")
            .. " the game's interact settings. Keep only one sparkle addon on, or they will undo each other.")
    end
    return found
end

-------------------------------------------------------------------------------
-- Slash commands (the settings page covers everything; these are shortcuts)
-------------------------------------------------------------------------------

local function Help()
    Print("type /lh to open the settings. Shortcuts:")
    print("  /lh on | off  - turn the addon on or off")
    print("  /lh ignore    - stop alerting for the thing you are standing at")
    print("  /lh test      - show the banner for 3 seconds")
    print("  /lh what      - show what the game says the nearest thing is")
    print("  /lh height N  - move the glints up or down (e.g. -120)")
    print("  /lh size N    - make the glint cloud wider or smaller")
end

SLASH_LOOTHIGHLIGHT1 = "/lh"
SLASH_LOOTHIGHLIGHT2 = "/loothighlight"
SlashCmdList.LOOTHIGHLIGHT = function(input)
    local cmd = strtrim(input or ""):match("^(%S*)")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "options" or cmd == "config" then
        if ns.OpenOptions and ns.OpenOptions() then
            return
        end
        Help()
    elseif cmd == "on" then
        ns.SetEnabled(true)
        Print("on")
    elseif cmd == "off" then
        ns.SetEnabled(false)
        Print("off, your own interact settings are restored")
    elseif cmd == "ignore" then
        local name = ns.IgnoreCurrent()
        if name then
            Print("ignoring " .. name)
        else
            Print("walk up to the thing first, so its name shows on the banner")
        end
    elseif cmd == "test" then
        ns.TestBanner()
    elseif cmd == "height" or cmd == "size" then
        local n = tonumber(input:match("(%-?%d+)%s*$"))
        if not n then
            Print("e.g. /lh height -120 (more negative = lower) or /lh size 140")
            return
        end
        if cmd == "height" then
            db.markerOffset = math.max(-300, math.min(60, math.floor(n)))
            Print("glint height " .. db.markerOffset)
        else
            db.markerSize = math.max(24, math.min(300, math.floor(n)))
            Print("glint cloud size " .. db.markerSize)
        end
        HideMarker()
        Update()
        if ns.RefreshOptions then
            ns.RefreshOptions()
        end
    elseif cmd == "what" then
        local ok, err = pcall(ns.ShowWhat)
        if not ok then
            Print("could not read the target: " .. tostring(err))
        end
    else
        Help()
    end
end

-- /lh what: everything we know about the current target, for bug reports.
function ns.ShowWhat()
    do
        local guid = UnitGUID("softinteract")
        if not guid then
            Print("nothing nearby the game would interact with")
            return
        end
        local function Show(v)
            if IsSecret(v) then
                return "hidden"
            end
            return tostring(v)
        end
        local category, unable, cursorKey = Classify(guid)
        local state, detail = "?", nil
        if category then
            local n = UnitName("softinteract")
            state, detail = TargetState(category, (not IsSecret(n)) and n or nil, unable)
        end
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit("softinteract")
        local spot = PlayerSpot()
        Print(string.format("id: %s | position: %s",
            IsSecret(guid) and "hidden" or tostring(guid), spot and "known" or "unknown"))
        Print(string.format("name: %s | type: %s | cursor: %s | category: %s%s | range: %s | game icon: %s",
            Show(UnitName("softinteract")),
            IsSecret(guid) and "hidden" or tostring((strsplit("-", guid))),
            tostring(cursorKey),
            tostring(category),
            " | " .. state .. (detail and (" (" .. detail .. ")") or ""),
            tostring(ns.GameRange()),
            (plate and FindIconFrame(plate)) and "found" or "not found"))
    end
end
