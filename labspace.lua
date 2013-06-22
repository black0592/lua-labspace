-- labspace 1.0
-- Copyright (C) 2011 Gunnar Beutner
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

-- TODO
-- logging
-- make idle notifications independent from game delay

-- Ideas:
-- scientists vote on kills

local BOTNICK = "labspace"
local BOTACCOUNT = "labspace"
local BOTACCOUNTID = 5022574
local BOTCHANNELS = { "#labspace" }
local MINPLAYERS = 6
local MAXPLAYERS = 30
local DEBUG = false
local DB = "labspace.db"

local KILLMESSAGES = {
  "was brutally murdered.",
  "was vaporized by the scientist's death ray.",
  "slipped into a coma after drinking their poison-laced morning coffee.",
  "was crushed to death by a 5-ton boulder.",
  "couldn't escape from the scientist's killbot army."
}

local ls_bot
local ls_gamestate = {}
local ls_db = {}
local ls_lastsave = 0
local ls_lastalivecheck = 0
local ls_sched = Scheduler()

function onload()
  ls_dbload()
  onconnect()
end

function onunload()
  ls_dbsave()
end

function onconnect()
  ls_bot = irc_localregisteruserid(BOTNICK, "lab", "space", "Labspace", BOTACCOUNT, BOTACCOUNTID, "+iXr", handler)
  ls_join_channels()
end

function ls_join_channels()
  for _, channel in pairs(BOTCHANNELS) do
    ls_add_channel(channel)
  end

  for _, channel in pairs(ls_db.channels) do
    if not ls_is_game_channel(channel) then
      ls_add_channel(channel)
    end
  end
end

function ls_split_message(message)
  message, _ = message:gsub("^ +", "")
  message, _ = message:gsub("  +", " ")
  message, _ = message:gsub(" +$", "")

  local tokens = {}

  for token in string.gmatch(message, "%S+") do
    table.insert(tokens, token)
  end

  return tokens
end

function handler(target, revent, ...)
  if revent == "irc_onchanmsg" then
    local numeric, channel, message = ...

    if not ls_is_game_channel(channel) then
      return
    end

    ls_keepalive(channel, numeric)

    local tokens = ls_split_message(message)
    local command = tokens[1]

    if command then
      if command == "!add" then
        ls_cmd_add(channel, numeric)
      elseif command == "!remove" then
        ls_cmd_remove(channel, numeric)
      elseif command == "!wait" then
        ls_cmd_wait(channel, numeric)
      elseif command == "!start" then
        ls_cmd_start(channel, numeric)
      elseif command == "!status" then
        ls_cmd_status(channel, numeric)
      elseif command == "!hl" then
        ls_cmd_hl(channel, numeric)
      elseif command == "!enable" then
        ls_cmd_enable(channel, numeric)
      elseif command == "!disable" then
        ls_cmd_disable(channel, numeric)
      end

      ls_flush_modes(channel)
    end
  elseif revent == "irc_onmsg" or revent == "irc_onnotice" then
    local numeric, message = ...

    local tokens = ls_split_message(message)

    local command = tokens[1]
    local argument = tokens[2]

    if command then
      if command == "kill" then
        ls_cmd_kill(numeric, argument)
      elseif command == "investigate" then
        ls_cmd_investigate(numeric, argument)
      elseif command == "vote" then
        ls_cmd_vote(numeric, argument)
      elseif command == "guard" then
        ls_cmd_guard(numeric, argument)
      elseif command == "smite" and onstaff(numeric) then
        ls_cmd_smite(numeric, argument)
      elseif command == "addchan" and ontlz(numeric) then
        ls_cmd_addchan(numeric, argument)
      elseif command == "delchan" and ontlz(numeric) then
        ls_cmd_delchan(numeric, argument)
      end
    end
  elseif revent == "irc_onkilled" then
    ls_bot = nil
    ls_gamestate = {}
  elseif revent == "irc_onkillreconnect" then
    local numeric = ...

    if numeric then
      ls_bot = numeric
      ls_join_channels()
    end
  end
end

function irc_onpart(channel, numeric, message)
  if not ls_is_game_channel(channel) then
    return
  end

  if ls_get_role(channel, numeric) then
    ls_remove_player(channel, numeric)
    ls_advance_state(channel)
  end
end

function irc_onkick(channel, kicked_numeric, kicker_numeric, message)
  if not ls_is_game_channel(channel) then
    return
  end

  if ls_bot == kicked_numeric then
    ls_remove_channel(channel)
    return
  end

  if ls_get_role(channel, kicked_numeric) then
    ls_remove_player(channel, kicked_numeric)
    ls_advance_state(channel)
  end
end
irc_onkickall = irc_onkick

function irc_onquit(numeric)
  for channel, _ in pairs(ls_gamestate) do
    if ls_get_role(channel, numeric) then
      ls_remove_player(channel, numeric)
      ls_advance_state(channel)
    end
  end
end

function ontick()
  for channel, _ in pairs(ls_gamestate) do
    ls_advance_state(channel, true)
    ls_flush_modes(channel)
  end

  if ls_lastalivecheck < os.time() - 30 then
    ls_lastalivecheck = os.time()

    for channel, _ in pairs(ls_gamestate) do
      ls_check_alive(channel)
    end
  end

  if ls_lastsave < os.time() - 60 then
    ls_lastsave = os.time()
    ls_dbsave()
  end
end

-- sends a debug message
function ls_debug(channel, message)
  if DEBUG then
    irc_localchanmsg(ls_bot, channel, "DEBUG: " .. message)
  end
end

-- sends a notice to the specified target
function ls_notice(numeric, text)
  irc_localnotice(ls_bot, numeric, text)
end

-- sends a message to the specified target
function ls_chanmsg(channel, text)
  irc_localchanmsg(ls_bot, channel, text)
end

-- formats the specified role identifier for output in a message
function ls_format_role(role)
  if role == "scientist" then
    return "Mad Scientist"
  elseif role == "investigator" then
    return "Investigator"
  elseif role == "citizen" then
    return "Citizen"
  elseif role == "lobby" then
    return "Lobby"
  else
    return "Unknown Role"
  end
end

-- formats the specified player name for output in a message (optionally
-- revealing that player's role in the game)
function ls_format_player(channel, numeric, reveal)
  local nick = irc_getnickbynumeric(numeric)
  local result = "\002" .. nick.nick .. "\002"

  if reveal then
    result = result .. " (" .. ls_format_role(ls_get_role(channel, numeric)) .. ")"
  end

  return result
end

-- formats a list of player names for output in a message (optionally
-- revealing their roles in the game)
function ls_format_players(channel, numerics, reveal, no_and)
  local i = 0
  local result = ""

  for _, numeric in pairs(numerics) do
    if i ~= 0 then
      if not no_and and i == table.getn(numerics) - 1 then
        result = result .. " and "
      else
        result = result .. ", "
     end
   end

   result = result .. ls_format_player(channel, numeric, reveal)
   i = i + 1
  end

  return result
end

-- returns the current state of the game
function ls_get_state(channel)
  return ls_gamestate[channel]["state"]
end

-- gets the timeout for the current state
function ls_get_timeout(channel)
  return ls_gamestate[channel]["timeout"]
end

-- gets the delay for the current state
function ls_get_delay(channel)
  return ls_gamestate[channel]["delay"]
end

-- gets the ts when !hl was last used
function ls_get_lasthl(channel)
  return ls_gamestate[channel]["lasthl"]
end

-- gets whether the bot is enabled
function ls_get_enabled(channel)
  return ls_gamestate[channel]["enabled"]
end

-- returns true if the game state delay was exceeded, false otherwise
function ls_delay_exceeded(channel)
  return ls_get_delay(channel) < os.time()
end

function ls_get_waitcount(channel)
  return ls_gamestate[channel]["waitcount"]
end

-- sets the game state
function ls_set_state(channel, state)
  ls_gamestate[channel]["state"] = state

  ls_set_timeout(channel, -1)
  ls_set_delay(channel, 30)
end

-- sets the game state timeout (in seconds)
function ls_set_timeout(channel, timeout)
  if timeout == -1 then
    ls_gamestate[channel]["timeout"] = -1
  else
    ls_gamestate[channel]["timeout"] = os.time() + timeout
  end
end

-- sets the game state delay (in seconds)
function ls_set_delay(channel, delay)
  ls_gamestate[channel]["delay"] = os.time() + delay
  ls_debug(channel, "changed gamestate delay to " .. delay)
end

-- sets the !hl timestamp
function ls_set_lasthl(channel, ts)
  ls_gamestate[channel]["lasthl"] = ts
end

-- sets whether the bot is enabled
function ls_set_enabled(channel, enabled)
  ls_gamestate[channel]["enabled"] = enabled
end

function ls_set_waitcount(channel, count)
  ls_gamestate[channel]["waitcount"] = count
end

-- returns true if the game state timeout was exceeded, false otherwise
function ls_timeout_exceeded(channel)
  local timeout = ls_get_timeout(channel)

  return timeout ~= -1 and timeout < os.time()
end

-- returns true if there's a game in progress, false otherwise
function ls_game_in_progress(channel)
  return ls_get_state(channel) ~= "lobby"
end

-- returns the name of the channel the specified nick is playing on
-- if the nick isn't playing any games nil is returned instead
function ls_chan_for_numeric(numeric)
  for channel, _ in pairs(ls_gamestate) do
    if ls_get_role(channel, numeric) then
      return channel
    end
  end

  return nil
end

function ls_cmd_add(channel, numeric)
  ls_add_player(channel, numeric)
end

function ls_cmd_remove(channel, numeric)
  ls_remove_player(channel, numeric)
end

function ls_cmd_wait(channel, numeric)
  if ls_game_in_progress(channel) then
    ls_notice(numeric, "Sorry, there's no lobby at the moment.")
    return
  end

  if table.getn(ls_get_players(channel)) >= MINPLAYERS then
    local count = ls_get_waitcount(channel)

    if count >= 2 then
      ls_notice(numeric, "Sorry, the timeout can only be extended twice per game.")
      return
    end

    ls_set_waitcount(channel, count + 1)
  end

  if not ls_get_role(channel, numeric) then
    ls_notice(numeric, "Sorry, you need to be in the lobby to use this command.")
    return
  end

  ls_set_timeout(channel, 120)
  ls_set_delay(channel, 45)

  ls_chanmsg(channel, "Lobby timeout was reset.")
end

function ls_cmd_start(channel, numeric)
  if ls_game_in_progress(channel) then
    ls_notice(numeric, "Sorry, there's no lobby at the moment.")
    return
  end

  if not ls_get_role(channel, numeric) then
    ls_notice(numeric, "Sorry, you need to be in the lobby to use this command.")
    return
  end

  ls_advance_state(channel)

  ls_flush_modes(channel)
end

function ls_cmd_status(channel, numeric)
  if not ls_get_role(channel, numeric) then
    ls_notice(numeric, "Sorry, you need to be in the lobby to use this command.")
    return
  end

  ls_chanmsg(channel, "Players: " .. ls_format_players(channel, ls_get_players(channel)))

  if ls_game_in_progress(channel) then
    ls_chanmsg(channel, "Roles: " ..
      table.getn(ls_get_players(channel, "scientist")) .. "x " .. ls_format_role("scientist") .. ", " ..
      table.getn(ls_get_players(channel, "investigator")) .. "x " .. ls_format_role("investigator") .. ", " ..
      table.getn(ls_get_players(channel, "citizen")) .. "x " .. ls_format_role("citizen"))
  end
end

function ls_cmd_hl(channel, numeric)
  if ls_game_in_progress(channel) then
    ls_notice(numeric, "Sorry, there's no lobby at the moment.")
    return
  end

  if not ls_get_role(channel, numeric) then
    ls_notice(numeric, "Sorry, you need to be in the lobby to use this command.")
    return
  end

  if ls_get_lasthl(channel) > os.time() - 300 then
    ls_notice(numeric, "Sorry, you can only use that command once every 5 minute.")
    return
  end

  if string.lower(channel) ~= "#labspace" then
    ls_notice(numeric, "Sorry, you can't use this command here.")
    return
  end

  ls_set_lasthl(channel, os.time())

  local numerics = {}

  for nick in channelusers_iter(channel, { nickpusher.numeric }) do
    local numeric = nick[1]

    if not ls_get_role(channel, numeric) then
      table.insert(numerics, numeric)
    end

    if table.getn(numerics) > 10 then
      ls_chanmsg(channel, "HL: " .. ls_format_players(channel, numerics, false, true))
      numerics = {}
    end
  end

  if table.getn(numerics) > 0 then
    ls_chanmsg(channel, "HL: " .. ls_format_players(channel, numerics, false, true))
  end
end

function ls_cmd_enable(channel, numeric)
  local chanuser = irc_getuserchanmodes(numeric, channel)

  if not chanuser or not chanuser.opped then
    ls_notice(channel, "You need to be opped to use this command.")
    return
  end

  ls_set_enabled(channel, true)
  ls_notice(numeric, "Game has been enabled.")
end

function ls_cmd_disable(channel, numeric)
  local chanuser = irc_getuserchanmodes(numeric, channel)

  if not chanuser or not chanuser.opped then
    ls_notice(channel, "You need to be opped to use this command.")
    return
  end

  if ls_game_in_progress(channel) then
    ls_chanmsg(channel, ls_format_player(channel, numeric) .. " disabled the game.")
  end

  ls_stop_game(channel)
  ls_flush_modes(channel)

  ls_set_enabled(channel, false)
  ls_notice(numeric, "Game has been disabled.")
end

function ls_cmd_kill(numeric, victim)
  if not victim then
    ls_notice(numeric, "Syntax: kill <nick>")
    return
  end

  local channel = ls_chan_for_numeric(numeric)

  if not channel then
    ls_notice(numeric, "You haven't joined any game lobby.")
    return
  end

  ls_keepalive(channel, numeric)

  if ls_get_role(channel, numeric) ~= "scientist" then
    ls_notice(numeric, "You need to be a scientist to use this command.")
    return
  end

  if ls_get_state(channel) ~= "kill" then
    ls_notice(numeric, "Sorry, you can't use this command right now.")
    return
  end

  if not ls_get_active(channel, numeric) then
    ls_notice(numeric, "Sorry, it's not your turn to choose a victim.")
    return
  end

  local victimnick = irc_getnickbynick(victim)

  if not victimnick then
    ls_notice(numeric, "Sorry, I don't know who that is.")
    return
  end

  local victimnumeric = victimnick.numeric

  if not ls_get_role(channel, victimnumeric) then
    ls_notice(numeric, "Sorry, " .. ls_format_player(channel, victimnumeric) .. " isn't playing the game.")
    return
  end

  if math.random(100) > 85 then
    ls_chanmsg(channel, "The scientists' attack was not successful tonight. Nobody died.")
  elseif ls_get_guarded(channel, victimnumeric) then
    for _, player in pairs(ls_get_players(channel)) do
      ls_set_trait(channel, player, "force", false)
    end
    
    ls_set_guarded(channel, victimnumeric, false)

    ls_chanmsg(channel, "The attack on " .. ls_format_player(channel, victimnumeric) .. " was deflected by a force field. The force field generator has now run out of power.")
  elseif ls_get_trait(channel, victimnumeric, "infested") then
    ls_devoice_player(channel, numeric)
    ls_devoice_player(channel, victimnumeric)
    
    ls_remove_player(channel, numeric, true)
    ls_remove_player(channel, victimnumeric, true)

    ls_chanmsg(channel, "An alien bursts out of " .. ls_format_player(channel, victimnumeric, true) .. "'s chest just as " .. ls_format_player(channel, numeric, true) .. " was about to murder them, killing them both.")
  else
    ls_devoice_player(channel, victimnumeric)

    if numeric == victimnumeric then
      ls_chanmsg(channel, ls_format_player(channel, victimnumeric, true) .. " committed suicide.")
    else
      if ls_get_role(channel, victimnumeric) == "scientist" then
        ls_chanmsg(channel, ls_format_player(channel, victimnumeric, true) .. " was brutally murdered. Oops.")
      else
        local killmessage = KILLMESSAGES[math.random(table.getn(KILLMESSAGES))]

        ls_chanmsg(channel, ls_format_player(channel, victimnumeric, true) .. " " .. killmessage)
      end
    end

    ls_remove_player(channel, victimnumeric, true)
  end

  ls_set_state(channel, "investigate")
  ls_advance_state(channel)

  ls_flush_modes(channel)
end

function ls_cmd_investigate(numeric, victim)
  if not victim then
    ls_notice(numeric, "Syntax: investigate <nick>")
    return
  end

  local channel = ls_chan_for_numeric(numeric)

  if not channel then
    ls_notice(numeric, "You haven't joined any game lobby.")
    return
  end

  if ls_get_role(channel, numeric) ~= "investigator" then
    ls_notice(numeric, "You need to be an investigator to use this command.")
    return
  end

  ls_keepalive(channel, numeric)

  if ls_get_state(channel) ~= "investigate" then
    ls_notice(numeric, "Sorry, you can't use this command right now.")
    return
  end

  local victimnick = irc_getnickbynick(victim)

  if not victimnick then
    ls_notice(numeric, "Sorry, I don't know who that is.")
    return
  end

  local victimnumeric = victimnick.numeric

  if not ls_get_role(channel, victimnumeric) then
    ls_notice(numeric, "Sorry, " .. ls_format_player(channel, victimnumeric) .. " isn't playing the game.")
    return
  end

  local investigators = ls_get_players(channel, "investigator")

  for _, investigator in pairs(investigators) do
    if investigator ~= numeric then
      ls_notice(investigator, "Another investigator picked a target.")
    end
  end

  if math.random(100) > 85 then
    ls_chanmsg(channel, ls_format_player(channel, numeric) .. "'s fine detective work reveals " .. ls_format_player(channel, victimnumeric) .. "'s role: " .. ls_format_role(ls_get_role(channel, victimnumeric)))
  end

  if numeric == victimnumeric then
    ls_notice(numeric, "You're the investigator. Excellent detective work!")
  else
    ls_notice(numeric, ls_format_player(channel, victimnumeric) .. "'s role is: " .. ls_format_role(ls_get_role(channel, victimnumeric)))
  end

  ls_set_state(channel, "vote")
  ls_advance_state(channel)

  ls_flush_modes(channel)
end

function ls_cmd_vote(numeric, victim)
  if not victim then
    ls_notice(numeric, "Syntax: vote <nick>")
    return
  end

  local channel = ls_chan_for_numeric(numeric)

  if not channel then
    ls_notice(numeric, "You haven't joined any game lobby.")
    return
  end

  if ls_get_state(channel) ~= "vote" then
    ls_notice(numeric, "Sorry, you can't use this command right now.")
    return
  end

  ls_keepalive(channel, numeric)

  local victimnick = irc_getnickbynick(victim)

  if not victimnick then
    ls_notice(numeric, "Sorry, I don't know who that is.")
    return
  end

  local victimnumeric = victimnick.numeric

  if not ls_get_role(channel, victimnumeric) then
    ls_notice(numeric, "Sorry, " .. ls_format_player(channel, victimnumeric) .. " isn't playing the game.")
    return
  end

  if ls_get_vote(channel, numeric) == victimnumeric then
    ls_notice(numeric, "You already voted for " .. ls_format_player(channel, victimnumeric) .. ".")
    return
  end

  ls_set_vote(channel, numeric, victimnumeric)
  ls_notice(numeric, "Done.")

  ls_advance_state(channel)

  ls_flush_modes(channel)
end

function ls_cmd_guard(numeric, victim)
  if not victim then
    ls_notice(numeric, "Syntax: vote <nick>")
    return
  end

  local channel = ls_chan_for_numeric(numeric)

  if not channel then
    ls_notice(numeric, "You haven't joined any game lobby.")
    return
  end

  if not ls_get_trait(channel, numeric, "force") then
    ls_notice(numeric, "Sorry, you need the force field generator to use this command.")
    return
  end

  ls_keepalive(channel, numeric)

  local victimnick = irc_getnickbynick(victim)

  if not victimnick then
    ls_notice(numeric, "Sorry, I don't know who that is.")
    return
  end

  local victimnumeric = victimnick.numeric

  if not ls_get_role(channel, victimnumeric) then
    ls_notice(numeric, "Sorry, " .. ls_format_player(channel, victimnumeric) .. " isn't playing the game.")
    return
  end
  
  local target
  
  if victimnumeric == numeric then
    target = "yourself"
  else
    target = ls_format_player(channel, victimnumeric)
  end
  
  for _, player in pairs(ls_get_players(channel)) do
    ls_set_guarded(channel, player, (player == victimnumeric))
  end
  
  ls_notice(numeric, "You are now protecting " .. target .. ".")
end

function ls_cmd_smite(numeric, victim)
  if not victim then
    ls_notice(numeric, "Syntax: smite <nick>")
    return
  end

  local victimnick = irc_getnickbynick(victim)

  if not victimnick then
    ls_notice(numeric, "Sorry, I don't know who that is.")
    return
  end

  local victimnumeric = victimnick.numeric
  local channel = ls_chan_for_numeric(victimnumeric)

  if not channel then
    ls_notice(numeric, "Sorry, " .. victimnick.nick .. " isn't playing the game.")
    return
  end

  ls_chanmsg(channel, ls_format_player(channel, victimnumeric, true) .. " was struck by lightning.")
  ls_remove_player(channel, victimnumeric, true)

  ls_advance_state(channel)

  ls_flush_modes(channel)
end

function ls_cmd_addchan(numeric, channel)
  if not channel then
    ls_notice(numeric, "Syntax: addchan <#channel>")
    return
  end

  if not irc_getchaninfo(channel) then
    ls_notice(numeric, "The specified channel does not exist.")
    return
  end

  if ls_is_game_channel(channel) then
    ls_notice(numeric, "The bot is already on that channel.")
    return
  end

  ls_add_channel(channel)

  ls_notice(numeric, "Done.")
end

function ls_cmd_delchan(numeric, channel)
  if not channel then
    ls_notice(numeric, "Syntax: delchan <#channel>")
    return
  end

  if not ls_is_game_channel(channel) then
    ls_notice(numeric, "The bot is not on that channel.")
    return
  end

  ls_remove_channel(channel, true)

  ls_notice(numeric, "Done.")
end

function ls_keepalive(channel, numeric)
  if ls_get_role(channel, numeric) then
    ls_set_seen(channel, numeric, os.time())
  end

  -- extend lobby timeout if we don't have enough players yet
  if ls_get_state(channel) == "lobby" and table.getn(ls_get_players(channel)) < MINPLAYERS then
    ls_set_delay(channel, 90)
    ls_set_timeout(channel, 150)
  end
end

function ls_timer_announce_players(channel)
  ls_gamestate[channel]["announce_timer"] = nil

  local new_players = {}

  for _, numeric in pairs(ls_get_players(channel)) do
    if not ls_get_announced(channel, numeric) then
      table.insert(new_players, numeric)
      ls_set_announced(channel, numeric, true)
      ls_voice_player(channel, numeric)
    end
  end

  ls_flush_modes(channel)

  if table.getn(new_players) > 0 then
    local count = table.getn(ls_get_players(channel))
    local subject

    if count ~= 1 then
      subject = "players"
    else
      subject = "player"
    end

    ls_chanmsg(channel, ls_format_players(channel, new_players) .. " joined the game (" .. count .. " " .. subject .. " in the lobby).")
  end
end

function ls_add_channel(channel)
  ls_gamestate[channel] = { players = {}, state = "lobby", timeout = -1, delay = os.time() + 30, waitcount = 0, lasthl = 0, enabled = true }
  irc_localjoin(ls_bot, channel)
  irc_localsimplechanmode(ls_bot, channel, "-m")
end

function ls_remove_channel(channel, part)
  if ls_gamestate[channel]["announce_timer"] then
    ls_sched:remove(ls_gamestate[channel]["announce_timer"])
  end

  ls_gamestate[channel] = nil

  if part then
    irc_localpart(ls_bot, channel)
  end
end

function ls_dbload()
  ls_db = loadtable(basepath() .. "db/" .. DB)

  if not ls_db then
    ls_db = ls_dbdefaults()
  end
end

function ls_dbsave()
  local channels = {}

  for channel, _ in pairs(ls_gamestate) do
    table.insert(channels, channel)
  end

  ls_db.channels = channels

  savetable(basepath() .. "db/" .. DB, ls_db)
end

function ls_dbdefaults()
  local db = {}
  db.channels = BOTCHANNELS

  return db
end

function ls_add_player(channel, numeric, forced)
  local role = ls_get_role(channel, numeric)

  if role then
    ls_chanmsg(channel, "\001ACTION slaps " .. ls_format_player(channel, numeric) .. "\001")
    return
  end

  if not forced then
    if not ls_get_enabled(channel) then
      ls_notice(numeric, "Sorry, the game is currently disabled.")
      return
    end

    if ls_game_in_progress(channel) then
      ls_notice(numeric, "Sorry, you can't join the game right now.")
      return
    end

    local chanuser = irc_getuserchanmodes(numeric, channel)

    if not chanuser then
      ls_notice(numeric, "Sorry, you must be on the channel to use this command.")
      return
    end

    if chanuser.opped then
      ls_notice(numeric, "You must not be opped to use this command.")
      return
    end

    if table.getn(ls_get_players(channel)) >= MAXPLAYERS then
      ls_notice(numeric, "Sorry, the game's lobby is full.")
      return 
    end

    if ls_chan_for_numeric(numeric) then
      ls_notice(numeric, "Sorry, you can't play on multiple channels at once.")
      return
    end
  end

  ls_set_role(channel, numeric, "lobby")
  ls_set_seen(channel, numeric, os.time())

  if not forced then
    ls_set_announced(channel, numeric, false)

    if ls_gamestate[channel]["announce_timer"] then
      ls_sched:remove(ls_gamestate[channel]["announce_timer"])
    end
    ls_gamestate[channel]["announce_timer"] = ls_sched:add(5, ls_timer_announce_players, channel)

    ls_notice(numeric, "You were added to the lobby.")
  else
    ls_set_announced(channel, numeric, true)
    ls_voice_player(channel, numeric)
  end

  ls_set_delay(channel, 30)
  ls_set_timeout(channel, 90)
end

function ls_voice_player(channel, numeric)
  if not ls_gamestate[channel]["modes"] then
    ls_gamestate[channel]["modes"] = {}
  end

  table.insert(ls_gamestate[channel]["modes"], true)
  table.insert(ls_gamestate[channel]["modes"], "v")
  table.insert(ls_gamestate[channel]["modes"], numeric)
end

function ls_devoice_player(channel, numeric)
  if not ls_gamestate[channel]["modes"] then
    ls_gamestate[channel]["modes"] = {}
  end

  table.insert(ls_gamestate[channel]["modes"], false)
  table.insert(ls_gamestate[channel]["modes"], "v")
  table.insert(ls_gamestate[channel]["modes"], numeric)
end

function ls_flush_modes(channel)
  if ls_gamestate[channel]["modes"] then
    irc_localovmode(ls_bot, channel, ls_gamestate[channel]["modes"]) 
    ls_gamestate[channel]["modes"] = nil
  end
end

function ls_remove_player(channel, numeric, forced)
  local role = ls_get_role(channel, numeric)

  if not role then
    return
  end

  local announced = ls_get_announced(channel, numeric)

  local force_field = ls_get_trait(channel, numeric, "force")
  
  ls_set_role(channel, numeric, nil)

  ls_devoice_player(channel, numeric)

  for _, player in pairs(ls_get_players(channel)) do
    if ls_get_vote(channel, player) == numeric then
      ls_set_vote(channel, player, nil)
    end
    
    if force_field then
      ls_set_guarded(channel, player, false)
    end
  end

  if not forced then
    if announced then
      if ls_game_in_progress(channel) then
        ls_chanmsg(channel, ls_format_player(channel, numeric) .. " committed suicide. Goodbye, cruel world.")
      else
        ls_chanmsg(channel, ls_format_player(channel, numeric) .. " left the game (" .. table.getn(ls_get_players(channel)) .. " players in the lobby).")
      end
    end

    ls_notice(numeric, "You were removed from the lobby.")

    ls_set_delay(channel, 30)
    ls_set_timeout(channel, 90)
  end
end

function ls_get_players(channel, role)
  local players = {}

  for player, _ in pairs(ls_gamestate[channel]["players"]) do
    if not role or ls_get_role(channel, player) == role then
      table.insert(players, player)
    end
  end

  return players
end

function ls_is_game_channel(channel)
  return ls_gamestate[channel]
end

function ls_get_role(channel, numeric)
  if not ls_gamestate[channel]["players"][numeric] then
    return nil
  end

  return ls_gamestate[channel]["players"][numeric]["role"]
end

function ls_set_role(channel, numeric, role)
  if not ls_gamestate[channel]["players"][numeric] or role == "lobby" then
    ls_gamestate[channel]["players"][numeric] = {
      active = false,
      announced = false,
      traits = {},
      guarded = false
    }
  end

  if role then
    ls_gamestate[channel]["players"][numeric]["role"] = role
  else
    ls_gamestate[channel]["players"][numeric] = nil
  end

  if role and role ~= "lobby" then
    ls_notice(numeric, "Your role for this round is '" .. ls_format_role(role) .. "'.")
  end
end

function ls_get_trait(channel, numeric, trait)
  return ls_gamestate[channel]["players"][numeric]["traits"][trait]
end

function ls_set_trait(channel, numeric, trait, enabled)
  ls_gamestate[channel]["players"][numeric]["traits"][trait] = enabled
end

function ls_get_guarded(channel, numeric, guarded)
  return ls_gamestate[channel]["players"][numeric]["guarded"]
end

function ls_set_guarded(channel, numeric, guarded)
  ls_gamestate[channel]["players"][numeric]["guarded"] = guarded
end

function ls_get_seen(channel, numeric)
  return ls_gamestate[channel]["players"][numeric]["seen"]
end

function ls_set_seen(channel, numeric, seen)
  ls_gamestate[channel]["players"][numeric]["seen"] = seen
end

function ls_get_vote(channel, numeric)
  if not ls_gamestate[channel]["players"][numeric] then
    return nil
  end

  return ls_gamestate[channel]["players"][numeric]["vote"]
end

function ls_set_vote(channel, numeric, votenumeric)
  if ls_get_vote(channel, numeric) == votenumeric then
    return
  end

  if votenumeric then
    local count = 0
    for _, player in pairs(ls_get_players(channel)) do
      if ls_get_vote(channel, player) == votenumeric then
        count = count + 1
      end
    end

    -- increase count for this new vote
    count = count + 1

    if numeric ~= votenumeric then
      if ls_get_vote(channel, numeric) then
        ls_chanmsg(channel, ls_format_player(channel, numeric) .. " changed their vote to " .. ls_format_player(channel, votenumeric) .. " (" .. count .. " votes).")
      else
        ls_chanmsg(channel, ls_format_player(channel, numeric) .. " voted for " .. ls_format_player(channel, votenumeric) .. " (" .. count .. " votes).")
      end
    else
      ls_chanmsg(channel, ls_format_player(channel, numeric) .. " voted for himself. Oops! (" .. count .. " votes)")
    end
  end

  if ls_gamestate[channel]["players"][numeric] then
    ls_gamestate[channel]["players"][numeric]["vote"] = votenumeric
  end
end

function ls_get_active(channel, numeric)
  return ls_gamestate[channel]["players"][numeric]["active"]
end

function ls_set_active(channel, numeric, active)
  ls_gamestate[channel]["players"][numeric]["active"] = active
end

function ls_get_announced(channel, numeric)
  return ls_gamestate[channel]["players"][numeric]["announced"]
end

function ls_set_announced(channel, numeric, announced)
  ls_gamestate[channel]["players"][numeric]["announced"] = announced
end

function ls_pick_player(players)
  return players[math.random(table.getn(players))]
end

function ls_number_scientists(numPlayers)
  return math.ceil((numPlayers - 2) / 5.0)
end

function ls_number_investigators(numPlayers)
  return math.ceil((numPlayers - 5) / 6.0)
end

function ls_start_game(channel)
  local players = ls_get_players(channel)

  irc_localsimplechanmode(ls_bot, channel, "+m")
  
  for nick in channelusers_iter(channel, { nickpusher.numeric }) do
    local numeric = nick[1]

    if ls_get_role(channel, numeric) then
      ls_voice_player(channel, numeric)
      ls_keepalive(channel, numeric)
    else
      ls_devoice_player(channel, numeric)
    end
  end

  ls_chanmsg(channel, "Starting the game...")

  for _, player in pairs(players) do
    ls_set_role(channel, player, "lobby")
  end

  local players_count = table.getn(players)
  local scientists_count = 0
  local scientists_needed = ls_number_scientists(players_count)

  -- pick scientists
  while scientists_count < scientists_needed do
    local scientist_index = math.random(table.getn(players))
    ls_set_role(channel, table.remove(players, scientist_index), "scientist")
    scientists_count = scientists_count + 1
  end

  -- notify scientists about each other
  for _, scientist in pairs(ls_get_players(channel, "scientist")) do
    for _, scientist_notify in pairs(ls_get_players(channel, "scientist")) do
      if scientist ~= scientist_notify then
        ls_notice(scientist_notify, ls_format_player(channel, scientist) .. " is also a scientist.")
      end
    end
  end

  local investigators_count = 0
  local investigators_needed = ls_number_investigators(players_count)

  -- pick investigators
  while investigators_count < investigators_needed do
    local investigator_index = math.random(table.getn(players))
    ls_set_role(channel, table.remove(players, investigator_index), "investigator")
    investigators_count = investigators_count + 1
  end

  -- rest of the players are citizens
  for _, player in pairs(players) do
    ls_set_role(channel, player, "citizen")
  end
  
  -- give someone the force field generator
  local force_owner = players[math.random(table.getn(players))]
  ls_set_trait(channel, force_owner, "force", true)
  ls_set_guarded(channel, force_owner, true)
  ls_notice(force_owner, "You've found the \002force field generator\002. Use /notice " .. BOTNICK .. " guard <nick> to protect someone.")
  ls_notice(force_owner, "You are currently protecting yourself.")

  -- make someone infested if there are at least 6 citizens
  if table.getn(players) > 6 then
    local infested_player = players[math.random(table.getn(players))]
    ls_set_trait(channel, infested_player, "infested", true)
    ls_notice(infested_player, "You're infested with an \002alien parasite\002.")
    ls_chanmsg(channel, "It's " .. ls_format_player(channel, infested_player) .. ".")
  end
  
  ls_chanmsg(channel, "Roles have been assigned: " ..
    table.getn(ls_get_players(channel, "scientist")) .. "x " .. ls_format_role("scientist") .. ", " ..
    table.getn(ls_get_players(channel, "investigator")) .. "x " .. ls_format_role("investigator") .. ", " ..
    table.getn(ls_get_players(channel, "citizen")) .. "x " .. ls_format_role("citizen") .. " - Good luck!")

  ls_set_state(channel, "kill")
  ls_advance_state(channel)
end

function ls_stop_game(channel)
  ls_set_state(channel, "lobby")
  ls_set_waitcount(channel, 0)

  for _, player in pairs(ls_get_players(channel)) do
    ls_remove_player(channel, player, true)
  end

  irc_localsimplechanmode(ls_bot, channel, "-m")
end

-- makes sure people are not afk
function ls_check_alive(channel)
  if not ls_game_in_progress(channel) then
    return
  end

  local dead_players = {}
  local idle_players = {}

  for _, player in pairs(ls_get_players(channel)) do
    local seen = ls_get_seen(channel, player)

    if seen then
      if seen < os.time() - 120 then
        table.insert(dead_players, player)
      elseif seen < os.time() - 60 then
        table.insert(idle_players, player)
      end
    end
  end

  if table.getn(dead_players) > 0 then
    local verb

    if table.getn(dead_players) ~= 1 then
      verb = "seem"
    else
      verb = "seems"
    end

    ls_chanmsg(channel, ls_format_players(channel, dead_players) .. " " .. verb .. " to be dead (AFK).")

    for _, player in pairs(dead_players) do
      ls_remove_player(channel, player, true)
    end
  end

  if table.getn(idle_players) > 0 then
    ls_chanmsg(channel, "Hi " .. ls_format_players(channel, idle_players) .. ", please say something if you're still alive.")
  end
end

function ls_advance_state(channel, delayed)
  if delayed and not ls_delay_exceeded(channel) then
    return
  end

  ls_debug(channel, "ls_advance_state")

  ls_set_delay(channel, 30)

  local players = ls_get_players(channel)
  local scientists = ls_get_players(channel, "scientist")
  local investigators = ls_get_players(channel, "investigator")

  -- game start condition
  if not ls_game_in_progress(channel) then
    if table.getn(players) < MINPLAYERS then
      if table.getn(players) > 0 then
        if ls_timeout_exceeded(channel) then
          ls_chanmsg(channel, "Lobby was closed because there aren't enough players.")
          ls_stop_game(channel)
        else
          ls_chanmsg(channel, "Game will start when there are at least " .. MINPLAYERS .. " players.")
        end
      end
    else
      ls_start_game(channel)
    end

    return
  end

  -- winning condition when everyone is dead
  if table.getn(players) == 0 then
    ls_chanmsg(channel, "Everyone is dead.")
    ls_stop_game(channel)
    return 
  end

  -- winning condition for scientists
  if table.getn(scientists) >= table.getn(players) - table.getn(scientists) then
    ls_chanmsg(channel, "There are equal to or more scientists than citizens. Science wins again: " .. ls_format_players(channel, scientists, true))
    ls_stop_game(channel)
    return
  end

  -- winning condition for citizen
  if table.getn(scientists) == 0 then
    ls_chanmsg(channel, "All scientists have been eliminated. The citizens win this round: " .. ls_format_players(channel, players, true))
    ls_stop_game(channel)
    return
  end

  -- make sure there's progress towards the game's end
  local state = ls_get_state(channel)
  local timeout = ls_get_timeout(channel)

  if state == "kill" then
    if timeout == -1 then
      local active_scientist = scientists[math.random(table.getn(scientists))]

      for _, scientist in pairs(scientists) do
        if scientist == active_scientist then
          ls_set_active(channel, scientist, true)
          ls_notice(scientist, "It's your turn to select a citizen to kill. Use /notice " .. BOTNICK .. " kill <nick> to kill someone.")
        else
          ls_set_active(channel, scientist, false)
          ls_notice(scientist, ls_format_player(channel, active_scientist) .. " is choosing a victim.")
        end
      end

      if table.getn(scientists) > 1 then
        ls_chanmsg(channel, "The citizens are asleep while the mad scientists are choosing a target.")
      else
        ls_chanmsg(channel, "The citizens are asleep while the mad scientist is choosing a target.")
      end

      ls_set_timeout(channel, 120)
    elseif ls_timeout_exceeded(channel) then
      ls_chanmsg(channel, "The scientists failed to set their alarm clocks. Nobody dies tonight.")
      ls_set_state(channel, "investigate")
      ls_advance_state(channel)
    else
      ls_chanmsg(channel, "The scientists still need to pick someone to kill.")
    end
  end

  if state == "investigate" then
    -- the investigators are already dead
    if table.getn(investigators) == 0 then
      ls_set_state(channel, "vote")
      ls_advance_state(channel)
      return
    end

    if timeout == -1 then
      local active_investigator = investigators[math.random(table.getn(investigators))]

      for _, investigator in pairs(investigators) do
        if investigator == active_investigator then
          ls_set_active(channel, investigator, true)
          ls_notice(investigator, "You need to choose someone to investigate: /notice " .. BOTNICK .. " investigate <nick>")
        else
          ls_set_active(channel, investigator, false)
          ls_notice(investigator, "Another investigator is choosing a target.")
        end
      end

      if table.getn(investigators) > 1 then
        ls_chanmsg(channel, "It's now up to the investigators to find the mad scientists.")
      else
        ls_chanmsg(channel, "It's now up to the investigator to find the mad scientists.")
      end

      ls_set_timeout(channel, 120)
    elseif ls_timeout_exceeded(channel) then
      ls_chanmsg(channel, "Looks like the investigator is still firmly asleep.")
      ls_set_state(channel, "vote")
      ls_advance_state(channel)
    else
      ls_chanmsg(channel, "The investigator still needs to do their job.");
    end
  end

  if state == "vote" then
    local missing_votes = {}

    for _, player in pairs(players) do
      if not ls_get_vote(channel, player) then
        table.insert(missing_votes, player)
      end
    end

    if timeout == -1 then
      for _, player in pairs(players) do
        ls_set_vote(channel, player, nil)
      end

      ls_chanmsg(channel, "It's now up to the citizens to vote who to lynch (via /notice " .. BOTNICK .. " vote <nick>).")
      ls_set_timeout(channel, 120)
    elseif ls_timeout_exceeded(channel) or table.getn(missing_votes) == 0 then
      local votes = {}
      local votees = {}

      for _, player in pairs(players) do
        local vote = ls_get_vote(channel, player)

        if vote then
          if not votes[vote] then
            votes[vote] = 0
            table.insert(votees, vote)
          end

          votes[vote] = votes[vote] + 1
        end
      end

      local function votecomp(v1, v2)
        if votes[v1] > votes[v2] then
          return true
        end
      end

      table.sort(votees, votecomp)

      local message_suffix, candidates

      if table.getn(votees) > 0 then
        local message = ""

        for _, votee in pairs(votees) do
          if message ~= "" then
            message = message .. ", "
          end

          message = message .. votes[votee] .. "x " .. ls_format_player(channel, votee)
        end

        ls_chanmsg(channel, "Votes: " .. message)

        local most_votes = votes[votees[1]]
        candidates = {}

        for _, votee in pairs(votees) do
          if votes[votee] == most_votes then
            table.insert(candidates, votee)
          end
        end

        message_suffix = "was lynched by the angry mob."
      else
        candidates = players
        message_suffix = "was hit by a stray high-energy laser beam."
      end

      local victim_index = math.random(table.getn(candidates))
      local victim = candidates[victim_index]

      ls_devoice_player(channel, victim)

      ls_chanmsg(channel, ls_format_player(channel, victim, true) .. " " .. message_suffix)
      ls_remove_player(channel, victim, true)

      ls_set_state(channel, "kill")
      ls_advance_state(channel)
    elseif delayed then
      ls_chanmsg(channel, "Some of the citizens still need to vote: " .. ls_format_players(channel, missing_votes))
    end
  end
end
