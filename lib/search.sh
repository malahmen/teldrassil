# shellcheck shell=bash
# lib/search.sh — search: items, npcs, objects, quests, teleports in the world
# database; characters, bots and guilds in the characters database.
#
# cmangos keeps one row per item or creature (vmangos keeps one per patch, so
# nordrassil's search has to pick the version; this one does not).
#
# Part of teldrassil.sh, which sources it; not meant to run on its own.

# _like <term> — an escaped LIKE pattern: %term%, with % and _ in it literal.
_like() {
    local t="${1//\\/\\\\}"; t="${t//%/\\%}"; t="${t//_/\\_}"
    _sql_str "%${t}%"
}

cmd_search() {
    local kind="" term="" limit=50
    local -a cflags=()
    while [[ $# -gt 0 ]]; do case "$1" in
        --kind)  _need_value "$@"; kind="$2"; shift 2 ;;
        --term)  _need_value "$@"; term="$2"; shift 2 ;;
        --limit) _need_value "$@"; limit="$2"; shift 2 ;;
        --zone|--class|--race|--level|--guild) _need_value "$@"; cflags+=("$1" "$2"); shift 2 ;;
        --online|--roster-only|--random-only) cflags+=("$1"); shift ;;
        *) error_exit "search: unknown flag $1" ;;
    esac; done
    [[ "$kind" =~ ^(items|npcs|objects|quests|teleports|characters|bots|guilds)$ ]] \
        || error_exit "search: --kind must be items|npcs|objects|quests|teleports|characters|bots|guilds."
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || error_exit "search: --limit must be a positive number."
    case "$kind" in
        characters|bots|guilds) ;;
        *) [[ -n "$term" ]] || error_exit "search: --term is required for ${kind}." ;;
    esac
    if (( ${#cflags[@]} )) && [[ "$kind" != characters && "$kind" != bots ]]; then
        error_exit "search: --zone, --class, --race, --level, --guild, --online, --roster-only and --random-only are for characters and bots."
    fi
    _require_db
    local like=""; [[ -n "$term" ]] && like="$(_like "$term")"
    local W="$DB_WORLD" C="$DB_CHARACTERS"
    case "$kind" in
        items)
            printf '%s\n' "SELECT entry, name, Quality AS quality, ItemLevel AS ilvl, RequiredLevel AS req
                FROM ${W}.item_template WHERE name LIKE ${like} ORDER BY name LIMIT ${limit};" | _db_table ;;
        npcs)
            printf '%s\n' "SELECT ct.Entry AS entry, ct.Name AS name, ct.SubName AS subname,
                    CONCAT(ct.MinLevel, IF(ct.MaxLevel<>ct.MinLevel, CONCAT('-', ct.MaxLevel), '')) AS level,
                    COUNT(c.guid) AS spawns, GROUP_CONCAT(DISTINCT c.map ORDER BY c.map) AS maps
                FROM ${W}.creature_template ct LEFT JOIN ${W}.creature c ON c.id = ct.Entry
                WHERE ct.Name LIKE ${like} GROUP BY ct.Entry ORDER BY ct.Name LIMIT ${limit};" | _db_table ;;
        objects)
            # Herb and ore nodes, chests, doors... with how many spawns and on
            # which maps: the 'where is Peacebloom?' behind a farm order.
            printf '%s\n' "SELECT gt.entry, gt.name, gt.type, COUNT(g.guid) AS spawns,
                    GROUP_CONCAT(DISTINCT g.map ORDER BY g.map) AS maps
                FROM ${W}.gameobject_template gt LEFT JOIN ${W}.gameobject g ON g.id = gt.entry
                WHERE gt.name LIKE ${like} GROUP BY gt.entry ORDER BY gt.name LIMIT ${limit};" | _db_table ;;
        quests)
            printf '%s\n' "SELECT entry, Title AS title, QuestLevel AS level, MinLevel AS min, ZoneOrSort AS zone_or_sort
                FROM ${W}.quest_template WHERE Title LIKE ${like} ORDER BY Title LIMIT ${limit};" | _db_table ;;
        teleports)
            # game_tele - the table '.tele <name>' itself searches.
            printf '%s\n' "SELECT id, name, map, ROUND(position_x, 1) AS x, ROUND(position_y, 1) AS y
                FROM ${W}.game_tele WHERE name LIKE ${like} ORDER BY name LIMIT ${limit};" | _db_table ;;
        guilds)
            local where=""; [[ -n "$like" ]] && where="WHERE g.name LIKE ${like}"
            printf '%s\n' "SELECT g.guildid AS id, g.name, l.name AS leader,
                    IF(la.username LIKE '${BOT_ACCOUNT_PREFIX}%', 'bot', 'player') AS led_by,
                    (SELECT COUNT(*) FROM ${C}.guild_member m WHERE m.guildid = g.guildid) AS members,
                    (SELECT COUNT(*) FROM ${C}.guild_member m JOIN ${C}.characters c ON c.guid = m.guid
                        WHERE m.guildid = g.guildid AND c.online = 1) AS online,
                    (SELECT COUNT(*) FROM ${C}.guild_rank r WHERE r.guildid = g.guildid) AS ranks,
                    CONCAT_WS('/', g.EmblemStyle, g.EmblemColor, g.BorderStyle, g.BorderColor, g.BackgroundColor) AS tabard
                FROM ${C}.guild g LEFT JOIN ${C}.characters l ON l.guid = g.leaderguid
                LEFT JOIN ${DB_REALMD}.account la ON la.id = l.account
                ${where} ORDER BY g.name LIMIT ${limit};" | _db_table ;;
        characters|bots)
            local d; d="$(tmp_dir)"
            printf '%s\n' "SET SESSION group_concat_max_len = 268435456;
                SELECT JSON_ARRAYAGG(JSON_OBJECT('guid', c.guid, 'name', c.name, 'race', c.race, 'class', c.class,
                    'level', c.level, 'online', c.online, 'zone', c.zone, 'map', c.map,
                    'bot', a.username LIKE '${BOT_ACCOUNT_PREFIX}%', 'guild', g.name, 'rank', r.rname))
                FROM ${C}.characters c LEFT JOIN ${DB_REALMD}.account a ON a.id = c.account
                LEFT JOIN ${C}.guild_member m ON m.guid = c.guid LEFT JOIN ${C}.guild g ON g.guildid = m.guildid
                LEFT JOIN ${C}.guild_rank r ON r.guildid = m.guildid AND r.rid = m.\`rank\`;" | _db_raw > "$d/chars.json"
            local -a f=(--rows "$d/chars.json" --dbc "$DBC_DIR" --limit "$limit" --kind "$([[ $kind == bots ]] && echo bot || echo all)")
            [[ -n "$term" ]] && f+=(--term "$term")
            [[ -n "$ROSTER_FILE" && -r "$ROSTER_FILE" ]] && f+=(--roster "$ROSTER_FILE")
            helper chars "${f[@]}" "${cflags[@]}" ;;
    esac
}
