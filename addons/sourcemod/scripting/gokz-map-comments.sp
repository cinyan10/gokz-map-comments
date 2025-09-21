#include <sourcemod>
#include <sdktools>
#include <gokz>
#include <gokz/core>
#include <gokz/localdb>

#pragma semicolon 1
#pragma newdecls required

Database gH_DB = null;
bool g_bRateReminderSent[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "GOKZ Map Rating & Comments",
    author      = "Cinyan10",
    description = "Rate maps (1–5) and leave a short comment. Shows average on spawn. Uses SteamID32. Latest comment per player counts.",
    version     = "1.1.0"
};

// ──────────────────────────────────────────────────────────────────────────────
// Lifecycle
// ──────────────────────────────────────────────────────────────────────────────
public void OnPluginStart()
{
    RegConsoleCmd("sm_rate", Command_Rate, "Usage: !rate <1-5> [comment]");
    RegConsoleCmd("sm_comments", Command_ShowComments, "Show latest comments for this map");

    // DB
    gH_DB = GOKZ_DB_GetDatabase();
    if (gH_DB == null)
    {
        CreateTimer(2.0, Timer_RetryDB, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    else
    {
        DB_EnsureTables();
    }
}

public void OnMapStart()
{
    // reset per-map prompt flags
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bRateReminderSent[i] = false;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Events & Timers
// ──────────────────────────────────────────────────────────────────────────────
public Action Timer_RetryDB(Handle timer)
{
    if (gH_DB == null)
    {
        gH_DB = GOKZ_DB_GetDatabase();
        if (gH_DB == null) return Plugin_Continue;
        DB_EnsureTables();
    }
    return Plugin_Stop;
}

public void GOKZ_OnFirstSpawn(int client)
{
    if (!IsValidClient(client)) return;
    CreateTimer(2.0, Timer_ShowAvgOne, GetClientUserId(client));
}

public Action Timer_ShowAvgOne(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client)) return Plugin_Stop;
    DB_ShowMapAverage(client);
    return Plugin_Stop;
}

// After finish, remind 3 seconds later (once per player per map)
public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
    if (!IsValidClient(client)) return;
    CreateTimer(3.0, Timer_PromptRateIfNeeded, GetClientUserId(client));
}

public Action Timer_PromptRateIfNeeded(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client)) return Plugin_Stop;

    if (!g_bRateReminderSent[client])
    {
        g_bRateReminderSent[client] = true;
        GOKZ_PrintToChat(client, true, "{lime}Use {gold}!rate <1-5> [comment]{default} to rate the current map, for example: {gold}!rate 5 This map is great");
    }
    return Plugin_Stop;
}

// ──────────────────────────────────────────────────────────────────────────────
// Command: !rate <1-5> [comment]
// ──────────────────────────────────────────────────────────────────────────────
public Action Command_Rate(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    if (gH_DB == null)
    {
        PrintToChat(client, "\x05[Rate]\x01 Database not ready yet. Try again shortly.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        PrintToChat(client, "\x05[Rate]\x01 Usage: \x04!rate <1-5> [comment]");
        return Plugin_Handled;
    }

    char sRating[8];
    GetCmdArg(1, sRating, sizeof(sRating));
    int rating = StringToInt(sRating);
    if (rating < 1 || rating > 5)
    {
        PrintToChat(client, "\x05[Rate]\x01 Rating must be between \x041\x01 and \x045\x01.");
        return Plugin_Handled;
    }

    char comment[256] = "";
    if (args >= 2)
    {
        GetCmdArgString(comment, sizeof(comment)); // full input after command
        TrimString(comment);
        int firstSpace = FindCharInString(comment, ' '); // remove rating token
        if (firstSpace >= 0)
        {
            strcopy(comment, sizeof(comment), comment[firstSpace + 1]);
            TrimString(comment);
        }
        else
        {
            comment[0] = '\0';
        }
    }

    int steam32 = GetSteamAccountID(client);

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    // Pack context for async eligibility + MapID lookup
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteCell(rating);
    dp.WriteCell(steam32);
    dp.WriteString(comment);

    // Query: find MapID by name and check if player has a Times row for this map (course=0)
    char escMap[PLATFORM_MAX_PATH * 2 + 1];
    SQL_EscapeString(gH_DB, mapName, escMap, sizeof(escMap));

    char query[1024];
    FormatEx(query, sizeof(query),
        "SELECT m.MapID, EXISTS( \
            SELECT 1 FROM Times t \
            JOIN MapCourses mc ON t.MapCourseID = mc.MapCourseID \
            WHERE t.SteamID32 = %d AND mc.MapID = m.MapID AND mc.Course = 0 \
        ) AS eligible \
        FROM Maps m WHERE m.Name = '%s' LIMIT 1;",
        steam32, escMap);

    SQL_TQuery(gH_DB, DB_CheckEligibleThenInsert, query, dp);

    return Plugin_Handled;
}

// ──────────────────────────────────────────────────────────────────────────────
// DB ensure / helpers
// ──────────────────────────────────────────────────────────────────────────────
void DB_EnsureTables()
{
    if (gH_DB == null) return;

    char createSql[1024];
    strcopy(createSql, sizeof(createSql),
        "CREATE TABLE IF NOT EXISTS MapComments ( \
            id INT UNSIGNED NOT NULL AUTO_INCREMENT, \
            map_id INT UNSIGNED NOT NULL, \
            map_name VARCHAR(30) NOT NULL, \
            steamid32 INT UNSIGNED NOT NULL, \
            rating TINYINT UNSIGNED NOT NULL, \
            comment TEXT NULL, \
            created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, \
            PRIMARY KEY (id), \
            INDEX idx_mc_map (map_id), \
            INDEX idx_mc_map_player (map_id, steamid32, created_at) \
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    );
    SQL_TQuery(gH_DB, DB_Generic_CB, createSql);
}

void DB_ShowMapAverage(int client)
{
    if (gH_DB == null || !IsValidClient(client)) return;

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char escMap[PLATFORM_MAX_PATH * 2 + 1];
    SQL_EscapeString(gH_DB, mapName, escMap, sizeof(escMap));

    char query[1024];
    // Latest rating per player for this map_name, then average/count.
    FormatEx(query, sizeof(query),
        "SELECT ROUND(AVG(mc1.rating), 2) AS avg_rating, COUNT(*) AS cnt \
         FROM MapComments mc1 \
         JOIN ( \
             SELECT steamid32, MAX(created_at) AS max_created \
             FROM MapComments \
             WHERE map_name = '%s' \
             GROUP BY steamid32 \
         ) last ON last.steamid32 = mc1.steamid32 AND last.max_created = mc1.created_at \
         WHERE mc1.map_name = '%s';",
        escMap, escMap);

    SQL_TQuery(gH_DB, DB_Average_CB, query, GetClientUserId(client));
}


// ──────────────────────────────────────────────────────────────────────────────
// DB Callbacks
// ──────────────────────────────────────────────────────────────────────────────
public void DB_Generic_CB(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
        LogError("[MapRating] DB error: %s", error);
}

public void DB_CheckEligibleThenInsert(Database db, DBResultSet res, const char[] error, any data)
{
    DataPack dp = view_as<DataPack>(data);
    dp.Reset();
    int userid = dp.ReadCell();
    int rating = dp.ReadCell();
    int steam32 = dp.ReadCell();
    char comment[256];
    dp.ReadString(comment, sizeof(comment));
    delete dp;

    int client = GetClientOfUserId(userid);
    if (!client || !IsValidClient(client)) return;

    if (error[0])
    {
        LogError("[MapRating] Eligible check error: %s", error);
        return;
    }

    if (res == null || !res.FetchRow())
    {
        GOKZ_PrintToChat(client, true, "{red}This map has not been registered in the database yet");
        return;
    }

    int map_id = res.FetchInt(0);
    bool eligible = res.FetchInt(1) != 0;
    if (!eligible)
    {
        GOKZ_PlayErrorSound(client);
        GOKZ_PrintToChat(client, true, "{red}You can only rate after completing the current map (main course)");
        return;
    }

    char escComment[512];
    SQL_EscapeString(gH_DB, comment, escComment, sizeof(escComment));

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char escMapName[PLATFORM_MAX_PATH * 2 + 1];
    SQL_EscapeString(gH_DB, mapName, escMapName, sizeof(escMapName));

    char query[1024];
    if (escComment[0])
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO MapComments (map_id, map_name, steamid32, rating, comment) \
             VALUES (%d, '%s', %d, %d, '%s');",
            map_id, escMapName, steam32, rating, escComment);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "INSERT INTO MapComments (map_id, map_name, steamid32, rating, comment) \
             VALUES (%d, '%s', %d, %d, NULL);",
            map_id, escMapName, steam32, rating);
    }

    // Chain to insert callback
    SQL_TQuery(gH_DB, DB_InsertRating_CB, query, userid);
}

public void DB_InsertRating_CB(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (error[0])
    {
        if (client) PrintToChat(client, "\x05[Rate]\x01 Database error: %s", error);
        LogError("[MapRating] Insert error: %s", error);
        return;
    }

    if (client)
    {
        GOKZ_PrintToChat(client, true, "{lime}Your rating has been recorded");
        CreateTimer(0.3, Timer_ShowAvgOne, userid);
    }
}

public void DB_Average_CB(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!client || !IsValidClient(client)) return;

    if (error[0])
    {
        LogError("[MapRating] Avg error: %s", error);
        return;
    }

    float avg = 0.0;
    int cnt = 0;

    if (results != null && results.FetchRow())
    {
        avg = results.FetchFloat(0);
        cnt = results.FetchInt(1);
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    if (cnt <= 0)
    {
        GOKZ_PrintToChat(client, true, "{yellow}The current map {gold}%s{yellow} has no ratings yet, be the first to rate it: {gold}!rate 1-5 [comment]", mapName);
        return;
    }

    char stars[32];
    BuildStars(avg, stars, sizeof(stars));
    GOKZ_PrintToChat(client, true, "{lime}%s{default} — Average rating: {gold}%.2f{default} %s ({gold}%d{default} players) | Use {gold}!rate{default} to add your rating", mapName, avg, stars, cnt);
}

void BuildStars(float avg, char[] buffer, int maxlen)
{
    int filled = RoundToNearest(avg);
    if (filled < 0) filled = 0;
    if (filled > 5) filled = 5;

    buffer[0] = '\0';

    char FILLED[] = "★";
    char EMPTY[]  = "☆";

    for (int i = 0; i < filled; i++)
        StrCat(buffer, maxlen, FILLED);

    for (int i = filled; i < 5; i++)
        StrCat(buffer, maxlen, EMPTY);
}

public Action Command_ShowComments(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;
    if (gH_DB == null)
    {
        GOKZ_PrintToChat(client, true, "{red}The database is not ready yet, please try again later");
        return Plugin_Handled;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char escMap[PLATFORM_MAX_PATH * 2 + 1];
    SQL_EscapeString(gH_DB, mapName, escMap, sizeof(escMap));

    char query[1024];
    // Latest comment per player for current map, newest first
    FormatEx(query, sizeof(query),
        "SELECT mc1.steamid32, COALESCE(p.Alias, CAST(mc1.steamid32 AS CHAR)) AS alias, mc1.rating, COALESCE(mc1.comment,'') AS comment, mc1.created_at \
         FROM MapComments mc1 \
         LEFT JOIN Players p ON p.SteamID32 = mc1.steamid32 \
         JOIN ( \
            SELECT steamid32, MAX(created_at) AS max_created \
            FROM MapComments \
            WHERE map_name = '%s' \
            GROUP BY steamid32 \
         ) last ON last.steamid32 = mc1.steamid32 AND last.max_created = mc1.created_at \
         WHERE mc1.map_name = '%s' \
         ORDER BY mc1.created_at DESC;",
        escMap, escMap);

    SQL_TQuery(gH_DB, DB_BuildCommentsMenu, query, GetClientUserId(client));
    return Plugin_Handled;
}

public int CommentsMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End) { delete menu; }
    return 0;
}

public void DB_BuildCommentsMenu(Database db, DBResultSet res, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client)) return;

    if (error[0])
    {
        GOKZ_PrintToChat(client, true, "{red}Failed to load comments: %s", error);
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    Menu menu = new Menu(CommentsMenu_Handler);
    menu.SetTitle("【%s】Latest Comments", mapName);
    menu.Pagination = 6;
    menu.ExitButton = true;
    menu.ExitBackButton = false;

    int rows = 0;
    while (res != null && res.FetchRow())
    {
        rows++;
        char alias[64]; res.FetchString(1, alias, sizeof(alias));
        int rating = res.FetchInt(2);
        char comment[128]; res.FetchString(3, comment, sizeof(comment));

        char line[192];
        Format(line, sizeof(line), "%d ★  |  %s  |  %s", rating, alias, comment);

        // Not clickable
        menu.AddItem("row", line, ITEMDRAW_DEFAULT);
    }

    if (rows == 0)
    {
        menu.AddItem("", "No comments yet", ITEMDRAW_DISABLED);
    }

    menu.Display(client, 0);
}
