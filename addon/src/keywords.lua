-------------------------------------------------------------------------------
-- LISTENER by Tammya-MoonGuard (2017)
--
-- This module controls the keywords feature, which is a chat filter that
-- highlights keywords found in message text, as well as making a notification
-- when it finds them.
-------------------------------------------------------------------------------

local Main = ListenerAddon
local L    = Main.Locale
local SharedMedia = LibStub("LibSharedMedia-3.0")

-------------------------------------------------------------------------------
-- This is a list of patterns that we search the text for.
-- It's built during LoadKeywordsConfig, converting the CSV entries to
-- lua patterns, making replacements and adjusting as necessary.
--
local g_triggers = {}

-------------------------------------------------------------------------------
-- This is another cached configuration value, built from the color value
-- in the database. Formatted as "|crrggbbaa".
--
local g_color    = ""

-------------------------------------------------------------------------------
-- The player's RP name the triggers were built with.
--
local g_rpname

-------------------------------------------------------------------------------
-- A simple throttle variable to not spam the beep function, since the filter
-- may be used several times for the same thing. This value is the time when
-- another beep is allowed, e.g. lastbeep + 0.15 seconds to disallow it 
-- from repeating on the same frame.
--
local g_beeptime = 0

-------------------------------------------------------------------------------
local function GetHexCode( color )
	return string.format( "ff%.2x%.2x%.2x", color[1]*255, color[2]*255, color[3]*255 )
end

-------------------------------------------------------------------------------
-- Text hidden from the triggers, in this order.
-- Links first, since they hold color codes of their own
--
local HIDDEN_CODES = {
	"(|c%x%x%x%x%x%x%x%x|H[^|]+|h[^|]+|h|r)";
	"(|cn[^:|]+:|H[^|]+|h[^|]+|h|r)";
	"|c%x%x%x%x%x%x%x%x";
	"|cn[^:]+:";
	"|r";
}

-------------------------------------------------------------------------------
-- This is a list of events that we want to hook for the filter.
-- Actual event is CHAT_MSG_<entry>
--
local CHAT_EVENTS = { 
	"SAY";
	"YELL";
	"EMOTE";
	"GUILD";
	"OFFICER";
	"PARTY";
	"PARTY_LEADER";
	"RAID";
	"RAID_LEADER";
	"CHANNEL";
}

-------------------------------------------------------------------------------
-- Highlights keywords in a message and makes the notification.
-- Returns (msg, found)
--
function Main.HighlightKeywords( msg, sender )
	-- Skip if not turned on.
	if not Main.db.profile.keywords_enable then return msg end

	local found = false

	-- Don't filter player's own text.
	if Main.Ambiguate( sender, "all" ) == UnitName("player") then return msg end

	-- Rebuild the triggers when the player's RP name changes
	if LibRPNames.Get( UnitName("player") ) ~= g_rpname then Main.LoadKeywordsConfig() end

	local original = msg
	local replaced = {}
	local function hide( text )
		table.insert( replaced, text )
		return "\001\002" .. #replaced .. "\002\001"
	end
	local function restore( text )
		return (text:gsub( "\001\002(%d+)\002\001", function( index )
			return replaced[tonumber(index)]
		end))
	end

	-- First we hide any links and color codes found, since we don't want to
	-- corrupt them.
	-- Triggers take \001 as a word boundary, so a keyword next to a hidden code matches
	for _, pattern in ipairs( HIDDEN_CODES ) do
		msg = msg:gsub( pattern, hide )
	end

	-- We pad with space so that word boundaries at start and end are found.
	msg = " " .. msg .. " "
	
	-- Now iterate through the triggers...
	for trigger, _ in pairs( g_triggers ) do
		
		for maxsubs = 1,10 do
					
			local subs
			msg, subs = msg:gsub( trigger, function( a,b,c )
				-- Any matches that are found are processed with the color code
				-- and then removed from the string, to be added later after
				-- all filtering is done, to prevent keyword collisions.
				--
				return a .. hide( g_color .. restore( b ) .. "|r" ) .. c
			end)
			
			if subs > 0 then
				found = true
				if GetTime() > g_beeptime then
					-- we have our own cooldown in here because this shit is going to be spammed a lot
					-- on message matches.
					g_beeptime = GetTime() + 0.15
					
					if Main.db.profile.keywords_sound then
						Main.Sound.Play( "messages", 10, Main.db.profile.keywords_soundfile )
						Main.SetMessageBeepCD()
					end
					
					if Main.db.profile.keywords_flash then
						Main.FlashClient()
					end
				end
			else
				break
			end
		
		end
		
	end
	
	if found then
		-- If we found any matching keywords, rebuild the message with the
		-- saved strings.
		msg = restore( msg )
		
		-- msg:sub is to remove the spaces we added as padding.
		return msg:sub( 2, msg:len() - 1 ), true
	end
	return original
end

-------------------------------------------------------------------------------
-- Here's our chat filter.
--
local function ChatFilter( self, event, msg, sender, ... )
	-- Don't filter player's own text.
	local bnet = select( 13-2, ... )
	if bnet and bnet > 0 and BNIsSelf( bnet ) then return end

	local found
	msg, found = Main.HighlightKeywords( msg, sender )
	if found then return false, msg, sender, ... end
end

-------------------------------------------------------------------------------
-- Load/reload the keywords configuration.
--
function Main.LoadKeywordsConfig()
	g_color = "|c" .. GetHexCode( Main.db.profile.keywords_color )
	g_triggers = {}
	
	local quotepattern = '(['..("%^$().[]*+-?"):gsub("(.)", "%%%1")..'])'
	
	local oocname   = UnitName('player')
	local icname, short_icname = LibRPNames.Get( oocname )
	g_rpname = icname
	local firstname = short_icname:match( "^%s*(%S+)" ) or ""
	local lastname  = icname:match( "(%S+)%s*$" ) or ""
	
	-- Only % needs escaping in a gsub replacement
	firstname = firstname:gsub( "%%", "%%%%" )
	lastname  = lastname:gsub( "%%", "%%%%" )
	
	for word in Main.db.profile.keywords_string:gmatch( "[^,]+" ) do
	
		-- trim space, lowercase
		word = word:match( "^%s*(.-)%s*$" ):lower()
		
		
		if word then
			-- and now, format the trigger...
			
			-- Hyphens don't count, so hyphenated names stay plain words
			if not word:gsub( "%-", "" ):find( quotepattern ) then
			
				-- if word doesn't have any special characters, then we
				-- make our normal substitutions,
				-- turn it into a case insensitive pattern, and wrap it
				-- in word boundaries
				
				word = word:gsub( "<firstname>", firstname )
				word = word:gsub( "<lastname>", lastname )
				word = word:gsub( "<oocname>", oocname )
				word = word:lower()
				-- Escape after the substitutions so names and hyphens match literally
				word = word:gsub( quotepattern, "%%%1" )
				
				word = word:gsub( "%a", function(c)
					return string.format( "[%s%s]", c:lower(), c:upper() )
				end)
				-- convert space to patterned space
				word = word:gsub( "%s+", "%%s+" )
				word = "([%s%p\001])(" .. word .. ")([%s%p\001])"
			else
				-- otherwise, they're doing something weird, and let them do it.
				-- meaning, they can use lua patterns. we just add the spaces
				-- pattern to wrap it.
				
				-- escape parenthesis because they can cause errors.
				word = word:gsub( "([%(%)])", "%%%1" )
				
				-- and match spaces on ends
				word = "([%s%p\001])(" .. word .. ")([%s%p\001])"
				
			end
			g_triggers[word] = true
		end
	end
end

-------------------------------------------------------------------------------
-- Sender name filter for TRP3's plain NPC emotes ("| text"), which TRP3 draws
-- in the name slot, leaving the message as " ".
--
local function NPCNameFilter( event, name, msg, sender, ... )
	local trp = TRP3_API and TRP3_API.chat
	-- TRP3 only flags NPC lines on CHAT_MSG_EMOTE
	if event ~= "CHAT_MSG_EMOTE" or not trp or not trp.setNPCMessageName then return end
	local lineID = select( 9, ... )
	if not canaccessallvalues( msg, sender, lineID ) or msg ~= " " or trp.getNPCMessageID() ~= lineID then return end
	
	local text, found = Main.HighlightKeywords( trp.getNPCMessageName(), sender )
	if not found then return end
	
	-- Stored back so TRP3's own filter returns it if it runs after this one
	trp.setNPCMessageName( text )
	return text
end

-------------------------------------------------------------------------------
-- Initialize this module.
--
function Main.InitKeywords()
	Main.LoadKeywordsConfig()
	for i, event in ipairs(CHAT_EVENTS) do
		ChatFrame_AddMessageEventFilter( "CHAT_MSG_" .. event, ChatFilter );
	end
	ChatFrameUtil.AddSenderNameFilter( NPCNameFilter )
end
