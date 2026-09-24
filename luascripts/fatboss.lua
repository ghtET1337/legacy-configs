--[[
    fatboss.lua - FatBoss cosmetics on the official ET: Legacy server.

    Graffiti: a player binds "spray" (bind t spray). One graffiti per life, and
    each player's newest graffiti replaces the older one. The FatBoss cgame
    (zzz_fatboss_*.pk3) draws them; this module decides who may spray what and
    where, and tells every client.

    Designs come from FatBoss. With FATBOSS_LOADOUT_URL set, the module fetches
    {"<cl_guid>": {"graffiti": "<design>"}, ...} every minute in the background
    (FATBOSS_API_TOKEN is sent as a bearer token). Without it, the same JSON is
    read from <fs_homepath>/legacy/fatboss_loadouts.json.

    Runs next to Oksii's stats.lua and combinedfixes.lua in its own Lua VM and
    handles no command other than "spray".
]]

local json = require("dkjson")

local MODNAME = "fatboss"
local VERSION = "0.1"

local SPRAY_RANGE     = 128
local SPRAY_RADIUS    = 28      -- half the side of the graffiti square, in game units
local SPRAY_SCALES    = { 1.0, 0.8, 0.6 }
local SPRAY_SHIFTS    = { { 0, 0 }, { 0.35, 0 }, { -0.35, 0 }, { 0, 0.35 }, { 0, -0.35 },
                          { 0.3, 0.3 }, { -0.3, 0.3 }, { 0.3, -0.3 }, { -0.3, -0.3 } }
local ENTITYNUM_WORLD = (et.MAX_GENTITIES or 1024) - 2
local SURF_SKY        = 0x4
local SURF_NOMARKS    = 0x20
local TEAM_AXIS       = 1
local TEAM_ALLIES     = 2
local FETCH_MS        = 60000
local READ_MS         = 5000
local MESSAGE_GAP_MS  = 1500

local loadouts     = {}  -- cl_guid (upper case) -> graffiti design
local sprays       = {}  -- clientNum -> fbspray command without the sound flag
local usedThisLife = {}  -- clientNum -> true once sprayed in the current life
local lastMessage  = {}  -- clientNum -> level time of the last refusal
local loadoutPath, loadoutUrl, apiToken
local nextFetch, nextRead, lastLoadoutText = 0, 0, nil

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

local function validDesign(design)
    return type(design) == "string" and #design > 0 and #design <= 32 and design:match("^[a-z0-9_]+$") ~= nil
end

-- reads the loadout file when it changed; a broken file keeps the last good table
local function readLoadouts()
    local f = io.open(loadoutPath, "r")
    if not f then
        return
    end
    local text = f:read("*a")
    f:close()
    if not text or text == lastLoadoutText then
        return
    end
    local data = json.decode(text)
    if type(data) ~= "table" then
        et.G_LogPrint(string.format("%s: ignored an unreadable loadout file\n", MODNAME))
        return
    end
    local fresh, count = {}, 0
    for guid, entry in pairs(data) do
        if type(guid) == "string" and type(entry) == "table" and validDesign(entry.graffiti) then
            fresh[guid:upper()] = entry.graffiti
            count = count + 1
        end
    end
    loadouts, lastLoadoutText = fresh, text
    et.G_LogPrint(string.format("%s: %d graffiti loadouts\n", MODNAME, count))
end

-- background download; the file is swapped in only when curl succeeds
local function fetchLoadouts()
    if not loadoutUrl or loadoutUrl == "" then
        return
    end
    local tmp = loadoutPath .. ".tmp"
    local auth = ""
    if apiToken and apiToken ~= "" then
        auth = " -H " .. shellQuote("Authorization: Bearer " .. apiToken)
    end
    os.execute(string.format("(curl -fsS --max-time 10%s -o %s %s && mv -f %s %s) >/dev/null 2>&1 &",
        auth, shellQuote(tmp), shellQuote(loadoutUrl), shellQuote(tmp), shellQuote(loadoutPath)))
end

local function refuse(clientNum, levelTime, text)
    if lastMessage[clientNum] and levelTime - lastMessage[clientNum] < MESSAGE_GAP_MS then
        return
    end
    lastMessage[clientNum] = levelTime
    et.trap_SendServerCommand(clientNum, string.format('cpm "^3FatBoss:^7 %s"', text))
end

local function guidOf(clientNum)
    local userinfo = et.trap_GetUserinfo(clientNum)
    return (et.Info_ValueForKey(userinfo, "cl_guid") or ""):upper()
end

local function vma(a, s, b)
    return { a[1] + s * b[1], a[2] + s * b[2], a[3] + s * b[3] }
end

local function dot(a, b)
    return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

local function normalize(a)
    local l = math.sqrt(dot(a, a))
    if l < 0.0001 then return nil end
    return { a[1] / l, a[2] / l, a[3] / l }
end

-- the whole square must lie on the same wall: probe a 3x3 grid across it
local function squareFits(center, n, up, right, half, clientNum)
    for _, a in ipairs({ -0.95, 0, 0.95 }) do
        for _, b in ipairs({ -0.95, 0, 0.95 }) do
            local p = vma(vma(center, a * half, right), b * half, up)
            local tr = et.trap_Trace(vma(p, 8, n), nil, nil, vma(p, -8, n), clientNum, et.MASK_SOLID)
            if not tr or tr.fraction >= 1 or tr.startsolid or tr.entityNum ~= ENTITYNUM_WORLD
                or (tr.surfaceFlags & (SURF_SKY | SURF_NOMARKS)) ~= 0 or dot(tr.plane.normal, n) < 0.7 then
                return false
            end
        end
    end
    return true
end

-- the largest nearby placement where the whole graffiti is on the wall
local function fitGraffiti(hit, n, up, clientNum)
    local u = normalize(vma(up, -dot(up, n), n)) or { 0, 0, 1 }
    local r = normalize(cross(u, n))
    if not r then return nil end
    for _, scale in ipairs(SPRAY_SCALES) do
        local half = SPRAY_RADIUS * scale
        for _, shift in ipairs(SPRAY_SHIFTS) do
            local c = vma(vma(hit, shift[1] * half, r), shift[2] * half, u)
            if squareFits(c, n, u, r, half, clientNum) then
                return c, half
            end
        end
    end
    return nil
end

local function spray(clientNum)
    local levelTime = et.trap_Milliseconds()
    local team = et.gentity_get(clientNum, "sess.sessionTeam")
    if team ~= TEAM_AXIS and team ~= TEAM_ALLIES then
        return refuse(clientNum, levelTime, "join a team to spray.")
    end
    if (et.gentity_get(clientNum, "health") or 0) <= 0 then
        return refuse(clientNum, levelTime, "you can spray only while alive.")
    end
    if usedThisLife[clientNum] then
        return refuse(clientNum, levelTime, "one graffiti per life.")
    end
    local design = loadouts[guidOf(clientNum)]
    if not design then
        return refuse(clientNum, levelTime, "no graffiti equipped - get one from FatBoss crates.")
    end

    -- trace from the eyes along the view
    local origin = et.gentity_get(clientNum, "ps.origin")
    local angles = et.gentity_get(clientNum, "ps.viewangles")
    local eye = { origin[1], origin[2], origin[3] + (et.gentity_get(clientNum, "ps.viewheight") or 0) }
    local pitch, yaw = math.rad(angles[1]), math.rad(angles[2])
    local forward = { math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), -math.sin(pitch) }
    local finish = {
        eye[1] + forward[1] * SPRAY_RANGE,
        eye[2] + forward[2] * SPRAY_RANGE,
        eye[3] + forward[3] * SPRAY_RANGE,
    }
    local tr = et.trap_Trace(eye, nil, nil, finish, clientNum, et.MASK_SOLID)
    if not tr or tr.fraction >= 1 or tr.startsolid then
        return refuse(clientNum, levelTime, "get closer to a wall or the floor.")
    end
    if tr.entityNum ~= ENTITYNUM_WORLD or (tr.surfaceFlags & (SURF_SKY | SURF_NOMARKS)) ~= 0 then
        return refuse(clientNum, levelTime, "you can't spray here.")
    end

    -- image up: world up on walls; away from the player on floors and ceilings
    local n = tr.plane.normal
    local up
    if math.abs(n[3]) < 0.7 then
        up = { 0, 0, 1 }
    else
        up = { forward[1], forward[2], 0 }
    end

    local center, half = fitGraffiti(tr.endpos, n, up, clientNum)
    if not center then
        return refuse(clientNum, levelTime, "not enough room here - find a bigger, flatter wall.")
    end

    local cmd = string.format("fbspray %d %s %.1f %.1f %.1f %.4f %.4f %.4f %.4f %.4f %.4f %.1f",
        clientNum, design, center[1], center[2], center[3], n[1], n[2], n[3], up[1], up[2], up[3], half)
    et.trap_SendServerCommand(-1, cmd .. " 1")
    sprays[clientNum] = cmd .. " 0"
    usedThisLife[clientNum] = true
    et.G_LogPrint(string.format("%s: spray %d %s %s\n", MODNAME, clientNum, guidOf(clientNum), design))
end

function et_InitGame(levelTime, randomSeed, restart)
    et.RegisterModname(MODNAME .. " " .. VERSION)
    loadoutPath = et.trap_Cvar_Get("fs_homepath") .. "/legacy/fatboss_loadouts.json"
    loadoutUrl = os.getenv("FATBOSS_LOADOUT_URL")
    apiToken = os.getenv("FATBOSS_API_TOKEN")
    readLoadouts()
    fetchLoadouts()
    nextFetch = levelTime + FETCH_MS
    nextRead = levelTime + READ_MS
end

-- download every minute, pick up the downloaded file every few seconds
function et_RunFrame(levelTime)
    if levelTime >= nextFetch then
        nextFetch = levelTime + FETCH_MS
        fetchLoadouts()
    end
    if levelTime >= nextRead then
        nextRead = levelTime + READ_MS
        readLoadouts()
    end
end

function et_ClientCommand(clientNum, command)
    if string.lower(command or "") ~= "spray" then
        return 0
    end
    spray(clientNum)
    return 1
end

-- a full respawn starts a new life; a revive does not
function et_ClientSpawn(clientNum, revived, teamChange, restoreHealth)
    if revived ~= 1 then
        usedThisLife[clientNum] = nil
    end
end

-- late joiners get the graffiti already on the map, without the sound
function et_ClientBegin(clientNum)
    for _, cmd in pairs(sprays) do
        et.trap_SendServerCommand(clientNum, cmd)
    end
end

function et_ClientDisconnect(clientNum)
    usedThisLife[clientNum] = nil
    lastMessage[clientNum] = nil
end
