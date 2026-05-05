--[[
    prop_attacher — client.lua
    Debug tool for bone attachment offsets/rotations.

    INTERACTION MODEL (matches ps-housing / qbx_properties pattern):
    ─────────────────────────────────────────────────────────────────
    • UI panel is always open with NUI cursor visible.
    • RMB held OUTSIDE the panel area → freecam mode
        – NUI focus drops, game owns input
        – WASD moves camera, mouse look, Shift = fast
        – Release RMB → NUI focus restored, cursor back
    • LMB drag on a gizmo AXIS ARROW → moves prop along that axis
    • LMB drag on a gizmo ROTATION RING → rotates prop on that axis
    • Panel nudge buttons and inputs still work normally
]]

-- ─── State ────────────────────────────────────────────────────────────────────

local State = {
    open          = false,
    minimized     = false,
    initialized   = false,
    placing       = false,
    attachedProps = {},
    activeProp    = nil,
    activeBone    = 24818,
    offset        = vec3(0.0, 0.0, 0.0),
    rotation      = vec3(0.0, 0.0, 0.0),
}

-- Freecam (RMB-held-outside-panel)
local freeCam         = nil
local freeCamActive   = false
local FC_SPEED        = 0.08       -- base units per frame
local FC_SENS         = 0.5        -- degrees per mouse unit (was 0.08, too slow)

-- Gizmo
local GIZMO_ARM       = 0.5        -- world-unit length of each arrow
local GIZMO_RING_R    = 0.35       -- rotation ring radius
local GIZMO_HIT_SCR   = 0.04      -- screen-space hit threshold (0..1 range)

local dragMode        = nil        -- 'offsetX','offsetY','offsetZ','rotX','rotY','rotZ'
local dragLast        = nil        -- last world point on axis

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function v3len(v)
    return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
end

local function AttachToCurrentBone()
    if not State.activeProp or not DoesEntityExist(State.activeProp) then return end
    local ped = PlayerPedId()
    AttachEntityToEntity(
        State.activeProp, ped,
        GetPedBoneIndex(ped, State.activeBone),
        State.offset.x,   State.offset.y,   State.offset.z,
        State.rotation.x, State.rotation.y, State.rotation.z,
        true, true, false, true, 1, true
    )
end

local function CancelPlacement()
    if State.activeProp and DoesEntityExist(State.activeProp) then
        DeleteObject(State.activeProp)
    end
    State.activeProp = nil
    State.placing    = false
end

local function GetAttachedList()
    local list = {}
    for i, e in ipairs(State.attachedProps) do
        list[i] = { index = i, model = tostring(e.model), bone = e.bone }
    end
    return list
end

-- ─── Gizmo ────────────────────────────────────────────────────────────────────
--
-- Bone axes are cached once and only refreshed when the bone selection changes.
-- Recomputing every frame from GetEntityBoneRotation causes wobble because GTA
-- continuously jitters the reported bone rotation while a prop is attached to it.

local ARM  = GIZMO_ARM
local RING = GIZMO_RING_R

-- Cached bone axes — set by RefreshBoneAxes(), never recomputed mid-frame
local cachedRight   = vec3(1,0,0)
local cachedForward = vec3(0,1,0)
local cachedUp      = vec3(0,0,1)

-- Cached drag axes frozen at drag-start
local dragAxes = nil

local function RefreshBoneAxes()
    -- Call this whenever the bone selection changes, not every frame
    local ped  = PlayerPedId()
    local bIdx = GetPedBoneIndex(ped, State.activeBone)
    if bIdx == -1 then return end
    -- Wait one frame so the ped has settled before reading bone rotation
    local br   = GetEntityBoneRotation(ped, bIdx, 2)
    local p    = math.rad(br.x)
    local rl   = math.rad(br.y)
    local y    = math.rad(br.z)
    local sinP,cosP = math.sin(p), math.cos(p)
    local sinY,cosY = math.sin(y), math.cos(y)
    local sinR,cosR = math.sin(rl),math.cos(rl)
    cachedRight   = vec3(cosY*cosR+sinY*sinP*sinR,  sinY*cosR-cosY*sinP*sinR,  cosP*sinR)
    cachedForward = vec3(-sinY*cosP,                 cosY*cosP,                 sinP)
    cachedUp      = vec3(cosY*sinR-sinY*sinP*cosR,  sinY*sinR+cosY*sinP*cosR,  cosP*cosR)
end

-- Always returns the cached axes — never reads bone rotation mid-frame
local function GetBoneAxes()
    return cachedRight, cachedForward, cachedUp
end

local function ScreenDist(wx,wy,wz,sx,sy)
    local ok,px,py = World3dToScreen2d(wx,wy,wz)
    if not ok then return 1e9 end
    return math.sqrt((px-sx)^2+(py-sy)^2)
end

local function TestArrow(pos,tip,sx,sy,bestD,best,name)
    local d1 = ScreenDist(tip.x,tip.y,tip.z,sx,sy)
    local mid = (pos+tip)*0.5
    local d2  = ScreenDist(mid.x,mid.y,mid.z,sx,sy)
    local d   = math.min(d1,d2)
    if d < bestD then return d,name end
    return bestD,best
end

local function HitTestGizmo(prop,sx,sy)
    if not DoesEntityExist(prop) then return nil end
    local pos = GetEntityCoords(prop)
    local right,forward,up = GetBoneAxes()
    local best,bestD = nil, GIZMO_HIT_SCR

    bestD,best = TestArrow(pos, pos+right*ARM,   sx,sy,bestD,best,'offsetX')
    bestD,best = TestArrow(pos, pos+forward*ARM, sx,sy,bestD,best,'offsetY')
    bestD,best = TestArrow(pos, pos+up*ARM,      sx,sy,bestD,best,'offsetZ')

    local rings = {
        { mode='rotX', u=forward, v=up      },
        { mode='rotY', u=right,   v=up      },
        { mode='rotZ', u=right,   v=forward },
    }
    for _,ring in ipairs(rings) do
        for i=0,15 do
            local ang = (i/16)*math.pi*2
            local rp = pos + (ring.u*math.cos(ang)+ring.v*math.sin(ang))*RING
            local d  = ScreenDist(rp.x,rp.y,rp.z,sx,sy)
            if d < bestD then bestD=d; best=ring.mode end
        end
    end
    return best
end

-- For offset drag: project cursor ray onto axis, return t in world units
local function RayAxisT(camPos,rayDir,origin,axis)
    local wx,wy,wz = camPos.x-origin.x, camPos.y-origin.y, camPos.z-origin.z
    local a = rayDir.x^2+rayDir.y^2+rayDir.z^2
    local b = rayDir.x*axis.x+rayDir.y*axis.y+rayDir.z*axis.z
    local c = axis.x^2+axis.y^2+axis.z^2
    local d = rayDir.x*wx+rayDir.y*wy+rayDir.z*wz
    local e = axis.x*wx+axis.y*wy+axis.z*wz
    local denom = a*c - b*b
    if math.abs(denom)<1e-6 then return nil end
    return (a*e - b*d)/denom
end

-- For rotation drag: project cursor onto ring plane, return angle (rad)
local function RayRingAngle(camPos,rayDir,origin,normal,u,v)
    local denom = rayDir.x*normal.x+rayDir.y*normal.y+rayDir.z*normal.z
    if math.abs(denom)<1e-6 then return nil end
    local t = ((origin.x-camPos.x)*normal.x+(origin.y-camPos.y)*normal.y+(origin.z-camPos.z)*normal.z)/denom
    local hit = camPos + rayDir*t
    local rel = hit - origin
    local du = rel.x*u.x+rel.y*u.y+rel.z*u.z
    local dv = rel.x*v.x+rel.y*v.y+rel.z*v.z
    return math.atan(dv, du)
end

-- Wrap an angle delta to [-pi, pi] to avoid 360-degree snaps
local function WrapDelta(delta)
    while delta >  math.pi do delta = delta - 2*math.pi end
    while delta < -math.pi do delta = delta + 2*math.pi end
    return delta
end

local function GetCamRay(sx,sy)
    local camPos = GetGameplayCamCoords()
    local rot    = GetGameplayCamRot(2)
    local fov    = math.rad(GetGameplayCamFov())
    local p,h    = math.rad(rot.x), math.rad(rot.z)
    local fwdX=-math.sin(h)*math.cos(p); local fwdY=math.cos(h)*math.cos(p); local fwdZ=math.sin(p)
    local rgtX=math.cos(h);              local rgtY=math.sin(h);              local rgtZ=0
    local upX=-math.sin(h)*(-math.sin(p)); local upY=math.cos(h)*(-math.sin(p)); local upZ=math.cos(p)
    local hH=math.tan(fov*0.5); local hW=hH*(16/9)
    local nx=(sx-0.5)*2; local ny=(sy-0.5)*2
    local dx=fwdX+rgtX*nx*hW+upX*(-ny)*hH
    local dy=fwdY+rgtY*nx*hW+upY*(-ny)*hH
    local dz=fwdZ+rgtZ*nx*hW+upZ*(-ny)*hH
    local len=math.sqrt(dx*dx+dy*dy+dz*dz)
    return camPos, vec3(dx/len,dy/len,dz/len)
end

-- Get the drag scalar using cached bone axes and frozen drag origin
local function GetDragScalar(sx,sy)
    if not dragAxes then return nil end
    local camPos,rayDir = GetCamRay(sx,sy)
    local pos     = dragAxes.origin
    local right   = cachedRight
    local forward = cachedForward
    local up      = cachedUp

    if dragMode == 'offsetX' then return RayAxisT(camPos,rayDir,pos,right)
    elseif dragMode == 'offsetY' then return RayAxisT(camPos,rayDir,pos,forward)
    elseif dragMode == 'offsetZ' then return RayAxisT(camPos,rayDir,pos,up)
    elseif dragMode == 'rotX'   then return RayRingAngle(camPos,rayDir,pos,right,  forward,up)
    elseif dragMode == 'rotY'   then return RayRingAngle(camPos,rayDir,pos,forward,right,  up)
    elseif dragMode == 'rotZ'   then return RayRingAngle(camPos,rayDir,pos,up,     right,  forward)
    end
    return nil
end

local function DrawGizmo(prop,hovered)
    if not DoesEntityExist(prop) then return end
    local pos = GetEntityCoords(prop)
    local right,forward,up = GetBoneAxes()

    local arrows = {
        { dir=right,   mode='offsetX', r=220,g=50, b=50  },
        { dir=forward, mode='offsetY', r=50, g=200,b=70  },
        { dir=up,      mode='offsetZ', r=60, g=130,b=255 },
    }
    for _,a in ipairs(arrows) do
        local tip   = pos + a.dir*ARM
        local alpha = hovered==a.mode and 255 or 210
        DrawLine(pos.x,pos.y,pos.z, tip.x,tip.y,tip.z, a.r,a.g,a.b,alpha)
        DrawMarker(28,tip.x,tip.y,tip.z, 0,0,0, 0,0,0,
            0.055,0.055,0.055, a.r,a.g,a.b,alpha,
            false,true,2,false,nil,nil,false)
    end

    local rings = {
        { u=forward, v=up,      mode='rotX', r=220,g=50, b=50  },
        { u=right,   v=up,      mode='rotY', r=50, g=200,b=70  },
        { u=right,   v=forward, mode='rotZ', r=60, g=130,b=255 },
    }
    for _,ring in ipairs(rings) do
        local alpha = hovered==ring.mode and 255 or 150
        for i=0,15 do
            local a1=(i/16)*math.pi*2
            local a2=((i+1)/16)*math.pi*2
            local p1=pos+(ring.u*math.cos(a1)+ring.v*math.sin(a1))*RING
            local p2=pos+(ring.u*math.cos(a2)+ring.v*math.sin(a2))*RING
            DrawLine(p1.x,p1.y,p1.z, p2.x,p2.y,p2.z, ring.r,ring.g,ring.b,alpha)
        end
    end

    DrawMarker(28,pos.x,pos.y,pos.z, 0,0,0, 0,0,0,
        0.045,0.045,0.045, 255,255,255,200,
        false,true,2,false,nil,nil,false)
end

-- ─── Freecam ──────────────────────────────────────────────────────────────────
-- RMB outside panel = start. Release RMB = pause (cam stays, no reset).
-- RMB again = resume from same position/angle.
-- Camera is only actually destroyed when menu closes.

local function PauseFreeCam()
    -- Stop look/move loop but KEEP the scripted camera active so view doesn't snap back
    if not freeCamActive then return end
    freeCamActive = false
    -- Restore NUI cursor — but keep RenderScriptCams ON so view holds
    SetNuiFocus(false, false)
    Citizen.CreateThread(function()
        Wait(0)
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'freeCamOff' })
    end)
end

local function DestroyFreeCam()
    -- Actually destroy camera — called only when menu closes/minimizes
    freeCamActive = false
    if freeCam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(freeCam, false)
        freeCam = nil
    end
end

local function StartFreeCam()
    -- If cam already exists just resume the loop from current position
    if not freeCam then
        local ped     = PlayerPedId()
        local coord   = GetEntityCoords(ped)
        local heading = math.rad(GetEntityHeading(ped))
        local sp = vec3(
            coord.x - math.sin(heading) * 3.0,
            coord.y - math.cos(heading) * 3.0,
            coord.z + 1.4
        )
        freeCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        SetCamCoord(freeCam, sp.x, sp.y, sp.z)
        local dir   = coord - sp
        local pitch = math.deg(math.atan(dir.z, math.sqrt(dir.x*dir.x + dir.y*dir.y)))
        local yaw   = math.deg(math.atan(-dir.x, -dir.y))
        SetCamRot(freeCam, pitch, 0.0, yaw, 2)
        SetCamFov(freeCam, 60.0)
    end

    if freeCamActive then return end  -- loop already running
    freeCamActive = true

    SetCamActive(freeCam, true)
    RenderScriptCams(true, false, 0, true, true)  -- instant switch, no blend

    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'freeCamOn' })

    Citizen.CreateThread(function()
        while freeCamActive do
            Wait(0)

            -- Suppress ped movement
            DisableControlAction(0, 30,  true)
            DisableControlAction(0, 31,  true)
            DisableControlAction(0, 36,  true)
            DisableControlAction(0, 22,  true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 24,  true)
            DisableControlAction(0, 25,  true)

            -- Mouse look — controls 1 & 2 are true per-frame deltas
            local mx  = GetDisabledControlNormal(0, 1)
            local my  = GetDisabledControlNormal(0, 2)
            local rot = GetCamRot(freeCam, 2)
            SetCamRot(freeCam,
                math.max(-89.0, math.min(89.0, rot.x - my * FC_SENS * 10.0)),
                0.0,
                rot.z - mx * FC_SENS * 10.0,
                2)

            -- WASD movement
            local shift = IsDisabledControlPressed(0, 21)
            local speed = FC_SPEED * (shift and 4.0 or 1.0)
            local r2    = GetCamRot(freeCam, 2)
            local p     = math.rad(r2.x)
            local h     = math.rad(r2.z)
            local fwd   = vec3(-math.sin(h)*math.cos(p),  math.cos(h)*math.cos(p),  math.sin(p))
            local rgt   = vec3( math.cos(h),               math.sin(h),              0.0)
            local up    = vec3(0.0, 0.0, 1.0)
            local move  = vec3(0.0, 0.0, 0.0)

            if IsDisabledControlPressed(0, 32) then move = move + fwd  end
            if IsDisabledControlPressed(0, 33) then move = move - fwd  end
            if IsDisabledControlPressed(0, 34) then move = move - rgt  end
            if IsDisabledControlPressed(0, 35) then move = move + rgt  end
            if IsDisabledControlPressed(0, 44) then move = move + up   end
            if IsDisabledControlPressed(0, 38) then move = move - up   end

            local cp = GetCamCoord(freeCam)
            SetCamCoord(freeCam, cp.x+move.x*speed, cp.y+move.y*speed, cp.z+move.z*speed)

            if State.activeProp and DoesEntityExist(State.activeProp) then
                DrawGizmo(State.activeProp, nil)
            end

            -- Release RMB → pause (don't destroy cam)
            if IsDisabledControlJustReleased(0, 25) then
                PauseFreeCam()
                break
            end
        end
    end)
end

-- ─── Placement Loop ───────────────────────────────────────────────────────────


-- NUI tells us cursor position so we can do gizmo hit-testing while UI is open.
local cursorSX, cursorSY = 0.5, 0.5
-- NUI-driven LMB state (IsDisabledControlJustPressed doesn't fire when NUI has focus)
local nuiLmbDown     = false
local nuiLmbJustDown = false
local nuiLmbJustUp   = false

RegisterNUICallback('cursorMove', function(data, cb)
    cursorSX = tonumber(data.x) or cursorSX
    cursorSY = tonumber(data.y) or cursorSY
    cb({ ok=true })
end)

RegisterNUICallback('lmbDown', function(data, cb)
    cursorSX = tonumber(data.x) or cursorSX
    cursorSY = tonumber(data.y) or cursorSY
    nuiLmbJustDown = true
    nuiLmbDown     = true
    cb({ ok=true })
end)

RegisterNUICallback('lmbUp', function(data, cb)
    nuiLmbDown     = false
    nuiLmbJustUp   = true
    cb({ ok=true })
end)

local function PlacementLoop()
    AttachToCurrentBone()
    SendNUIMessage({ action = 'placementStart' })

    while State.placing and State.activeProp and DoesEntityExist(State.activeProp) do
        Wait(0)

        -- While freecam is active the freecam thread handles everything
        if not freeCamActive then
            DisableControlAction(0, 1, true)
            DisableControlAction(0, 2, true)

            -- Consume the just-flags at start of frame
            local lmbJustDown = nuiLmbJustDown
            local lmbDown     = nuiLmbDown
            local lmbJustUp   = nuiLmbJustUp
            nuiLmbJustDown = false
            nuiLmbJustUp   = false

            -- ── Gizmo interaction ────────────────────────────────────────────
            local hovered = (not dragMode) and HitTestGizmo(State.activeProp, cursorSX, cursorSY) or dragMode

            if lmbJustDown and hovered then
                dragMode = hovered
                -- Only freeze the prop's world position at drag start.
                -- Bone axes come from the stable cache (not recomputed per frame).
                dragAxes = { origin = GetEntityCoords(State.activeProp) }
                dragLast = GetDragScalar(cursorSX, cursorSY)
            end

            if dragMode and lmbDown then
                local cur = GetDragScalar(cursorSX, cursorSY)
                if cur and dragLast then
                    local delta = cur - dragLast
                    -- For rotation, wrap delta to [-pi, pi] to prevent 360 snaps
                    if dragMode:sub(1,3) == 'rot' then
                        delta = WrapDelta(delta)
                        -- Clamp to max 45 degrees per frame to prevent any sudden jumps
                        local degDelta = math.max(-45, math.min(45, math.deg(delta)))
                        if dragMode == 'rotX' then
                            State.rotation = vec3(State.rotation.x + degDelta, State.rotation.y, State.rotation.z)
                        elseif dragMode == 'rotY' then
                            State.rotation = vec3(State.rotation.x, State.rotation.y + degDelta, State.rotation.z)
                        elseif dragMode == 'rotZ' then
                            State.rotation = vec3(State.rotation.x, State.rotation.y, State.rotation.z + degDelta)
                        end
                    else
                        if dragMode == 'offsetX' then
                            State.offset = vec3(State.offset.x + delta, State.offset.y, State.offset.z)
                        elseif dragMode == 'offsetY' then
                            State.offset = vec3(State.offset.x, State.offset.y + delta, State.offset.z)
                        elseif dragMode == 'offsetZ' then
                            State.offset = vec3(State.offset.x, State.offset.y, State.offset.z + delta)
                        end
                    end
                    AttachToCurrentBone()
                    SendNUIMessage({
                        action   = 'liveUpdate',
                        offset   = {x=State.offset.x,   y=State.offset.y,   z=State.offset.z},
                        rotation = {x=State.rotation.x, y=State.rotation.y, z=State.rotation.z},
                    })
                end
                dragLast = cur
            end

            if lmbJustUp then
                dragMode = nil
                dragLast = nil
                dragAxes = nil
            end

            -- Scroll = Z offset nudge
            if IsDisabledControlJustPressed(0, 241) then
                State.offset = vec3(State.offset.x, State.offset.y, State.offset.z - 0.005)
                AttachToCurrentBone()
            end
            if IsDisabledControlJustPressed(0, 242) then
                State.offset = vec3(State.offset.x, State.offset.y, State.offset.z + 0.005)
                AttachToCurrentBone()
            end

            -- E = confirm
            if IsDisabledControlJustPressed(0, 38) then
                SendNUIMessage({ action = 'placementConfirmRequest' })
            end

            -- Backspace = minimize
            if IsDisabledControlJustPressed(0, 194) then MinimizeUI() end

            AttachToCurrentBone()
            DrawGizmo(State.activeProp, hovered)
            SendNUIMessage({
                action   = 'liveUpdate',
                offset   = {x=State.offset.x,   y=State.offset.y,   z=State.offset.z},
                rotation = {x=State.rotation.x, y=State.rotation.y, z=State.rotation.z},
            })
        end
    end

    DestroyFreeCam()
    SendNUIMessage({ action = 'placementEnd' })
end

-- ─── NUI Callbacks ────────────────────────────────────────────────────────────

-- NUI sends this when RMB pressed OUTSIDE the panel
RegisterNUICallback('rmbOutside', function(_, cb)
    if State.open and not freeCamActive then
        StartFreeCam()
    end
    cb({ ok = true })
end)

RegisterNUICallback('spawnProp', function(data, cb)
    local model = data.model
    if not model or model == '' then return cb({ ok=false, error='No model provided' }) end
    local hash = GetHashKey(model)
    if not IsModelValid(hash) then return cb({ ok=false, error='Invalid model: '..model }) end

    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) do
        Wait(50); t = t+50
        if t > 5000 then return cb({ ok=false, error='Model load timeout' }) end
    end

    if State.activeProp and DoesEntityExist(State.activeProp) then
        DeleteObject(State.activeProp)
    end

    local ped   = PlayerPedId()
    local coord = GetEntityCoords(ped)
    local prop  = CreateObject(hash, coord.x, coord.y, coord.z+1.0, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    FreezeEntityPosition(prop, true)
    SetEntityCollision(prop, false, false)
    SetEntityAlpha(prop, 200, false)

    State.activeProp = prop
    State.placing    = true
    State.offset     = vec3(0,0,0)
    State.rotation   = vec3(0,0,0)
    RefreshBoneAxes()

    Citizen.CreateThread(PlacementLoop)
    cb({ ok=true })
end)

RegisterNUICallback('setBone', function(data, cb)
    State.activeBone = data.bone
    RefreshBoneAxes()
    AttachToCurrentBone()
    cb({ ok=true })
end)

RegisterNUICallback('applyPreset', function(data, cb)
    local preset = AttachmentPresets[data.index]
    if not preset then return cb({ ok=false }) end
    State.activeBone = preset.bone
    State.offset     = preset.offset
    State.rotation   = preset.rotation
    RefreshBoneAxes()
    AttachToCurrentBone()
    cb({ ok=true,
        offset   = {x=State.offset.x,   y=State.offset.y,   z=State.offset.z},
        rotation = {x=State.rotation.x, y=State.rotation.y, z=State.rotation.z},
    })
end)

RegisterNUICallback('confirmAttach', function(_, cb)
    -- If nothing to attach, just silently succeed (prevents stuck state)
    if not State.activeProp or not DoesEntityExist(State.activeProp) then
        State.activeProp = nil
        State.placing    = false
        dragMode         = nil
        dragLast         = nil
        dragAxes         = nil
        return cb({ ok=true, attached=GetAttachedList() })
    end

    local ped = PlayerPedId()
    SetEntityAlpha(State.activeProp, 255, false)
    SetEntityCollision(State.activeProp, false, false)
    AttachEntityToEntity(
        State.activeProp, ped,
        GetPedBoneIndex(ped, State.activeBone),
        State.offset.x, State.offset.y, State.offset.z,
        State.rotation.x, State.rotation.y, State.rotation.z,
        true, true, false, true, 1, true)

    print(string.format(
        "[prop_attacher] AttachEntityToEntity(prop,ped,GetPedBoneIndex(ped,%d),%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,true,true,false,true,1,true)",
        State.activeBone,
        State.offset.x,State.offset.y,State.offset.z,
        State.rotation.x,State.rotation.y,State.rotation.z))

    table.insert(State.attachedProps, {
        entity   = State.activeProp,
        bone     = State.activeBone,
        offset   = {x=State.offset.x,y=State.offset.y,z=State.offset.z},
        rotation = {x=State.rotation.x,y=State.rotation.y,z=State.rotation.z},
        model    = GetEntityModel(State.activeProp),
    })

    -- Clear everything so there's nothing left to accidentally attach again
    State.activeProp = nil
    State.placing    = false
    State.offset     = vec3(0,0,0)
    State.rotation   = vec3(0,0,0)
    dragMode         = nil
    dragLast         = nil
    dragAxes         = nil

    cb({ ok=true, attached=GetAttachedList() })
end)

RegisterNUICallback('recalibrate', function(_, cb)
    if not State.activeProp or not DoesEntityExist(State.activeProp) then
        return cb({ ok=false, error='No active prop' })
    end

    local ped = PlayerPedId()

    -- pos1: where the prop is right now in the world
    local pos1 = GetEntityCoords(State.activeProp)
    local rot1 = GetEntityRotation(State.activeProp, 2)

    -- Find the closest bone to pos1 (excluding current bone)
    local bestBoneData = nil
    local bestDist     = 1e9
    for _, boneData in ipairs(BoneList) do
        if boneData.index ~= State.activeBone then
            local bIdx = GetPedBoneIndex(ped, boneData.index)
            if bIdx ~= -1 then
                local dist = #(pos1 - GetWorldPositionOfEntityBone(ped, bIdx))
                if dist < bestDist then
                    bestDist     = dist
                    bestBoneData = boneData
                end
            end
        end
    end

    local curBoneIdx  = GetPedBoneIndex(ped, State.activeBone)
    local curBoneDist = #(pos1 - GetWorldPositionOfEntityBone(ped, curBoneIdx))
    local isSame      = (bestBoneData == nil or curBoneDist <= bestDist)

    local function getBoneLabel(idx)
        for _, b in ipairs(BoneList) do
            if b.index == idx then return b.label..' ('..idx..')' end
        end
        return tostring(idx)
    end

    if isSame then
        return cb({
            ok=true, isSame=true,
            curBone=getBoneLabel(State.activeBone),
            newBone=getBoneLabel(State.activeBone),
            newBoneIdx=State.activeBone,
            curOffset={x=State.offset.x, y=State.offset.y, z=State.offset.z},
            newOffset={x=State.offset.x, y=State.offset.y, z=State.offset.z},
            curRot={x=State.rotation.x, y=State.rotation.y, z=State.rotation.z},
            newRot={x=State.rotation.x, y=State.rotation.y, z=State.rotation.z},
        })
    end

    local bestBone = bestBoneData.index
    local bestIdx  = GetPedBoneIndex(ped, bestBone)

    -- All the real work happens in a thread so Wait() actually advances game frames
    -- No thread needed - we use bone natives directly, no Wait required
    local function wrapAngle(a)
        while a >  180 do a = a - 360 end
        while a < -180 do a = a + 360 end
        return a
    end

    -- Build axes for any bone using the exact same math as RefreshBoneAxes
    -- (which is proven correct since the gizmo works)
    local function buildAxes(bIdx)
        local br    = GetEntityBoneRotation(ped, bIdx, 2)
        local p     = math.rad(br.x)
        local rl    = math.rad(br.y)
        local y     = math.rad(br.z)
        local sP,cP = math.sin(p), math.cos(p)
        local sY,cY = math.sin(y), math.cos(y)
        local sR,cR = math.sin(rl),math.cos(rl)
        local right   = vec3(cY*cR+sY*sP*sR,  sY*cR-cY*sP*sR,  cP*sR)
        local forward = vec3(-sY*cP,            cY*cP,            sP)
        local up      = vec3(cY*sR-sY*sP*cR,  sY*sR+cY*sP*cR,  cP*cR)
        return right, forward, up
    end

    -- Inverse transform: project world delta onto bone axes (R^T * delta)
    local function worldToLocal(right, forward, up, delta)
        return
            delta.x*right.x   + delta.y*right.y   + delta.z*right.z,
            delta.x*forward.x + delta.y*forward.y + delta.z*forward.z,
            delta.x*up.x      + delta.y*up.y      + delta.z*up.z
    end

    -- Use the CACHED axes for the current bone (proven correct, not animated)
    -- to verify the math produces State.offset from pos1
    local curBonePos = GetWorldPositionOfEntityBone(ped, curBoneIdx)
    local curDelta   = pos1 - curBonePos
    local checkX, checkY, checkZ = worldToLocal(cachedRight, cachedForward, cachedUp, curDelta)
    local verifyErr = math.abs(checkX - State.offset.x) +
                      math.abs(checkY - State.offset.y) +
                      math.abs(checkZ - State.offset.z)
    print(string.format("[recal] verify err=%.4f (check=%.3f,%.3f,%.3f vs offset=%.3f,%.3f,%.3f)",
        verifyErr, checkX, checkY, checkZ, State.offset.x, State.offset.y, State.offset.z))

    -- Build axes for the new bone
    local newBonePos = GetWorldPositionOfEntityBone(ped, bestIdx)
    local newDelta   = pos1 - newBonePos
    local nRight, nForward, nUp = buildAxes(bestIdx)
    local ox, oy, oz = worldToLocal(nRight, nForward, nUp, newDelta)

    -- Rotation: keep the same local rotation offset relative to each bone's base
    local curBoneRot = GetEntityBoneRotation(ped, curBoneIdx, 2)
    local newBoneRot = GetEntityBoneRotation(ped, bestIdx, 2)
    local localRotX  = wrapAngle(rot1.x - curBoneRot.x)
    local localRotY  = wrapAngle(rot1.y - curBoneRot.y)
    local localRotZ  = wrapAngle(rot1.z - curBoneRot.z)
    local rx = wrapAngle(newBoneRot.x + localRotX)
    local ry = wrapAngle(newBoneRot.y + localRotY)
    local rz = wrapAngle(newBoneRot.z + localRotZ)

    print(string.format("[recal] newBonePos dist=%.3f newOffset=(%.4f,%.4f,%.4f)",
        #newDelta, ox, oy, oz))

    cb({
        ok=true, isSame=false,
        curBone=getBoneLabel(State.activeBone),
        newBone=getBoneLabel(bestBone),
        newBoneIdx=bestBone,
        curOffset={x=State.offset.x,  y=State.offset.y,  z=State.offset.z},
        newOffset={x=ox,               y=oy,              z=oz},
        curRot   ={x=State.rotation.x, y=State.rotation.y,z=State.rotation.z},
        newRot   ={x=rx,               y=ry,              z=rz},
    })
end)
RegisterNUICallback('applyRecalibrate', function(data, cb)
    State.activeBone = tonumber(data.bone)
    State.offset     = vec3(tonumber(data.ox), tonumber(data.oy), tonumber(data.oz))
    State.rotation   = vec3(tonumber(data.rx), tonumber(data.ry), tonumber(data.rz))
    RefreshBoneAxes()
    AttachToCurrentBone()
    cb({ ok=true,
        offset   = {x=State.offset.x,   y=State.offset.y,   z=State.offset.z},
        rotation = {x=State.rotation.x, y=State.rotation.y, z=State.rotation.z},
    })
end)

RegisterNUICallback('deleteSelected', function(data, cb)
    local idx = data.index
    if not idx or not State.attachedProps[idx] then return cb({ ok=false }) end
    local e = State.attachedProps[idx]
    if DoesEntityExist(e.entity) then DetachEntity(e.entity,true,true); DeleteObject(e.entity) end
    table.remove(State.attachedProps, idx)
    cb({ ok=true })
end)

RegisterNUICallback('detachAll', function(_, cb)
    for _, e in ipairs(State.attachedProps) do
        if DoesEntityExist(e.entity) then DetachEntity(e.entity,true,true); DeleteObject(e.entity) end
    end
    State.attachedProps = {}
    cb({ ok=true })
end)

RegisterNUICallback('exportConfig', function(_, cb)
    local out = {}
    for i, e in ipairs(State.attachedProps) do
        out[i] = { model=tostring(e.model), bone=e.bone, offset=e.offset, rotation=e.rotation }
    end
    cb({ ok=true, data=out })
end)

RegisterNUICallback('setOffset', function(data, cb)
    State.offset = vec3(tonumber(data.x) or State.offset.x, tonumber(data.y) or State.offset.y, tonumber(data.z) or State.offset.z)
    AttachToCurrentBone(); cb({ ok=true })
end)

RegisterNUICallback('setRotation', function(data, cb)
    State.rotation = vec3(tonumber(data.x) or State.rotation.x, tonumber(data.y) or State.rotation.y, tonumber(data.z) or State.rotation.z)
    AttachToCurrentBone(); cb({ ok=true })
end)

RegisterNUICallback('nudgeOffset', function(data, cb)
    local step = tonumber(data.step) or 0.01
    local ax = data.axis
    if     ax=='x' then State.offset = vec3(State.offset.x+step, State.offset.y, State.offset.z)
    elseif ax=='y' then State.offset = vec3(State.offset.x, State.offset.y+step, State.offset.z)
    elseif ax=='z' then State.offset = vec3(State.offset.x, State.offset.y, State.offset.z+step) end
    AttachToCurrentBone()
    cb({ ok=true, offset={x=State.offset.x,y=State.offset.y,z=State.offset.z} })
end)

RegisterNUICallback('nudgeRotation', function(data, cb)
    local step = tonumber(data.step) or 1.0
    local ax = data.axis
    if     ax=='x' then State.rotation = vec3(State.rotation.x+step, State.rotation.y, State.rotation.z)
    elseif ax=='y' then State.rotation = vec3(State.rotation.x, State.rotation.y+step, State.rotation.z)
    elseif ax=='z' then State.rotation = vec3(State.rotation.x, State.rotation.y, State.rotation.z+step) end
    AttachToCurrentBone()
    cb({ ok=true, rotation={x=State.rotation.x,y=State.rotation.y,z=State.rotation.z} })
end)

RegisterNUICallback('resetTransform', function(_, cb)
    State.offset = vec3(0,0,0); State.rotation = vec3(0,0,0)
    AttachToCurrentBone()
    cb({ ok=true, offset={x=0,y=0,z=0}, rotation={x=0,y=0,z=0} })
end)

RegisterNUICallback('closeUI',  function(_, cb) CloseUI();    cb({ ok=true }) end)
RegisterNUICallback('minimize', function(_, cb) MinimizeUI(); cb({ ok=true }) end)

-- ─── Open / Close / Minimize ──────────────────────────────────────────────────

function OpenUI()
    if State.open and not State.minimized then return end
    State.open = true; State.minimized = false
    SetNuiFocus(true, true)
    if State.initialized then SendNUIMessage({ action='restore' }); return end
    State.initialized = true
    local boneData, presetData = {}, {}
    for i,b in ipairs(BoneList)         do boneData[i]   = {label=b.label, index=b.index} end
    for i,p in ipairs(AttachmentPresets) do presetData[i] = {label=p.label} end
    SendNUIMessage({ action='open', bones=boneData, presets=presetData, attached=GetAttachedList() })
end

function MinimizeUI()
    if not State.open then return end
    State.minimized = true; State.open = false
    DestroyFreeCam()
    SetNuiFocus(false, false)
    SendNUIMessage({ action='minimize' })
end

function CloseUI()
    if not State.open and not State.minimized then return end
    CancelPlacement(); DestroyFreeCam()
    State.open = false; State.minimized = false; State.initialized = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action='close' })
end

RegisterCommand('propattacher', function()
    if State.minimized then OpenUI()
    elseif State.open   then MinimizeUI()
    else                     OpenUI() end
end, false)

TriggerEvent('chat:addSuggestion', '/propattacher', 'Open / minimize Prop Attacher')

AddEventHandler('onResourceStop', function(r)
    if r ~= GetCurrentResourceName() then return end
    SendNUIMessage({ action='close' })
    SetNuiFocus(false, false)
end)
