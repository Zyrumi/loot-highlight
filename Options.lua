-- Loot Highlight: settings page (Esc > Options > AddOns > Loot Highlight)
-- Built from plain frames so it does not depend on Blizzard's changing
-- settings templates. Everything applies at once.

local ADDON_NAME, ns = ...

local refreshers = {} -- functions that pull current values into the widgets

local function RefreshAll()
    for _, fn in ipairs(refreshers) do
        local ok = pcall(fn)
        if not ok then
            -- one broken widget should not stop the others from updating
        end
    end
end
ns.RefreshOptions = function()
    if ns.optionsPanel and ns.optionsPanel:IsShown() then
        RefreshAll()
    end
end

local function Changed()
    ns.Update()
    RefreshAll()
end

local function AddTooltip(frame, title, text)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if text then
            GameTooltip:AddLine(text, nil, nil, nil, true)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-------------------------------------------------------------------------------
-- Widgets
-------------------------------------------------------------------------------

local function Header(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetSize(290, 1)
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -4)
    return fs
end

local function Note(parent, text, x, y, width)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(width or 290)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

local function Check(parent, label, tip, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", x, y)
    -- Hide the template's own label (if any); we draw our own.
    for _, key in ipairs({ "Text", "text" }) do
        if type(cb[key]) == "table" and cb[key].SetText then
            cb[key]:SetText("")
        end
    end
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        Changed()
    end)
    AddTooltip(cb, label, tip)
    refreshers[#refreshers + 1] = function()
        cb:SetChecked(get() and true or false)
    end
    return cb
end

-- A button that steps through a list of choices; shows the current one.
local function Choice(parent, label, tip, x, y, values, names, get, set, indent)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x + 4 + (indent or 0), y - 6)
    fs:SetText(label)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(96, 22)
    b:SetPoint("TOPLEFT", x + 196, y - 2)
    b:SetScript("OnClick", function()
        local current = get()
        local nextIndex = 1
        for i, v in ipairs(values) do
            if v == current then
                nextIndex = i % #values + 1
            end
        end
        set(values[nextIndex])
        Changed()
    end)
    AddTooltip(b, label, tip)
    refreshers[#refreshers + 1] = function()
        local current = get()
        for i, v in ipairs(values) do
            if v == current then
                b:SetText(names[i])
            end
        end
    end
    return b
end

-- Plain slider built from game textures (no template needed).
local function Slider(parent, label, tip, x, y, minV, maxV, step, get, set, unit)
    local title = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    title:SetPoint("TOPLEFT", x + 4, y)
    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetOrientation("HORIZONTAL")
    s:SetSize(280, 17)
    s:SetPoint("TOPLEFT", x + 4, y - 18)
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)

    local loading = false
    local function ShowValue(v)
        title:SetText(label .. ": " .. v .. (unit or ""))
    end
    s:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        ShowValue(v)
        if not loading and v ~= get() then
            set(v)
            Changed()
        end
    end)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(self:GetValue() + delta * step)
    end)
    AddTooltip(s, label, tip)
    refreshers[#refreshers + 1] = function()
        loading = true
        s:SetValue(get())
        ShowValue(get())
        loading = false
    end
    return s
end

local function Button(parent, text, tip, x, y, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 140, 22)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", function()
        onClick()
        Changed()
    end)
    AddTooltip(b, text, tip)
    return b
end

-- Colors offered when the game's color picker is not available.
local FALLBACK_COLORS = {
    { 1.00, 0.85, 0.30 }, { 0.55, 1.00, 0.55 }, { 1.00, 0.65, 0.35 }, { 1.00, 0.96, 0.72 },
    { 1.00, 1.00, 1.00 }, { 0.30, 0.90, 1.00 }, { 1.00, 0.45, 0.85 }, { 0.70, 0.45, 1.00 },
}

-- Opens the game's color picker for one type. Changes show live; Cancel
-- puts the old color back.
local function PickColor(key)
    local db = ns.db
    local c = ns.CategoryColor(key)
    local old = { c[1], c[2], c[3] }
    local function Apply(r, g, b)
        db.colors[key] = { r, g, b }
        Changed()
    end
    if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = old[1], g = old[2], b = old[3],
            hasOpacity = false,
            swatchFunc = function()
                local r, g, b
                if ColorPickerFrame.GetColorRGB then
                    r, g, b = ColorPickerFrame:GetColorRGB()
                elseif ColorPickerFrame.Content and ColorPickerFrame.Content.ColorPicker then
                    r, g, b = ColorPickerFrame.Content.ColorPicker:GetColorRGB()
                end
                if r and g and b then
                    Apply(r, g, b)
                end
            end,
            cancelFunc = function()
                Apply(old[1], old[2], old[3])
            end,
        })
        return
    end
    -- No picker: step to the next preset color.
    local nextIndex = 1
    for i, f in ipairs(FALLBACK_COLORS) do
        if math.abs(f[1] - old[1]) < 0.01 and math.abs(f[2] - old[2]) < 0.01 and math.abs(f[3] - old[3]) < 0.01 then
            nextIndex = i % #FALLBACK_COLORS + 1
        end
    end
    local f = FALLBACK_COLORS[nextIndex]
    Apply(f[1], f[2], f[3])
end

-- Small color square for one type. Clicking it opens the color picker and
-- shows a preview banner in that color.
local function ColorSwatch(parent, key, label, x, y)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)
    b:SetPoint("TOPLEFT", x + 4, y - 3)
    local edge = b:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints()
    edge:SetColorTexture(0.85, 0.85, 0.85, 1)
    local fill = b:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)
    b:SetScript("OnClick", function()
        ns.TestBanner(key)
        PickColor(key)
    end)
    AddTooltip(b, label .. " color", "Click to pick the color of the glints and the banner for this type.")
    refreshers[#refreshers + 1] = function()
        local c = ns.CategoryColor(key)
        fill:SetColorTexture(c[1], c[2], c[3], 1)
    end
    return b
end

-------------------------------------------------------------------------------
-- The page
-------------------------------------------------------------------------------

function ns.BuildOptions()
    if ns.optionsPanel then
        return
    end
    local db = ns.db
    local panel = CreateFrame("Frame", "LootHighlightOptions", UIParent)
    panel:Hide()
    ns.optionsPanel = panel

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Loot Highlight")
    Note(panel, "Points out the nearest thing you can gather or loot. Changes apply at once.", 16, -48, 600)

    -----------------------------------------------------------------------
    -- Left column: what to highlight, detection
    -----------------------------------------------------------------------
    local L, y = 16, -80
    Header(panel, "What to highlight", L, y)
    y = y - 30

    local choiceValues = { "auto", "on", "off" }
    local choiceNames = { "Auto", "On", "Off" }
    local onOffValues = { "on", "off" }
    local onOffNames = { "On", "Off" }

    for _, cat in ipairs(ns.CATEGORIES) do
        local key = cat.key
        local tip
        local values, names = onOffValues, onOffNames
        if cat.skill then
            values, names = choiceValues, choiceNames
            tip = "Auto: only when this character has the profession. On or Off: always."
        elseif key == "other" then
            tip = "Chairs, doors, mailboxes, braziers and similar things the game lets you click."
        elseif key == "loot" then
            tip = "Chests, quest objects and anything else you pick up."
        end
        ColorSwatch(panel, key, cat.label, L, y)
        Choice(panel, cat.label, tip, L, y, values, names,
            function() return db.show[key] end,
            function(v) db.show[key] = v end, 26)
        y = y - 28
    end

    y = y - 12
    Header(panel, "Detection", L, y)
    y = y - 30
    Check(panel, "Addon on", "Turning it off also gives back your own interact settings.", L, y,
        function() return db.enabled end,
        function(v) ns.SetEnabled(v) end)
    y = y - 34
    Slider(panel, "Range asked for", "How far away things are picked up. The game has its own maximum and will not go past it.",
        L, y, 5, 60, 1,
        function() return db.range end,
        function(v)
            db.range = v
            if db.enabled then ns.ApplyCVars() end
        end, " yd")
    y = y - 44
    local rangeNote = Note(panel, "", L + 4, y)
    refreshers[#refreshers + 1] = function()
        rangeNote:SetText("The game stops picking things at about 15 yards, whatever is set here.")
    end
    y = y - 22

    local ignoreNote = Note(panel, "", L + 4, y)
    refreshers[#refreshers + 1] = function()
        local names = ns.IgnoredNames()
        ignoreNote:SetText("Ignored: " .. (#names == 0 and "nothing" or table.concat(names, ", ")))
    end
    y = y - 34
    Button(panel, "Ignore nearest thing", "Stand at something you never want alerts for (a mailbox, a chair) and click this.",
        L + 4, y, 150, function()
            local name = ns.IgnoreCurrent()
            ns.Print(name and ("ignoring " .. name) or "nothing nearby to ignore")
        end)
    Button(panel, "Clear ignore list", nil, L + 160, y, 130, function()
        wipe(db.ignore)
    end)

    -----------------------------------------------------------------------
    -- Right column: how it looks
    -----------------------------------------------------------------------
    local R
    R, y = 340, -80
    Header(panel, "How it looks", R, y)
    y = y - 30
    Check(panel, "Glints on the object", "Twinkling stars drawn over the thing itself.", R, y,
        function() return db.marker end,
        function(v) db.marker = v end)
    y = y - 26
    Check(panel, "Game's interact icon", "The game's own icon above the object (pickaxe for ore, flower for herbs, hand for chests).", R, y,
        function() return db.gameIcon end,
        function(v) db.gameIcon = v end)
    y = y - 30
    Choice(panel, "Glint style", "Many small stars, or one big spinning star.", R, y,
        { "glints", "star" }, { "Many", "One" },
        function() return db.style end,
        function(v) db.style = v end)
    y = y - 34
    Slider(panel, "Number of glints", nil, R, y, 3, 24, 1,
        function() return db.glints end,
        function(v) db.glints = v end)
    y = y - 44
    Slider(panel, "Cloud size", "How wide the glint cloud is around the object.", R, y, 24, 300, 2,
        function() return db.markerSize end,
        function(v) db.markerSize = v end)
    y = y - 44
    Slider(panel, "Height", "Move the glint cloud up or down until it sits around the object. Tip: stand at a node and type /lh height -120 to try values.", R, y, -300, 60, 2,
        function() return db.markerOffset end,
        function(v) db.markerOffset = v end)
    y = y - 44
    Note(panel, "Colors: click the square next to each type on the left.", R + 4, y)
    y = y - 20
    Button(panel, "Reset colors", "Puts every type back to its starting color.", R + 4, y, 140, function()
        ns.ResetColors()
    end)
    y = y - 34
    Choice(panel, "Object outline", "The game's own outline around the targeted object (Graphics > Outline Mode). Keep leaves your graphics setting alone.",
        R, y, { "keep", "high", "good", "off" }, { "Keep", "High", "Good", "Off" },
        function() return db.outline end,
        function(v)
            db.outline = v
            if db.enabled then ns.ApplyCVars() end
        end)
    y = y - 30
    Check(panel, "Quest item sparkles", "The game's own sparkle on quest items. The game only shows it while Object outline is Off. Turning this off needs a full game restart.",
        R, y,
        function() return db.questSparkle end,
        function(v)
            db.questSparkle = v
            if db.enabled then ns.ApplyCVars() end
        end)
    y = y - 28
    Check(panel, "Banner at the top of the screen", nil, R, y,
        function() return db.banner end,
        function(v) db.banner = v end)
    y = y - 28
    Check(panel, "Ping sound", "Plays when something new comes into range.", R, y,
        function() return db.sound end,
        function(v) db.sound = v end)
    y = y - 34
    Button(panel, "Test banner", "Shows the banner for 3 seconds.", R + 4, y, 140, function()
        ns.TestBanner()
    end)

    panel:SetScript("OnShow", RefreshAll)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Loot Highlight")
        Settings.RegisterAddOnCategory(category)
        ns.settingsCategory = category
    end
end

-- Opens the settings page. Returns false when that is not possible.
function ns.OpenOptions()
    if not ns.settingsCategory or not Settings or not Settings.OpenToCategory then
        return false
    end
    if InCombatLockdown() then
        ns.openOptionsAfterCombat = true -- opened when combat ends
        ns.Print("the settings open when this fight is over")
        return true
    end
    Settings.OpenToCategory(ns.settingsCategory:GetID())
    return true
end
