/**
 * vim: set ts=4 :
 * =============================================================================
 * SourceMod Rock The Vote Plugin
 * Creates a map vote when the required number of players have requested one.
 *
 * SourceMod (C)2004-2014 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 * Version: $Id$
 */

#include <sourcemod>
#include <mapchooser>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "Map Nominations Advanced",
	author = "AlliedModders LLC & Punky",
	description = "Provides Map Nominations and Support for Event Maps",
	version = "1.0.0",
	url = "http://www.sourcemod.net/"
};

ConVar g_Cvar_ExcludeOld;
ConVar g_Cvar_ExcludeCurrent;

Menu g_MapMenu = null;
Menu g_PreMapMenu = null;
Menu g_EventMenu = null;
ArrayList g_MapList = null;
int g_mapFileSerial = -1;
int ply_count = -1;
KeyValues kv = null;

#define MAPSTATUS_ENABLED (1<<0)
#define MAPSTATUS_DISABLED (1<<1)
#define MAPSTATUS_EXCLUDE_CURRENT (1<<2)
#define MAPSTATUS_EXCLUDE_PREVIOUS (1<<3)
#define MAPSTATUS_EXCLUDE_NOMINATED (1<<4)

StringMap g_mapTrie = null;
StringMap g_mapInfo = null;
StringMap HasNominated = null;

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("nominations_advanced.phrases");
	
	int arraySize = ByteCountToCells(PLATFORM_MAX_PATH);
	g_MapList = new ArrayList(arraySize);
	
	g_Cvar_ExcludeOld = CreateConVar("sm_nominate_excludeold", "1", "Specifies if the current map should be excluded from the Nominations list", 0, true, 0.00, true, 1.0);
	g_Cvar_ExcludeCurrent = CreateConVar("sm_nominate_excludecurrent", "1", "Specifies if the MapChooser excluded maps should also be excluded from Nominations", 0, true, 0.00, true, 1.0);
	
	RegConsoleCmd("sm_nominate", Command_Nominate);
	
	RegAdminCmd("sm_nominate_addmap", Command_Addmap, ADMFLAG_CHANGEMAP, "sm_nominate_addmap <mapname> - Forces a map to be on the next mapvote.");
	
	g_mapTrie = new StringMap();
	g_mapInfo = new StringMap();
	HasNominated = new StringMap();
}

public void OnMapStart()
{
	if(kv != null)delete kv;
	ply_count = 0;
	
	g_mapInfo.Clear();
	HasNominated.Clear();
}

public void OnMapEnd()
{
	if(kv != null)delete kv;	//deleting the kv, that stores our address to the map list
}

public void OnClientConnected(int client)
{
	++ply_count;
	char ply[2] = " ";
	IntToString(client, ply, sizeof(ply));
	HasNominated.Remove(ply);				//remove client x entry from the string map
}

public void OnClientDisconnect(int client)
{
	if(ply_count > 0)
	{
		--ply_count;
	}
}

public void OnConfigsExecuted()
{
	if (ReadMapList(g_MapList,
					g_mapFileSerial,
					"nominations",
					MAPLIST_FLAG_CLEARARRAY|MAPLIST_FLAG_MAPSFOLDER)
		== null)
	{
		if (g_mapFileSerial == -1)
		{
			SetFailState("Unable to create a valid map list.");
		}
	}
	
	if(kv == null)
	{
		kv = new KeyValues("eventmaps");
		kv.ImportFromFile("maplist_event.txt");
	}
	
	BuildMapMenu();
}

public void OnNominationRemoved(const char[] map, int owner)
{
	int status;
	
	char resolvedMap[PLATFORM_MAX_PATH];
	FindMap(map, resolvedMap, sizeof(resolvedMap));
	
	/* Is the map in our list? */
	if (!g_mapTrie.GetValue(resolvedMap, status))
	{
		return;	
	}
	
	/* Was the map disabled due to being nominated */
	if ((status & MAPSTATUS_EXCLUDE_NOMINATED) != MAPSTATUS_EXCLUDE_NOMINATED)
	{
		return;
	}
	
	g_mapTrie.SetValue(resolvedMap, MAPSTATUS_ENABLED);
}

public Action Command_Addmap(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_nominate_addmap <mapname>");
		return Plugin_Handled;
	}
	
	char mapname[PLATFORM_MAX_PATH];
	char resolvedMap[PLATFORM_MAX_PATH];
	GetCmdArg(1, mapname, sizeof(mapname));

	if (FindMap(mapname, resolvedMap, sizeof(resolvedMap)) == FindMap_NotFound)
	{
		// We couldn't resolve the map entry to a filename, so...
		ReplyToCommand(client, "%t", "Map was not found", mapname);
		return Plugin_Handled;		
	}
	
	char displayName[PLATFORM_MAX_PATH];
	GetMapDisplayName(resolvedMap, displayName, sizeof(displayName));
	
	int status;
	if (!g_mapTrie.GetValue(resolvedMap, status))
	{
		ReplyToCommand(client, "%t", "Map was not found", displayName);
		return Plugin_Handled;		
	}
	
	NominateResult result = NominateMap(resolvedMap, true, 0);
	
	if (result > Nominate_Replaced)
	{
		/* We assume already in vote is the casue because the maplist does a Map Validity check and we forced, so it can't be full */
		ReplyToCommand(client, "%t", "Map Already In Vote", displayName);
		
		return Plugin_Handled;	
	}
	
	
	g_mapTrie.SetValue(resolvedMap, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);

	
	ReplyToCommand(client, "%t", "Map Inserted", displayName);
	LogAction(client, -1, "\"%L\" inserted map \"%s\".", client, mapname);

	return Plugin_Handled;		
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
	if (!client)
	{
		return;
	}
	
	if (strcmp(sArgs, "nominate", false) == 0)
	{
		ReplySource old = SetCmdReplySource(SM_REPLY_TO_CHAT);
		
		AttemptNominate(client);
		
		SetCmdReplySource(old);
	}
}

public Action Command_Nominate(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}
	
	if (args == 0)
	{
		AttemptNominate(client);
		return Plugin_Handled;
	}
	
	char mapname[PLATFORM_MAX_PATH];
	GetCmdArg(1, mapname, sizeof(mapname));
	
	if (FindMap(mapname, mapname, sizeof(mapname)) == FindMap_NotFound)
	{
		// We couldn't resolve the map entry to a filename, so...
		ReplyToCommand(client, "%t", "Map was not found", mapname);
		return Plugin_Handled;		
	}
	
	char displayName[PLATFORM_MAX_PATH];
	GetMapDisplayName(mapname, displayName, sizeof(displayName));
	
	int status;
	if (!g_mapTrie.GetValue(mapname, status))
	{
		ReplyToCommand(client, "%t", "Map was not found", displayName);
		return Plugin_Handled;		
	}
	
	if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
	{
		if ((status & MAPSTATUS_EXCLUDE_CURRENT) == MAPSTATUS_EXCLUDE_CURRENT)
		{
			ReplyToCommand(client, "[SM] %t", "Can't Nominate Current Map");
		}
		
		if ((status & MAPSTATUS_EXCLUDE_PREVIOUS) == MAPSTATUS_EXCLUDE_PREVIOUS)
		{
			ReplyToCommand(client, "[SM] %t", "Map in Exclude List");
		}
		
		if ((status & MAPSTATUS_EXCLUDE_NOMINATED) == MAPSTATUS_EXCLUDE_NOMINATED)
		{
			ReplyToCommand(client, "[SM] %t", "Map Already Nominated");
		}
		
		return Plugin_Handled;
	}
	
	int playercount = -1, nominations = -1, map_info[2] =  { 0, 0 }, map_info_player[2] =  { 0, 0 };

	char ply[2] = " ";
	char s_map[PLATFORM_MAX_PATH];
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	IntToString(client, ply, sizeof(ply));

	if(g_mapInfo.GetArray(mapname, map_info, 2))
	{
		nominations = map_info[0];
		playercount = map_info[1];
	
		if(HasNominated.GetString(ply, s_map, sizeof(s_map)))
		{
			if (StrEqual(s_map, mapname))
			{
				ReplyToCommand(client, "[SM] %t", "Already Voted");
				return Plugin_Handled;
			}
			if(g_mapInfo.GetArray(s_map, map_info_player, 2))
			{
				++map_info_player[0];					//increasing votes left for the map that player has changed his vote from
				g_mapInfo.SetArray(s_map, map_info_player, 2);			//update the votes for that map
			}
			if(RemoveNominationByMap(s_map))
			{
				PrintToChatAll("[SM] %t", "Map Removed", s_map);
			}
		}
		if(playercount <= ply_count)
		{
			if(nominations > 0)
			{
				HasNominated.SetString(ply, mapname);				//player has voted so decrease votes required or nominate the map
				--nominations;
				map_info[0] = nominations;
				g_mapInfo.SetArray(mapname, map_info, 2);			//update
				if(nominations > 0)
				{
					PrintToChatAll("[SM] %t", "Votes Needed", name, mapname, nominations);
					return Plugin_Handled;
				}
			}
		}
		else
		{
			ReplyToCommand(client, "[SM] %t", "Players Needed", playercount - ply_count);
			return Plugin_Handled;
		}
	}
	else if(HasNominated.GetString(ply, s_map, sizeof(s_map)))
	{
		if(g_mapInfo.GetArray(s_map, map_info_player, 2))
		{
			++map_info_player[0]; 								
			g_mapInfo.SetArray(s_map, map_info_player, 2);
			if(RemoveNominationByMap(s_map))
			{
				PrintToChatAll("[SM] %t", "Map Removed", s_map);
			}
		}
	}
	HasNominated.SetString(ply, mapname);				//update player's nomination for later use
	
	NominateResult result = NominateMap(mapname, false, client);
	if (result > Nominate_Replaced)
	{
		if (result == Nominate_AlreadyInVote)
		{
			ReplyToCommand(client, "%t", "Map Already In Vote", displayName);
		}
		else
		{
			ReplyToCommand(client, "[SM] %t", "Map Already Nominated");
		}
		
		return Plugin_Handled;	
	}
	if (result == Nominate_Replaced)
	{
		PrintToChatAll("[SM] %t", "Map Nomination Changed", name, mapname);
		return Plugin_Handled;	
	}
	
	/* Map was nominated! - Disable the menu item and update the trie */
	
	g_mapTrie.SetValue(mapname, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);
	
	if(g_mapInfo.GetArray(mapname, map_info, 2))
	{
		PrintToChatAll("[SM] %t", "Map Voted", mapname);
		return Plugin_Continue;
	}
	
	PrintToChatAll("[SM] %t", "Map Nominated", name, displayName);
	
	return Plugin_Continue;
}

void AttemptNominate(int client)
{
	g_PreMapMenu.SetTitle("%T", "Nominate Title", client);
	g_PreMapMenu.Display(client, MENU_TIME_FOREVER);
	
	return;
}

void BuildMapMenu()
{
	delete g_MapMenu;
	delete g_PreMapMenu;
	delete g_EventMenu;
	
	g_mapTrie.Clear();
	
	g_MapMenu = new Menu(Handler_MapSelectMenu, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
	g_PreMapMenu = new Menu(Handler_PreMapSelectMenu, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
	g_EventMenu = new Menu(Handler_EventMapSelectMenu, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);

	char map[PLATFORM_MAX_PATH];
	
	ArrayList excludeMaps;
	char currentMap[PLATFORM_MAX_PATH];
	
	if (g_Cvar_ExcludeOld.BoolValue)
	{	
		excludeMaps = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
		GetExcludeMapList(excludeMaps);
	}
	
	if (g_Cvar_ExcludeCurrent.BoolValue)
	{
		GetCurrentMap(currentMap, sizeof(currentMap));
	}
	
	char classic[128], event[128];
	Format(classic, sizeof(classic), "%t", "Classic Maps");
	Format(event, sizeof(event), "%t", "Event Maps");
	
	g_PreMapMenu.AddItem("Classic Maps", classic);
	g_PreMapMenu.AddItem("Event Maps", event);
	g_PreMapMenu.ExitButton = true;
	
	for (int i = 0; i < g_MapList.Length; i++)
	{
		int status = MAPSTATUS_ENABLED;
		
		g_MapList.GetString(i, map, sizeof(map));
		
		FindMap(map, map, sizeof(map));
		
		char displayName[PLATFORM_MAX_PATH];
		GetMapDisplayName(map, displayName, sizeof(displayName));

		if (g_Cvar_ExcludeCurrent.BoolValue)
		{
			if (StrEqual(map, currentMap))
			{
				status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_CURRENT;
			}
		}
		
		/* Dont bother with this check if the current map check passed */
		if (g_Cvar_ExcludeOld.BoolValue && status == MAPSTATUS_ENABLED)
		{
			if (excludeMaps.FindString(map) != -1)
			{
				status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_PREVIOUS;
			}
		}
		
		g_MapMenu.AddItem(map, displayName);
		g_mapTrie.SetValue(map, status);
	}
	
	int nominations = -1, playercount = -1, map_info[2] =  { 0, 0 };
	
	if(kv.GotoFirstSubKey())							//fetch the maps and their details
	{
		do
		{
			char event_map[PLATFORM_MAX_PATH];
			int status = MAPSTATUS_ENABLED;
			kv.GetSectionName(event_map, sizeof(event_map));
			nominations = kv.GetNum("nominations");
			playercount = kv.GetNum("playercount");
			map_info[0] = nominations;
			map_info[1] = playercount;
			if (GetConVarBool(g_Cvar_ExcludeCurrent))
			{
				if (StrEqual(event_map, currentMap))
				{
					status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_CURRENT;
				}
			}
		
			/* Dont bother with this check if the current map check passed */
			if (GetConVarBool(g_Cvar_ExcludeOld) && status == MAPSTATUS_ENABLED)
			{
				if (FindStringInArray(excludeMaps, event_map) != -1)
				{
					status = MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_PREVIOUS;
				}
			}
			g_EventMenu.AddItem(event_map, event_map);
			g_mapInfo.SetArray(event_map, map_info, sizeof(map_info));			//add those informations to our temporary database
			g_mapTrie.SetValue(event_map, status);
		}
		while (kv.GotoNextKey());
	}
	kv.GoBack();

	g_MapMenu.ExitButton = true;
	g_EventMenu.ExitButton = true;

	delete excludeMaps;
}

public int Handler_MapSelectMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char map[PLATFORM_MAX_PATH], name[MAX_NAME_LENGTH], displayName[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map), _, displayName, sizeof(displayName));
			char ply[2], s_map[PLATFORM_MAX_PATH];
			IntToString(param1, ply, sizeof(ply));
			int map_info_player[2] =  { 0, 0 };
			
			GetClientName(param1, name, sizeof(name));
			
			if(HasNominated.GetString(ply, s_map, sizeof(s_map)))
			{
				if(g_mapInfo.GetArray(s_map, map_info_player, 2))
				{
					++map_info_player[0];
					g_mapInfo.SetArray(s_map, map_info_player, 2);
					if(RemoveNominationByMap(s_map))
					{
						PrintToChatAll("[SM] %t", "Map Removed", s_map);
					}
				}
			}
			HasNominated.SetString(ply, map);
	
			NominateResult result = NominateMap(map, false, param1);
			
			/* Don't need to check for InvalidMap because the menu did that already */
			if (result == Nominate_AlreadyInVote)
			{
				PrintToChat(param1, "[SM] %t", "Map Already Nominated");
				return 0;
			}
			else if (result == Nominate_VoteFull)
			{
				PrintToChat(param1, "[SM] %t", "Max Nominations");
				return 0;
			}
			
			g_mapTrie.SetValue(map, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);
			PrintToChatAll("[SM] %t", "Map Nominated", name, displayName);
			return 0;
		}
		
		case MenuAction_DrawItem:
		{
			char map[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map));
			
			int status;
			
			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return ITEMDRAW_DEFAULT;
			}
			
			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
			{
				return ITEMDRAW_DISABLED;	
			}
			
			return ITEMDRAW_DEFAULT;
						
		}
		
		case MenuAction_DisplayItem:
		{
			char map[PLATFORM_MAX_PATH], displayName[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map), _, displayName, sizeof(displayName));
			
			int status;
			
			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return 0;
			}
			
			char display[PLATFORM_MAX_PATH + 64];
			
			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
			{
				if ((status & MAPSTATUS_EXCLUDE_CURRENT) == MAPSTATUS_EXCLUDE_CURRENT)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Current Map", param1);
					return RedrawMenuItem(display);
				}
				
				if ((status & MAPSTATUS_EXCLUDE_PREVIOUS) == MAPSTATUS_EXCLUDE_PREVIOUS)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Recently Played", param1);
					return RedrawMenuItem(display);
				}
				
				if ((status & MAPSTATUS_EXCLUDE_NOMINATED) == MAPSTATUS_EXCLUDE_NOMINATED)
				{
					Format(display, sizeof(display), "%s (%T)", displayName, "Nominated", param1);
					return RedrawMenuItem(display);
				}
			}
			
			return 0;
		}
	}
	
	return 0;
}

public int Handler_PreMapSelectMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_Select:
		{
			switch(param2)
			{
				case 0:
				{
					g_MapMenu.SetTitle("%T", "Nominate Title", param1);
					g_MapMenu.Display(param1, MENU_TIME_FOREVER);
					return 0;
				}
				case 1:
				{
					g_EventMenu.SetTitle("%T", "Nominate Title", param1);
					g_EventMenu.Display(param1, MENU_TIME_FOREVER);
					return 0;
				}
			}
		}
	}
	return 0;
}

public int Handler_EventMapSelectMenu(Menu menu, MenuAction action, int param1, int param2)
{
	int playercount = -1, nominations = -1;
	int map_info[2] =  { 0, 0 }, map_info_player[2] = {0, 0};
	char ply[2];
	char s_map[PLATFORM_MAX_PATH];
	IntToString(param1, ply, sizeof(ply));
	
	switch (action)
	{
		case MenuAction_Select:
		{	
			char map[PLATFORM_MAX_PATH], name[MAX_NAME_LENGTH];
			menu.GetItem(param2, map, sizeof(map));
			
			GetClientName(param1, name, MAX_NAME_LENGTH);
	
			g_mapInfo.GetArray(map, map_info, 2);
	
			nominations = map_info[0];
			playercount = map_info[1];
	
			if(HasNominated.GetString(ply, s_map, sizeof(s_map)))
			{
				if (StrEqual(s_map, map))
				{
					ReplyToCommand(param1, "[SM] %t", "Already Voted");
					return 0;
				}
				if(g_mapInfo.GetArray(s_map, map_info_player, 2))
				{
					++map_info_player[0];
					g_mapInfo.SetArray(s_map, map_info_player, 2);
				}
				if(RemoveNominationByMap(s_map))
				{
					PrintToChatAll("[SM] %t", "Map Removed", s_map);
				}
			}
			if(playercount <= ply_count)
			{
				if(nominations > 0)
				{
					HasNominated.SetString(ply, map);
					--nominations;
					map_info[0] = nominations;
					g_mapInfo.SetArray(map, map_info, 2);
					if(nominations > 0)
					{
						PrintToChatAll("[SM] %t", "Votes Needed", name, map, nominations);
						return 0;
					}
				}
			}
			else
			{
				ReplyToCommand(param1, "[SM] %t", "Players Needed", playercount - ply_count);
				return 0;
			}
			
			NominateResult result = NominateMap(map, true, param1);
			
			/* Don't need to check for InvalidMap because the menu did that already */
			if (result == Nominate_AlreadyInVote)
			{
				PrintToChat(param1, "[SM] %t", "Map Already Nominated");
				return 0;
			}
			else if (result == Nominate_VoteFull)
			{
				PrintToChat(param1, "[SM] %t", "Max Nominations");
				return 0;
			}
			
			g_mapTrie.SetValue(map, MAPSTATUS_DISABLED|MAPSTATUS_EXCLUDE_NOMINATED);

			if (result == Nominate_Replaced)
			{
				PrintToChatAll("[SM] %t", "Map Nomination Changed", name, map);
				return 0;	
			}
			
			PrintToChatAll("[SM] %t", "Map Voted", map);
			LogMessage("%s nominated %s", name, map);
		}
		
		case MenuAction_DrawItem:
		{
			char map[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map));
			g_mapInfo.GetArray(map, map_info, 2);
			nominations = map_info[0];
			playercount = map_info[1];
			
			int status;
			
			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return ITEMDRAW_DEFAULT;
			}
			HasNominated.GetString(ply, s_map, sizeof(s_map));
			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED || playercount > ply_count || StrEqual(s_map, map))
			{
				return ITEMDRAW_DISABLED;	
			}
			
			return ITEMDRAW_DEFAULT;		
		}
		
		case MenuAction_DisplayItem:
		{
			char map[PLATFORM_MAX_PATH];
			menu.GetItem(param2, map, sizeof(map));
			g_mapInfo.GetArray(map, map_info, 2);
			nominations = map_info[0];
			playercount = map_info[1];

			int status;
			
			if (!g_mapTrie.GetValue(map, status))
			{
				LogError("Menu selection of item not in trie. Major logic problem somewhere.");
				return 0;
			}
			
			char buffer[100];
			char display[150];
			
			strcopy(buffer, sizeof(buffer), map);
			
			if ((status & MAPSTATUS_DISABLED) == MAPSTATUS_DISABLED)
			{
				if ((status & MAPSTATUS_EXCLUDE_CURRENT) == MAPSTATUS_EXCLUDE_CURRENT)
				{
					Format(display, sizeof(display), "%s (%T)", buffer, "Current Map", param1);
					return RedrawMenuItem(display);
				}
				
				if ((status & MAPSTATUS_EXCLUDE_PREVIOUS) == MAPSTATUS_EXCLUDE_PREVIOUS)
				{
					Format(display, sizeof(display), "%s (%T)", buffer, "Recently Played", param1);
					return RedrawMenuItem(display);
				}
				
				if ((status & MAPSTATUS_EXCLUDE_NOMINATED) == MAPSTATUS_EXCLUDE_NOMINATED)
				{
					Format(display, sizeof(display), "%s (%T)", buffer, "Nominated", param1);
					return RedrawMenuItem(display);
				}
			}
			else if(playercount > ply_count)
			{
				Format(display, sizeof(display), "%s (%t)", buffer, "Players Left", playercount - ply_count);
				return RedrawMenuItem(display);
			}
			else if(nominations > 0)
			{
				Format(display, sizeof(display), "%s (%t)", buffer, "Votes Left", nominations);
				return RedrawMenuItem(display);
			}
			return 0;
		}
	}
	return 0;
}