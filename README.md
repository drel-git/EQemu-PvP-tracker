<p align="center">
  <img src="docs/eqemupvptrackerbanner.png" alt="PvP Tracker Banner" />
</p>

# EQemu PvP Tracker

Zone-agnostic PvP tracker for EQEmu servers.  
Logs player-vs-player kills during timed events, announces kills, keeps temporary per-event stats, and exports results in **Markdown** (for Discord) and **CSV** (for spreadsheets).


---

## ✨ Features
- Zone-agnostic - auto-detects zone via `eq.get_zone_short_name()`
- Zonewide PvP announcements in yellow text --> PvP: Disto has slain Drel! (Event Kills: 3)
- Temporary event storage - kills/deaths stored with TTL (default ~36h)
  - configurable by changing `local EVENT_TTL_SECONDS = 36 * 60 * 60  -- ~36h`
- Anti-feed protection - ignores repeat killer→victim within a timeframe (default OFF 0s)
  - configurable by changing `local ANTI_FEED_SECONDS = 45`
- Sortable leaderboard - ranked by kills, then K/D, then deaths.
- Exports (GM-only):  
  - Markdown snapshot for Discord.  
  - CSV snapshot (per-event).  
  - Fresh CSV file written in **write mode (`w`)** so each export overwrites the old one.
- Pagination — `!event top` and `!event post` support N + page.

---

## 🚀 Quickstart
1. **Place the script** --> Copy `player.lua` into each zone you want to support e.g.:
   - `quests/northkarana/player.lua`  
   - `quests/eastcommons/player.lua`  
   - … or symlink one copy across zones.

2. **Ensure folders exist** --> Create `quests/<zone>/` folders (Lua won’t auto-create).

3. **Reload quests**
   - `#reloadquest`

4. **Run an event** --> **!event start <optional_name> <optional_minutes>**
   - Example: `!event start MYSTERYEVENT4 120`

5. **Export results** (at the end)  
   - `!event export`  
   - Outputs:  
     - `<zone>_pvp_event_<EID>.md` (Markdown snapshot)  
     - `<zone>_pvp_event_<EID>.csv` (CSV snapshot)  
     - `quests/<zone>/<zone>_event.csv` (fresh overwrite each export)

---

## 🛠 Commands

**GM Commands**
- `!event start [name] [minutes]` - start event (optional label/duration)  
- `!event stop` - stop the active event  
- `!event clear` - clear event ID/data  
- `!event post [N] [page]` - broadcast leaderboard to zone/world  
- `!event export` - export Markdown + CSV (GM-only)  

**Player Commands**
- `!event` - show help  
- `!event me` - show your kills/deaths/KD  
- `!event top [N] [page]` - show top N players (default 10), paginated   

---

## 📂 File Outputs
On `!event export` (GM-only):
- **Markdown snapshot:** `<zone>_pvp_event_<EID>.md`
- **CSV snapshot:** `<zone>_pvp_event_<EID>.csv`
- **Fresh CSV (overwrites):** `quests/<zone>/<zone>_event.csv`
