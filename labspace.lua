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
-- vote info in !status
-- canonicalize channel names (or figure out if lua has case-insensitive dicts)

-- Ideas:
-- scientists vote on kills

local BOTNICK = "labspace"
local BOTACCOUNT = "labspace"
local BOTACCOUNTID = 5022574
local HOMECHANNEL = "#labspace"
local MINPLAYERS = 6
local MAXPLAYERS = 30
local DEBUG = false
local DB = "labspace.db"

local KILLMESSAGES = {
  "was brutally murdered.",
  "was vaporized by the scientist's death ray.",
  "slipped into a coma after drinking their poison-laced morning coffee.",
  "was crushed to death by a 5-ton boulder.",
  "couldn't escape from the scientist's killbot army.",
  "was torn apart by a group of ferocious labrats.",
  "was sucked into an artificial black hole.",
  "took a bath in concentrated sulfuric acid."
}

local ls_bot
local ls_hlbot
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
  ls_bot = irc_localregisteruserid(BOTNICK, "labspace", "brought.to.you.by.science", "For science!", BOTACCOUNT, BOTACCOUNTID, "+iXr", gamehandler)
  ls_join_channels()
  
  ls_hlbot = irc_localregisteruser("hl-" .. BOTNICK, "will.spam", "for.food", "Got some change?", "labspace-hl", "+iX", highlighthandler)
  irc_localjoin(ls_hlbot, HOMECHANNEL)
end

function ls_join_channels()
  ls_add_channel(HOMECHANNEL)

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

function gamehandler(target, revent, ...)
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
      elseif command == "!help" then
        ls_cmd_help(channel, numeric)
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
      elseif command == "stats" then
        ls_cmd_stats(numeric, argument)
      elseif command == "smite" and onstaff(numeric) then
        ls_cmd_smite(numeric, argument)
      elseif command == "killgame" and onstaff(numeric) then
        ls_cmd_killgame(numeric, argument)
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
    ls_bot = target
    ls_join_channels()
  end
end

function highlighthandler(target, revent, ...)
  if revent == "irc_onkilled" then
    ls_hlbot = nil
  elseif revent == "irc_onkillreconnect" then
    ls_hlbot = target
    ls_localjoin(ls_hlbot, HOMECHANNEL)
  end
end

function irc_onpart(channel, numeric, message)
  if not ls_is_game_channel(channel) then
    return
  end

  if ls_get_role(channel, numeric) then
    if ls_get_role(channel, numeric) ~= "lobby" then
      ls_incr_stats_user(numeric, "killed_suicide")
    end

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
    if ls_get_role(channel, numeric) ~= "lobby" then
      ls_incr_stats_user(numeric, "killed_suicide")
    end

    ls_remove_player(channel, kicked_numeric)
    ls_advance_state(channel)
  end
end
irc_onkickall = irc_onkick

function irc_onquit(numeric)
  for channel, _ in pairs(ls_gamestate) do
    if ls_get_role(channel, numeric) then
      if ls_get_role(channel, numeric) ~= "lobby" then
        ls_incr_stats_user(numeric, "killed_suicide")
      end

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

-- formats the specified trait identifier for output in a message
function ls_format_trait(trait)
  if trait == "teleporter" then
    return "Personal Teleporter"
  elseif trait == "infested" then
    return "Alien Parasite"
  elseif trait == "force" then
    return "Force Field Generator"
  else
    return "Unknown Trait"
  end
end

-- formats the specified player name for output in a message (optionally
-- revealing that player's role and their traits in the game)
function ls_format_player(channel, numeric, reveal_role, reveal_traits)
  local nick = irc_getnickbynumeric(numeric)
  local result = "\002" .. nick.nick .. "\002"

  if reveal_role then
    result = result .. " (" .. ls_format_role(ls_get_role(channel, numeric))
    
    if reveal_traits then
      for _, trait in pairs(ls_get_traits(channel, numeric)) do
        if ls_get_trait(channel, numeric, trait) then
          result = result .. ", " .. ls_format_trait(trait)
        end
      end
    end

    result = result .. ")"
  end

  return result
end

-- formats a list of player names for output in a message (optionally
-- revealing their roles and traits in the game)
function ls_format_players(channel, numerics, reveal_role, reveal_traits, no_and)
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

   result = result .. ls_format_player(channel, numeric, reveal_role, reveal_traits)
   i = i + 1
  end

  return result
end

-- returns the current state of the game
function ls_get_state(channel)
  return ls_gamestate[channel]["state"]
end

function ls_get_startts(channel)
  return ls_gamestate[channel]["startts"]
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

function ls_set_startts(channel, startts)
  ls_gamestate[channel]["startts"] = startts
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

function ls_get_stats_channel(channel, key)
  if not ls_db.stats_channel then
    return 0
  end

  if not ls_db.stats_channel[channel] then
    return 0
  end

  return ls_db.stats_channel[channel][key]
end

function ls_incr_stats_channel(channel, key, num)
  if not ls_db.stats_channel then
    ls_db.stats_channel = {}
  end

  if not ls_db.stats_channel[channel] then
    ls_db.stats_channel[channel] = {}
  end

  local value = ls_db.stats_channel[channel][key]

  if not value then
    value = 0
  end

  if num then
    value = value + num
  else
    value = value + 1
  end

  ls_db.stats_channel[channel][key] = value
end

function ls_get_stats_user(numeric, key)
  if not ls_db.stats_user then
    return 0
  end

  local nick = irc_getnickbynumeric(numeric)
  local accountid = nick.accountid

  if not accountid then
    accountid = -1
  end

  if not ls_db.stats_user[accountid] then
    return 0
  end

  if not ls_db.stats_user[accountid][key] then
    return 0
  end

  return ls_db.stats_user[accountid][key]
end

function ls_get_stats_user_aggregate(key)
  if not ls_db.stats_user then
    return 0
  end

  local value = 0

  for accountid, _ in pairs(ls_db.stats_user) do
    if ls_db.stats_user[accountid][key] then
      value = value + ls_db.stats_user[accountid][key]
    end
  end

  return value
end

function ls_incr_stats_user(numeric, key, num)
  local nick = irc_getnickbynumeric(numeric)
  local accountid = nick.accountid

  if not accountid then
    accountid = -1
  end

  if not ls_db.stats_user then
    ls_db.stats_user = {}
  end

  if not ls_db.stats_user[accountid] then
    ls_db.stats_user[accountid] = {}
  end

  local value = ls_db.stats_user[accountid][key]

  if not value then
    value = 0
  end

  if num then
    value = value + num
  else
    value = value + 1
  end

  ls_db.stats_user[accountid][key] = value
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

function ls_cmd_help(channel, numeric)
  ls_notice(numeric, "Read the guide at http://goo.gl/XUyPf")
  ls_notice(numeric, "If you have further questions, feel free to ask in " .. HOMECHANNEL)
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

  if string.lower(channel) ~= string.lower(HOMECHANNEL) then
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
      irc_localchanmsg(ls_hlbot, channel, "HL: " .. ls_format_players(channel, numerics, false, false, true))
      numerics = {}
    end
  end

  if table.getn(numerics) > 0 then
    irc_localchanmsg(ls_hlbot, "HL: " .. ls_format_players(channel, numerics, false, false, true))
  end
end

function ls_cmd_enable(channel, numeric)
  local chanuser = irc_getuserchanmodes(numeric, channel)

  if (not chanuser or not chanuser.opped) and not onstaff(numeric) then
    ls_notice(numeric, "You need to be opped to use this command.")
    return
  end

  ls_set_enabled(channel, true)
  ls_notice(numeric, "Game has been enabled.")
end

function ls_cmd_disable(channel, numeric)
  local chanuser = irc_getuserchanmodes(numeric, channel)

  if (not chanuser or not chanuser.opped) and not onstaff(numeric) then
    ls_notice(numeric, "You need to be opped to use this command.")
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
    ls_incr_stats_user(numeric, "failed_chance")
    ls_incr_stats_user(victimnumeric, "survived_chance")

    ls_chanmsg(channel, "The scientists' attack was not successful tonight. Nobody died.")
  elseif ls_get_guarded(channel, victimnumeric) then
    for _, player in pairs(ls_get_players(channel)) do
      ls_set_trait(channel, player, "force", false)
    end
    
    ls_set_guarded(channel, victimnumeric, false)

    ls_incr_stats_user(numeric, "failed_guarded")
    ls_incr_stats_user(victimnumeric, "survived_guarded")

    ls_chanmsg(channel, "The attack on " .. ls_format_player(channel, victimnumeric) .. " was deflected by a force field. The force field generator has now run out of power.")
  elseif ls_get_trait(channel, victimnumeric, "infested") then
    ls_devoice_player(channel, numeric)
    ls_devoice_player(channel, victimnumeric)
    
    ls_chanmsg(channel, "An alien bursts out of " .. ls_format_player(channel, victimnumeric, true) .. "'s chest just as " .. ls_format_player(channel, numeric, true) .. " was about to murder them, killing them both.")

    ls_incr_stats_user(numeric, "kill_infested")
    ls_incr_stats_user(numeric, "killed_scientist")
    ls_incr_stats_user(victimnumeric, "kill_scientist")
    ls_incr_stats_user(victimnumeric, "killed_infested")

    ls_remove_player(channel, numeric, true)
    ls_remove_player(channel, victimnumeric, true)
  else
    ls_devoice_player(channel, victimnumeric)

    if numeric == victimnumeric then
      ls_incr_stats_user(numeric, "killed_suicide")

      ls_chanmsg(channel, ls_format_player(channel, victimnumeric, true) .. " committed suicide.")
    else
      ls_incr_stats_user(numeric, "kill_scientist")
      ls_incr_stats_user(numeric, "killed_scientist")

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

  if ls_get_state(channel) ~= "investigate" then
    ls_notice(numeric, "Sorry, you can't use this command right now.")
    return
  end

  if not ls_get_active(channel, numeric) then
    ls_notice(numeric, "Sorry, it's not your turn to choose an investigation target.")
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
      ls_notice(investigator, ls_format_player(channel, numeric) .. " investigated " .. ls_format_player(channel, victimnumeric) .. ". Their role is: " .. ls_format_role(ls_get_role(channel, victimnumeric)))
    end
  end

  if ls_get_role(channel, victimnumeric) ~= "scientist" then
    ls_notice(victimnumeric, ls_format_player(channel, numeric) .. " investigated you.")
  end
  
  if math.random(100) > 85 then
    ls_incr_stats_user(numeric, "investigate_revealed")

    ls_chanmsg(channel, ls_format_player(channel, numeric) .. "'s fine detective work reveals " .. ls_format_player(channel, victimnumeric) .. "'s role: " .. ls_format_role(ls_get_role(channel, victimnumeric)))
  end

  ls_incr_stats_user(numeric, "investigate_" .. ls_get_role(channel, victimnumeric))
  ls_incr_stats_user(victimnumeric, "investigate_target")

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

  ls_keepalive(channel, numeric)
  
  ls_set_vote(channel, numeric, victimnumeric)
  ls_notice(numeric, "Done.")

  ls_advance_state(channel)

  ls_flush_modes(channel)
end

function ls_cmd_guard(numeric, victim)
  if not victim then
    ls_notice(numeric, "Syntax: guard <nick>")
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
    if ls_get_guarded(channel, player) then
      if player == victimnumeric then
        ls_notice(numeric, "You are already protecting " .. target .. ".")
        return
      end
      
      local previous_Target
      
      if player == numeric then
        previous_target = "yourself"
      else
        previous_target = ls_format_player(channel, player)
      end
      
      ls_notice(numeric, "You are no longer protecting " .. previous_target .. ".")

      if numeric ~= player then
        ls_notice(player, "You are no longer being protected by a \002force field\002.")
      end
    end

    ls_set_guarded(channel, player, (player == victimnumeric))
  end
  
  ls_notice(victimnumeric, "A field of energy envelopes you. You are now protected by a \002force field\002.")
  
  if numeric ~= victimnumeric then
    ls_notice(numeric, "You are now protecting " .. target .. ".")
  end
end

function round(num, idp)
  local mult = 10^(idp or 0)
  return math.floor(num * mult + 0.5) / mult
end

function ls_cmd_stats(numeric, victim)
  local getter

  if victim == "--all" then
    local channel = ls_chan_for_numeric(numeric)

    if channel and ls_get_role(channel, numeric) ~= "lobby" then
      ls_notice(numeric, "Sorry, you can't view aggregated statistics while you're playing the game.")
      return
    end

    getter = function(key)
      return ls_get_stats_user_aggregate(key)
    end

    ls_notice(numeric, "Showing aggregated statistics for all users.")
  else
    local victimnumeric

    if victim then
      local victimnick = irc_getnickbynick(victim)

      if not victimnick then
        ls_notice(numeric, "Sorry, I don't know who that is. Please specify a valid nick or try --all.")
        return
      end

      if not victimnick.accountid then
        ls_notice(numeric, "Sorry, that user is not authenticated with Q.")
        return
      end

      for channel, _ in pairs(ls_gamestate) do
        local role = ls_get_role(channel, victimnick.numeric)

        if role and role ~= "lobby" then
          ls_notice(numeric, "Sorry, you can't view statistics for a user who is currently playing a game.")
          return
        end
      end

      victimnumeric = victimnick.numeric

      ls_notice(numeric, "Showing statistics for '" .. victimnick.nick .. "'")
    else
      victimnumeric = numeric

      ls_notice(numeric, "Showing statistics for yourself.")
    end

    getter = function(key)
      return ls_get_stats_user(victimnumeric, key)
    end
  end

  ls_notice(numeric, "Game time: " .. round(getter("game_time") / 60, 2) .. " minutes")

  ls_notice(numeric, "Roles: " ..
    getter("role_scientist") .. "x " .. ls_format_role("scientist") .. ", " ..
    getter("role_investigator") .. "x " .. ls_format_role("investigator") .. ", " ..
    getter("role_citizen") .. "x " .. ls_format_role("citizen"))

  ls_notice(numeric, "Traits: " ..
    getter("trait_teleporter") .. "x " .. ls_format_trait("teleporter") .. ", " ..
    getter("trait_infested") .. "x " .. ls_format_trait("infested") .. ", " ..
    getter("trait_force") .. "x " .. ls_format_trait("force"))

  ls_notice(numeric, "Won games as: " ..
    getter("won_scientist") .. "x " .. ls_format_role("scientist") .. ", " ..
    getter("won_investigator") .. "x " .. ls_format_role("investigator") .. ", " ..
    getter("won_citizen") .. "x " .. ls_format_role("citizen"))

  ls_notice(numeric, "Survived attacks by: " ..
    getter("survived_chance") .. "x chance, " ..
    getter("survived_guarded") .. "x being guarded with a force field")

  ls_notice(numeric, "Active role: " ..
    getter("active_scientist") .. "x " .. ls_format_role("scientist") .. ", " ..
    getter("active_investigator") .. "x " .. ls_format_role("investigator"))

  ls_notice(numeric, "Inactive role: " ..
    getter("inactive_scientist") .. "x " .. ls_format_role("scientist") .. ", " ..
    getter("inactive_investigator") .. "x " .. ls_format_role("investigator"))

  ls_notice(numeric, "Kills: " ..
    getter("kill_scientist") .. "x scientist attack, " ..
    getter("kill_infested") .. "x infestation attack, " ..
    getter("kill_tied") .. "x teams tied, " ..
    getter("kill_smite") .. "x lightning, " ..
    getter("kill_bomb") .. "x bomb")

  ls_notice(numeric, "Failed kills: " ..
    getter("failed_chance") .. "x by chance, " ..
    getter("failed_guarded") .. "x because target was guarded by a force field")

  ls_notice(numeric, "Deaths: " ..
    getter("killed_scientist") .. "x scientist attack, " ..
    getter("killed_infested") .. "x infestation attack, " ..
    getter("killed_lynch") .. "x lynched, " ..
    getter("killed_suicide") .. "x suicide, " ..
    getter("killed_tied") .. "x teams tied, " ..
    getter("killed_afk") .. "x AFK, " ..
    getter("killed_smite") .. "x lightning, " ..
    getter("killed_bomb") .. "x bomb")

  ls_notice(numeric, "Revealed investigations: " .. getter("investigation_revealed"))

  ls_notice(numeric, "Investigated: " ..
    getter("investigate_scientist") .. "x " .. ls_format_role("scientist") .. ", " ..
    getter("investigate_investigator") .. "x " .. ls_format_role("investigator") .. ", " ..
    getter("investigate_citizen") .. "x " .. ls_format_role("citizen"))

  ls_notice(numeric, "Was investigated: " .. getter("investigate_target"))

  ls_notice(numeric, "Votes by target team: " ..
    getter("vote_team") .. "x own team, " ..
    getter("vote_enemy") .. "x enemy team")

  ls_notice(numeric, "Votes by target role: " ..
    getter("vote_scientist") .. "x " .. ls_format_role("scientist") .. ", " ..
    getter("vote_investigator") .. "x " .. ls_format_role("investigator") .. ", " ..
    getter("vote_citizen") .. "x " .. ls_format_role("citizen"))

  ls_notice(numeric, "Teleporter usage: " ..
    getter("teleporter_activated") .. "x success (" .. getter("teleporter_intact") .. "x retained, " .. getter("teleporter_destroyed") .. "x destroyed), " ..
    getter("teleporter_failed") .. "x failed")
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

  ls_incr_stats_user(numeric, "kill_smite")
  ls_incr_stats_user(victimnumeric, "killed_smite")

  ls_chanmsg(channel, ls_format_player(channel, victimnumeric, true, true) .. " was struck by lightning.")
  ls_remove_player(channel, victimnumeric, true)

  ls_advance_state(channel)

  ls_flush_modes(channel)
end

function ls_cmd_killgame(numeric, channel)
  if not channel then
    ls_notice(numeric, "Syntax: smite <channel>")
    return
  end

  if not ls_is_game_channel(channel) then
    ls_notice(numeric, "I'm not on that channel.")
    return
  end

  if table.getn(ls_get_players(channel)) == 0 then
    ls_notice(numeric, "There's nobody playing the game.")
    return
  end

  ls_incr_stats_user(numeric, "kill_bomb", table.getn(ls_get_players(channel)))

  for _, player in pairs(ls_get_players(channel)) do
    ls_incr_stats_user(player, "killed_bomb")
  end

  ls_chanmsg(channel, ls_format_player(channel, numeric) .. " set us up the bomb. Game over.")
  ls_stop_game(channel)

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
  db.channels = { HOMECHANNEL }

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

  if role ~= "lobby" then
    ls_incr_stats_user(numeric, "game_time", os.time() - ls_get_startts(channel))
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

function ls_get_traits(channel, numeric)
  local traits = {}
  
  for trait, _ in pairs(ls_gamestate[channel]["players"][numeric]["traits"]) do
    table.insert(traits, trait)
  end
  
  return traits
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

    local plural_s

    if count ~= 1 then
      plural_s = "s"
    else
      plural_s = ""
    end

    if numeric ~= votenumeric then
      if ls_get_vote(channel, numeric) then
        ls_chanmsg(channel, ls_format_player(channel, numeric) .. " changed their vote to " .. ls_format_player(channel, votenumeric) .. " (" .. count .. " vote" .. plural_s .. ").")
      else
        ls_chanmsg(channel, ls_format_player(channel, numeric) .. " voted for " .. ls_format_player(channel, votenumeric) .. " (" .. count .. " vote" .. plural_s .. ").")
      end
    else
      ls_chanmsg(channel, ls_format_player(channel, numeric) .. " voted for himself. Oops! (" .. count .. " vote" .. plural_s .. ")")
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
      ls_set_seen(channel, numeric, os.time())
    else
      ls_devoice_player(channel, numeric)
    end
  end

  ls_chanmsg(channel, "Starting the game...")

  ls_incr_stats_channel(channel, "game_count")
  ls_set_startts(channel, os.time())

  for _, player in pairs(players) do
    ls_set_role(channel, player, "lobby")
    ls_keepalive(channel, player)
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

  -- notify scientists about each other
  for _, investigator in pairs(ls_get_players(channel, "investigator")) do
    for _, investigator_notify in pairs(ls_get_players(channel, "investigator")) do
      if investigator ~= investigator_notify then
        ls_notice(investigator_notify, ls_format_player(channel, investigator) .. " is also an investigator.")
      end
    end
  end

  -- rest of the players are citizens
  for _, player in pairs(players) do
    ls_set_role(channel, player, "citizen")
  end

  for _, player in pairs(ls_get_players(channel)) do
    ls_incr_stats_user(player, "role_" .. ls_get_role(channel, player))
  end  

  -- give someone the force field generator
  local force_owner = players[math.random(table.getn(players))]
  ls_set_trait(channel, force_owner, "force", true)
  ls_incr_stats_user(force_owner, "trait_force")
  ls_set_guarded(channel, force_owner, true)
  ls_notice(force_owner, "You've found the \002force field generator\002. Use /notice " .. BOTNICK .. " guard <nick> to protect someone.")
  ls_notice(force_owner, "You are currently protecting yourself.")

  -- make someone infested if there are at least 6 citizens
  if table.getn(players) > 6 then
    local infested_player = players[math.random(table.getn(players))]
    ls_set_trait(channel, infested_player, "infested", true)
    ls_incr_stats_user(infested_player, "trait_infested")
    ls_notice(infested_player, "You're infested with an \002alien parasite\002.")
  end
  
  -- give someone the teleporter
  local teleporter_candidates

  if math.random(100) > 75 then
    teleporter_candidates = ls_get_players(channel)
  else
    teleporter_candidates = ls_get_players(channel, "scientist")
  end

  local teleporter_owner = teleporter_candidates[math.random(table.getn(teleporter_candidates))]
  ls_set_trait(channel, teleporter_owner, "teleporter", true)
  ls_incr_stats_user(teleporter_owner, "trait_teleporter")
  ls_notice(teleporter_owner, "You've found the \002personal teleporter\002 (50% chance to evade lynching).")
  
  ls_chanmsg(channel, "Roles have been assigned: " ..
    table.getn(ls_get_players(channel, "scientist")) .. "x " .. ls_format_role("scientist") .. ", " ..
    table.getn(ls_get_players(channel, "investigator")) .. "x " .. ls_format_role("investigator") .. ", " ..
    table.getn(ls_get_players(channel, "citizen")) .. "x " .. ls_format_role("citizen") .. " - Good luck!")

  ls_set_state(channel, "kill")
  ls_advance_state(channel)
end

function ls_stop_game(channel)
  if ls_get_state(channel) ~= "lobby" then
    ls_incr_stats_channel(channel, "game_time", os.time() - ls_get_startts(channel))
  end

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

    ls_chanmsg(channel, ls_format_players(channel, dead_players, true, true) .. " " .. verb .. " to be dead (AFK).")

    for _, player in pairs(dead_players) do
      ls_incr_stats_user(player, "killed_afk")
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
    for _, player in pairs(players) do
      if ls_get_role(channel, player) == "scientist" then
        ls_incr_stats_user(player, "kill_tied")
        ls_incr_stats_user(player, "won_scientist")
      else
        ls_incr_stats_user(player, "killed_tied")
      end
    end

    ls_chanmsg(channel, "There are equal to or more scientists than citizens. Science wins again: " .. ls_format_players(channel, scientists, true, true))
    ls_stop_game(channel)
    return
  end

  -- winning condition for citizen
  if table.getn(scientists) == 0 then
    for _, player in pairs(players) do
      ls_incr_stats_user(player, "won_" .. ls_get_role(channel, player))
    end

    ls_chanmsg(channel, "All scientists have been eliminated. The citizens win this round: " .. ls_format_players(channel, players, true, true))
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
          ls_incr_stats_user(scientist, "active_scientist")
          ls_notice(scientist, "It's your turn to select a citizen to kill. Use /notice " .. BOTNICK .. " kill <nick> to kill someone.")
        else
          ls_set_active(channel, scientist, false)
          ls_incr_stats_user(scientist, "inactive_scientist")
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
          ls_incr_stats_user(investigator, "active_investigator")
          ls_notice(investigator, "You need to choose someone to investigate: /notice " .. BOTNICK .. " investigate <nick>")
        else
          ls_set_active(channel, investigator, false)
          ls_incr_stats_user(investigator, "inactive_investigator")
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

        if (ls_get_role(channel, player) == "scientist" and ls_get_role(channel, vote) == "scientist") or (ls_get_role(channel, player) ~= "scientist" and ls_get_role(channel, vote) ~= "scientist") then
          ls_incr_stats_user(player, "vote_team")
        else
          ls_incr_stats_user(player, "vote_enemy")
        end

        ls_incr_stats_user(player, "vote_" .. ls_get_role(channel, vote))

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
      local teleporter = ls_get_trait(channel, victim, "teleporter")

      if teleporter and math.random(100) > 50 then
        ls_notice(victim, "You press the button to activate the \002personal teleporter\002... and you safely escape!")
        ls_incr_stats_user(victim, "teleporter_activated")
        ls_chanmsg(channel, ls_format_player(channel, victim) .. " used his personal teleporter to escape the angry mob.")
        
        if math.random(100) > 50 then
          ls_set_trait(channel, victim, "teleporter", false)
          ls_incr_stats_user(victim, "teleporter_destroyed")
          ls_notice(victim, "Your \002personal teleporter\002 was destroyed.")
        else
          ls_incr_stats_user(victim, "teleporter_intact")
          ls_notice(channel, victim, "You check your \002personal teleporter\002 after the escape and it is still intact.")
        end
      else
        if teleporter then
          ls_incr_stats_user(victim, "teleporter_failed")
          ls_notice(victim, "You press the button to activate the \002personal teleporter\002... but nothing happens!")
        end
        
        ls_incr_stats_user(victim, "killed_lynch")
        ls_devoice_player(channel, victim)

        ls_chanmsg(channel, ls_format_player(channel, victim, true) .. " " .. message_suffix)
        ls_remove_player(channel, victim, true)
      end

      ls_set_state(channel, "kill")
      ls_advance_state(channel)
    elseif delayed then
      ls_chanmsg(channel, "Some of the citizens still need to vote: " .. ls_format_players(channel, missing_votes))
    end
  end
end
