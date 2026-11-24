local _, R = ...
local Framing = {}
R.Framing = Framing

function Framing:ViewLabel()
    local distance = R.Adapter:Distance()
    if not distance then return "Camera distance unavailable" end
    if distance == 0 then return "First person" end
    return string.format("Third person  ·  distance %.1f", distance)
end

-- The release-matched command catalogue distinguishes a native graphics command
-- from a CVar, macro, or script. Cache only the lookup, never the player's choice.
local commandListed
local function findModelCommand()
    if not Enum or not Enum.ConsoleCategory or type(Enum.ConsoleCategory.Graphics) ~= "number"
        or not Enum.ConsoleCommandType or type(Enum.ConsoleCommandType.Command) ~= "number"
        or type(ConsoleGetAllCommands) ~= "function" then return false end
    local commands = ConsoleGetAllCommands()
    if type(commands) ~= "table" then return false end
    for _, entry in ipairs(commands) do
        if entry.category == Enum.ConsoleCategory.Graphics and entry.commandType == Enum.ConsoleCommandType.Command
            and type(entry.command) == "string" and entry.command:lower() == "showplayer" then
            return true
        end
    end
    return false
end

function Framing:Available()
    if R.Engine:State() ~= "idle" or R.Adapter:DisplayShown() ~= true then
        return nil, "Show the interface and finish the current take first."
    end
    local allowed, reason = R.Engine:Allowed(true)
    if not allowed then return nil, reason end
    if not ChatFrameUtil or type(ChatFrameUtil.OpenChat) ~= "function" then
        return nil, "The game chat editor is unavailable."
    end
    if commandListed == nil then
        local ok, listed = pcall(findModelCommand)
        commandListed = ok and listed == true
    end
    if not commandListed then return nil, "This client did not list the character visibility command." end
    return true
end

-- Hand the exact command to the player in the game's own edit box. Only the
-- player's Enter applies it. There is no reliable world-model state readback
-- for CineRig to snapshot or restore when another caller changes visibility.
function Framing:Prepare(visible)
    if type(visible) ~= "boolean" then return nil, "Choose Hide character or Show character." end
    local ok, reason = self:Available()
    if not ok then return nil, reason end
    if ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow() then
        return nil, "Close your current chat entry first."
    end
    local command = visible and "/console showPlayer 1" or "/console showPlayer 0"
    ok = pcall(ChatFrameUtil.OpenChat, command, DEFAULT_CHAT_FRAME)
    if not ok then return nil, "Could not open chat. Enter " .. command .. " manually." end
    return true, "Press Enter in game chat to apply, or Escape to cancel."
end
