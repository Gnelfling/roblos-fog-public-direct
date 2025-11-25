-- StormSystem: Smooth altitude sound crossfade + progressive screen shake
-- LocalScript -> StarterPlayerScripts or StarterGui

-- Services
local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")
local TweenService  = game:GetService("TweenService")
local UserInput     = game:GetService("UserInputService")
local SoundService  = game:GetService("SoundService")
local Lighting      = game:GetService("Lighting")

local player = Players.LocalPlayer
local guiParent = player:WaitForChild("PlayerGui")
local camera = workspace:FindFirstChild("CurrentCamera") or workspace.CurrentCamera

-- ===== CONFIG =====
local PARTICLE_TEXTURE = "17628471654"

-- rain sound ids (per-altitude)
local SOUND_LOW   = "rbxassetid://9064263922"        -- default ground
local SOUND_500   = "rbxassetid://7768706125"        -- at ~500
local SOUND_1000  = "rbxassetid://8952534866"        -- at ~1000
local SOUND_7000  = "rbxassetid://107570305797094"  -- at ~7000+

-- blend ranges (adjust for wider/narrower crossfades)
local BLEND_500_MIN, BLEND_500_MAX   = 400, 600    -- low <-> 500
local BLEND_500_1000_MIN, BLEND_500_1000_MAX = 900, 1100  -- 500 <-> 1000
local BLEND_1000_7000_MIN, BLEND_1000_7000_MAX = 4000, 10000 -- 1000 <-> 7000 (wide)

-- screen shake thresholds
local SHAKE_START_Y = 5000
local SHAKE_FULL_Y  = 7000
local SHAKE_BASE_AMPLITUDE = 0.5  -- studs at start
local SHAKE_MAX_AMPLITUDE  = 3.0  -- studs at full (7000)

-- rain/fog/particles config (kept from previous)
local RAIN_PART_SIZE    = Vector3.new(800, 1, 800)
local RAIN_PART_HEIGHT  = 140
local EMITTER_COUNT     = 20
local EMITTER_RATE_BASE = 2500 -- extremely heavy as requested
local EMITTER_SIZE      = 6
local EMITTER_SPEED_MIN = 120
local EMITTER_SPEED_MAX = 170
local EMITTER_LIFE_MIN  = 3.5
local EMITTER_LIFE_MAX  = 5.0
local EMITTER_ACCEL     = -400
local VELOCITY_SPREAD   = 22
local ZOFFSET_SPAN      = 0

local THUNDER_MIN_INT = 10
local THUNDER_MAX_INT = 20
local THUNDER_IDS = {"4961240438","6767192500","7768747890","6409267922","7768751498"}

-- ===== Fog fade settings (user request) =====
local FOG_VANISH_HEIGHT = 20000     -- fog removed at/above this height
local FOG_START_FADE    = 8000      -- begin fading from this height
local RAIN_FOG_BASE_DENSITY = 0.02  -- very subtle base density when low
local RAIN_FOG_BASE_HAZE    = 0.8   -- subtle haze

-- ===== helpers =====
local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end
local function lerp(a,b,t) return a + (b-a) * t end
local function smoothstep(a,b,x)
    if b <= a then return 0 end
    local t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
end

local function logConsole(msg) print("[StormSystem]: "..msg) end

-- ===== Atmosphere preservation =====
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
local createdAtmosphere = false
if not atmosphere then
    atmosphere = Instance.new("Atmosphere")
    atmosphere.Parent = Lighting
    createdAtmosphere = true
    logConsole("No Atmosphere found — created new instance.")
else
    logConsole("Found existing Atmosphere — preserving original settings.")
end

local originalAtmosphere = {
    Density = atmosphere.Density,
    Offset  = atmosphere.Offset,
    Color   = atmosphere.Color,
    Glare   = atmosphere.Glare,
    Haze    = atmosphere.Haze,
}

-- Keep older RAIN_FOG_* definitions for compatibility but we will use the new subtle base
local RAIN_FOG_BOOST = 0.45
local RAIN_FOG_DENSITY = math.clamp((originalAtmosphere.Density or 0) + RAIN_FOG_BOOST, 0, 1)
local RAIN_FOG_HAZE    = (originalAtmosphere.Haze and originalAtmosphere.Haze > 0) and (originalAtmosphere.Haze + 4) or 6

-- Replacement: lightweight setFogEnabled that sets base density but per-frame will modulate by height
local function setFogEnabled(on, logLabel)
    if on then
        atmosphere.Density = RAIN_FOG_BASE_DENSITY
        atmosphere.Haze = RAIN_FOG_BASE_HAZE
        atmosphere.Color = originalAtmosphere.Color or Color3.fromRGB(200,200,200)
        atmosphere.Offset = originalAtmosphere.Offset or 0
        atmosphere.Glare = originalAtmosphere.Glare or 0
        if logLabel then
            logLabel.Text = logLabel.Text .. "\nFog ENABLED (base density="..tostring(RAIN_FOG_BASE_DENSITY)..")"
        end
        logConsole("Fog ENABLED (base density="..tostring(RAIN_FOG_BASE_DENSITY)..")")
    else
        atmosphere.Density = originalAtmosphere.Density or 0
        atmosphere.Haze = originalAtmosphere.Haze or 0
        atmosphere.Color = originalAtmosphere.Color or Color3.fromRGB(200,200,200)
        atmosphere.Offset = originalAtmosphere.Offset or 0
        atmosphere.Glare = originalAtmosphere.Glare or 0
        if logLabel then
            logLabel.Text = logLabel.Text .. "\nFog DISABLED (restored)"
        end
        logConsole("Fog DISABLED (restored)")
    end
end

-- ===== rain part & emitters (PART-parented emitters) =====
local rainPart = Instance.new("Part")
rainPart.Name = "ClientRainPart"
rainPart.Size = RAIN_PART_SIZE
rainPart.Anchored = true
rainPart.CanCollide = false
rainPart.Transparency = 1
rainPart.Parent = workspace

-- clear previous emitters if re-run
for _, c in ipairs(rainPart:GetChildren()) do
    if c:IsA("ParticleEmitter") then pcall(function() c:Destroy() end) end
end

local rainEmitters = {}
math.randomseed(tick() % 65536)
for i = 1, EMITTER_COUNT do
    local e = Instance.new("ParticleEmitter")
    e.Texture = "rbxassetid://"..PARTICLE_TEXTURE
    e.Rate = math.max(1, EMITTER_RATE_BASE + math.random(-120,120))
    local spmin = EMITTER_SPEED_MIN + math.random(-14,14)
    local spmax = EMITTER_SPEED_MAX + math.random(-14,14)
    e.Speed = NumberRange.new(spmin, spmax)
    e.Lifetime = NumberRange.new(EMITTER_LIFE_MIN, EMITTER_LIFE_MAX)
    e.Size = NumberSequence.new(EMITTER_SIZE)
    e.Transparency = NumberSequence.new(0.2)
    e.VelocitySpread = VELOCITY_SPREAD
    pcall(function() e.Acceleration = Vector3.new(0, EMITTER_ACCEL, 0) end)
    pcall(function() e.EmissionDirection = Enum.NormalId.Bottom end)
    e.RotSpeed = NumberRange.new(0,0)
    e.LightInfluence = 0
    -- per request: set ZOffset = 0
    e.ZOffset = 0
    e.Enabled = false
    e.Parent = rainPart
    table.insert(rainEmitters, e)
end
logConsole("Created rainPart and "..tostring(#rainEmitters).." emitters (Rate="..tostring(EMITTER_RATE_BASE)..", ZOffset=0).")

-- ===== Rain sounds (four layers) =====
local sound_low   = Instance.new("Sound", SoundService); sound_low.Looped = true;   sound_low.SoundId = SOUND_LOW;  sound_low.Volume = 0
local sound_500   = Instance.new("Sound", SoundService); sound_500.Looped = true;   sound_500.SoundId = SOUND_500; sound_500.Volume = 0
local sound_1000  = Instance.new("Sound", SoundService); sound_1000.Looped = true;  sound_1000.SoundId = SOUND_1000; sound_1000.Volume = 0
local sound_7000  = Instance.new("Sound", SoundService); sound_7000.Looped = true;  sound_7000.SoundId = SOUND_7000; sound_7000.Volume = 0

-- play them silent; they'll be crossfaded
local function startAllRainSounds()
    pcall(function() sound_low:Play() end)
    pcall(function() sound_500:Play() end)
    pcall(function() sound_1000:Play() end)
    pcall(function() sound_7000:Play() end)
end
local function stopAllRainSounds()
    pcall(function() sound_low:Stop() end)
    pcall(function() sound_500:Stop() end)
    pcall(function() sound_1000:Stop() end)
    pcall(function() sound_7000:Stop() end)
end

-- ===== thunder & bright lightning flash (keeps previous logic) =====
local function lightningFlashBig(duration, intensity, logLabel)
    local origAmbient = Lighting.Ambient
    local origOutdoor = Lighting:FindFirstChild("OutdoorAmbient") and Lighting.OutdoorAmbient or Lighting.Ambient
    local origBrightness = Lighting.Brightness or 1
    local origExposure = 0
    pcall(function() origExposure = Lighting.ExposureCompensation or 0 end)
    local origClockTime = 0
    pcall(function() origClockTime = Lighting.ClockTime or 12 end)

    local flashAmbient = Color3.new(1,1,1)
    local flashOutdoor = Color3.new(1,1,1)
    local flashBrightness = math.max(6, (origBrightness or 1) + intensity)
    local flashExposure = (origExposure or 0) + (intensity * 0.6)

    pcall(function() Lighting.Ambient = flashAmbient end)
    pcall(function() Lighting.OutdoorAmbient = flashOutdoor end)
    pcall(function() Lighting.Brightness = flashBrightness end)
    pcall(function() Lighting.ExposureCompensation = flashExposure end)
    pcall(function() Lighting.ClockTime = math.clamp((origClockTime - 0.5), 0, 24) end)

    if logLabel then logLabel.Text = logLabel.Text .. "\nLightning flash (bright) started" end

    spawn(function()
        wait(duration)
        pcall(function()
            local info = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
            local tweenB = TweenService:Create(Lighting, info, {Brightness = origBrightness})
            tweenB:Play()
        end)
        pcall(function()
            local info = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
            local tweenE = TweenService:Create(Lighting, info, {ExposureCompensation = origExposure})
            tweenE:Play()
        end)
        wait(0.18)
        pcall(function() Lighting.Ambient = origAmbient end)
        pcall(function() Lighting.OutdoorAmbient = origOutdoor end)
        pcall(function() Lighting.ClockTime = origClockTime end)
        if logLabel then logLabel.Text = logLabel.Text .. "\nLightning flash ended (restored)" end
    end)
end

local function playThunderWithBigFlash(logLabel)
    local idx = math.random(1, #THUNDER_IDS)
    local id = THUNDER_IDS[idx]
    if logLabel then logLabel.Text = logLabel.Text .. "\nThunder RNG index: "..tostring(idx).." id: "..id end
    lightningFlashBig(0.28, 6.0, logLabel)
    wait(0.10)
    local thunder = Instance.new("Sound", SoundService)
    thunder.SoundId = "rbxassetid://"..id
    thunder.Volume = 1
    thunder:Play()
    thunder.Ended:Connect(function() pcall(function() thunder:Destroy() end) end)
end

spawn(function()
    while true do
        if thunderEnabled then
            local tWait = math.random(THUNDER_MIN_INT, THUNDER_MAX_INT)
            if logLabel then logLabel.Text = logLabel.Text .. "\nNext thunder in "..tostring(tWait).."s" end
            wait(tWait)
            if thunderEnabled then playThunderWithBigFlash(logLabel) end
        else
            wait(0.6)
        end
    end
end)

-- ===== GUI (draggable, M toggle, white texts) =====
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "StormSystemGUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = guiParent

local frame = Instance.new("Frame", screenGui)
frame.Size = UDim2.new(0,520,0,320)
frame.AnchorPoint = Vector2.new(0.5,0.5)
frame.Position = UDim2.new(0.5,0.5)
frame.BackgroundColor3 = Color3.fromRGB(28,28,28)
frame.BorderSizePixel = 0
Instance.new("UICorner", frame).CornerRadius = UDim.new(0,12)

-- draggable
local dragging, dragStart, startPos = false, Vector2.new(), UDim2.new()
frame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = frame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
frame.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

local title = Instance.new("TextLabel", frame)
title.Size = UDim2.new(1,-24,0,30); title.Position = UDim2.new(0,12,0,8)
title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold; title.TextSize = 20
title.TextColor3 = Color3.fromRGB(230,230,230); title.Text = "Storm Control (Rain + Fog + Thunder)"

local rainBtn = Instance.new("TextButton", frame)
rainBtn.Size = UDim2.new(0,240,0,44); rainBtn.Position = UDim2.new(0,16,0,56)
rainBtn.Font = Enum.Font.GothamSemibold; rainBtn.TextSize = 16; rainBtn.TextColor3 = Color3.fromRGB(255,255,255)
rainBtn.Text = "Toggle Rain + Fog"; rainBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)
Instance.new("UICorner", rainBtn).CornerRadius = UDim.new(0,8)
local rainGrad = Instance.new("UIGradient", rainBtn); rainGrad.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(75,75,75)), ColorSequenceKeypoint.new(1, Color3.fromRGB(40,40,40))}); rainGrad.Rotation = 90

local thunderBtn = Instance.new("TextButton", frame)
thunderBtn.Size = UDim2.new(0,240,0,44); thunderBtn.Position = UDim2.new(0,264,0,56)
thunderBtn.Font = Enum.Font.GothamSemibold; thunderBtn.TextSize = 16; thunderBtn.TextColor3 = Color3.fromRGB(255,255,255)
thunderBtn.Text = "Toggle Thunder"; thunderBtn.BackgroundColor3 = Color3.fromRGB(10,10,10)
Instance.new("UICorner", thunderBtn).CornerRadius = UDim.new(0,8)
local thunderGrad = Instance.new("UIGradient", thunderBtn); thunderGrad.Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(0,0,0)), ColorSequenceKeypoint.new(1, Color3.fromRGB(255,220,0))}); thunderGrad.Rotation = 45

local logLabel = Instance.new("TextLabel", frame)
logLabel.Size = UDim2.new(1, -24, 0, 160); logLabel.Position = UDim2.new(0,12,0,116)
logLabel.BackgroundColor3 = Color3.fromRGB(18,18,18); logLabel.TextColor3 = Color3.fromRGB(200,200,200)
logLabel.Font = Enum.Font.SourceSans; logLabel.TextSize = 14; logLabel.TextWrapped = true; logLabel.TextXAlignment = Enum.TextXAlignment.Left; logLabel.TextYAlignment = Enum.TextYAlignment.Top
logLabel.Text = "Logs:"
Instance.new("UICorner", logLabel).CornerRadius = UDim.new(0,6)

-- hover animations
local function addHover(btn)
    btn.MouseEnter:Connect(function() pcall(function() TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {BackgroundColor3 = btn.BackgroundColor3 + Color3.new(0.06,0.06,0.06)}):Play() end) end)
    btn.MouseLeave:Connect(function() pcall(function() TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {BackgroundColor3 = btn.BackgroundColor3 - Color3.new(0.06,0.06,0.06)}):Play() end) end)
end
addHover(rainBtn); addHover(thunderBtn)

-- ===== state vars =====
local rainEnabled = false
local thunderEnabled = false
local menuOpen = true

rainBtn.MouseButton1Click:Connect(function()
    rainEnabled = not rainEnabled
    for _, e in ipairs(rainEmitters) do e.Enabled = rainEnabled end
    setFogEnabled(rainEnabled, logLabel)
    if rainEnabled then
        startAllRainSounds()
        logLabel.Text = logLabel.Text .. "\nRain+Fog ENABLED"
    else
        stopAllRainSounds()
        -- set volumes to 0 just in case
        sound_low.Volume = 0; sound_500.Volume = 0; sound_1000.Volume = 0; sound_7000.Volume = 0
        logLabel.Text = logLabel.Text .. "\nRain+Fog DISABLED"
    end
end)

thunderBtn.MouseButton1Click:Connect(function()
    thunderEnabled = not thunderEnabled
    logLabel.Text = logLabel.Text .. "\nThunder "..(thunderEnabled and "ENABLED" or "DISABLED")
end)

UserInput.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.M then
        if menuOpen then
            menuOpen = false; frame.Visible = false; logLabel.Text = logLabel.Text .. "\nMenu closed"
        else
            menuOpen = true; frame.Visible = true; logLabel.Text = logLabel.Text .. "\nMenu opened"
        end
    end
end)

-- ===== Per-frame update: position rain part, compute smooth crossfade volumes, apply shake =====
RunService.Heartbeat:Connect(function(dt)
    local char = player.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    if not hrp then return end

    -- position rain emitter part above player
    rainPart.Position = hrp.Position + Vector3.new(0, RAIN_PART_HEIGHT, 0)

    if rainEnabled then
        local y = hrp.Position.Y

        -- compute smooth contributions
        -- low sound decreases around 400..600
        local lowFadeOut = smoothstep(BLEND_500_MIN, BLEND_500_MAX, y) -- 0..1
        local vol_low = clamp(1 - lowFadeOut, 0, 1)

        -- 500 sound: fades in around 400..600 and fades out around 900..1100
        local midIn = smoothstep(BLEND_500_MIN, BLEND_500_MAX, y)
        local midOut = smoothstep(BLEND_500_1000_MIN, BLEND_500_1000_MAX, y)
        local vol_500 = clamp(midIn * (1 - midOut), 0, 1)

        -- 1000 sound: fades in around 900..1100 and fades out around 4000..10000
        local highIn = smoothstep(BLEND_500_1000_MIN, BLEND_500_1000_MAX, y)
        local highOut = smoothstep(BLEND_1000_7000_MIN, BLEND_1000_7000_MAX, y)
        local vol_1000 = clamp(highIn * (1 - highOut), 0, 1)

        -- 7000+ sound: ramps up from 4000..10000
        local vol_7000 = clamp(smoothstep(BLEND_1000_7000_MIN, BLEND_1000_7000_MAX, y), 0, 1)

        -- normalize if sum > 1 (avoid overall loudness spike) — keep relative shape
        local total = vol_low + vol_500 + vol_1000 + vol_7000
        if total > 1 then
            vol_low = vol_low / total
            vol_500 = vol_500 / total
            vol_1000 = vol_1000 / total
            vol_7000 = vol_7000 / total
        end

        -- apply volumes smoothly using TweenService (small tweens) for extra smoothing
        local ok, _ = pcall(function()
            sound_low.Volume   = vol_low
            sound_500.Volume   = vol_500
            sound_1000.Volume  = vol_1000
            sound_7000.Volume  = vol_7000
        end)

        -- ----- NEW: Height-based fog modulation (smooth fade to 0 at 20,000 studs) -----
        -- compute scale: 1 at/below FOG_START_FADE, 0 at/above FOG_VANISH_HEIGHT, linear in between
        local scale = 1
        if y <= FOG_START_FADE then
            scale = 1
        else
            scale = clamp(1 - ((y - FOG_START_FADE) / math.max(1, FOG_VANISH_HEIGHT - FOG_START_FADE)), 0, 1)
        end

        -- smoothing factor per-frame for gentle transitions
        local smoothFactor = 0.12

        -- target values (fog off if scale==0)
        local targetDensity = RAIN_FOG_BASE_DENSITY * scale
        local targetHaze = RAIN_FOG_BASE_HAZE * math.max(0.12, scale)

        -- apply exponential smoothing so atmosphere changes are gradual
        local currentDensity = atmosphere.Density or 0
        atmosphere.Density = currentDensity + (targetDensity - currentDensity) * smoothFactor

        local currentHaze = atmosphere.Haze or 0
        atmosphere.Haze = currentHaze + (targetHaze - currentHaze) * smoothFactor

        -- ensure full removal at/above vanish height (snap to zero to avoid tiny residuals)
        if y >= FOG_VANISH_HEIGHT then
            atmosphere.Density = 0
            atmosphere.Haze = 0
        end
        -- --------------------------------------------------------------------------------

        -- screen shake: start at SHAKE_START_Y, full at SHAKE_FULL_Y
        if y >= SHAKE_START_Y then
            local t = clamp((y - SHAKE_START_Y) / math.max(1, SHAKE_FULL_Y - SHAKE_START_Y), 0, 1)
            local baseAmp = lerp(SHAKE_BASE_AMPLITUDE, SHAKE_MAX_AMPLITUDE, t)
            -- further scale if above full height
            if y > SHAKE_FULL_Y then
                baseAmp = baseAmp * (1 + (y - SHAKE_FULL_Y) / 10000) -- slight growth beyond 7000
            end
            -- smooth noise-based offset (uses tick for time factor)
            local time = tick()
            local ox = (math.noise(time * 0.8, 0) - 0.5) * 2 * baseAmp
            local oy = (math.noise(0, time * 0.9) - 0.5) * 2 * baseAmp
            local oz = (math.noise(time * 0.7, 1) - 0.5) * 2 * (baseAmp * 0.5)
            -- apply to camera safely
            if camera and camera:IsA("Camera") then
                local base = camera.CFrame
                camera.CFrame = base * CFrame.new(ox, oy, oz)
            end
        end
    end
end)

-- initial GUI log
logLabel.Text = logLabel.Text .. "\nScript loaded. Rain OFF. Thunder OFF. Atmosphere preserved."
logConsole("StormSystem loaded.")
