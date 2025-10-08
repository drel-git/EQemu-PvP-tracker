-- PvP Event Tracker (zone-agnostic)
-- - Zone/world yellow announce on PvP kills
-- - Temporary (event-scoped) kills/deaths in Data Buckets (TTL)
-- - Deterministic Event IDs: YYYYMMDD-HHMM[-Name]
-- - GM: start/stop/clear/export/post | Players: me/top/status (with pagination)
-- - Export writes Markdown snapshot and a fresh CSV file (write mode)
-- Place this file as quests/<zone>/player.lua (or symlink across zones)

----------------------------- CONFIG ---------------------------
local MT_Yellow = 15
local ANNOUNCE_SCOPE = "zone"            -- "zone" or "world" for announcements
local EVENT_TTL_SECONDS = 36 * 60 * 60   -- ~36h; event data expires automatically
local ANTI_FEED_SECONDS = 45             -- ignore repeat killer->victim within N seconds

-- Pagination defaults
local DEFAULT_TOP_N  = 10   -- default "how many" if not specified
local TOP_PAGE_SIZE  = 10   -- default page size for !event top
local POST_PAGE_SIZE = 10   -- default page size for !event post

-- Zone context (used for keys & filenames)
local ZONE = eq.get_zone_short_name() or "zone"

----------------------------- KEYS (scoped to this zone's event) ---------------------------
local function KEY_EVENT_ID()
  return ("%s:event:id"):format(ZONE)
end

local function KEY_EVENT_ACTIVE()
  return ("%s:event:active"):format(ZONE)
end

local function KEY_EVENT_END_TS()
  return ("%s:event:endts"):format(ZONE)
end

local function KEY_INDEX(eid)
  return ("%s:%s:index"):format(ZONE, eid)
end

local function K_NAME(eid, cid)
  return ("%s:%s:name:%d"):format(ZONE, eid, cid)
end

local function K_KILLS(eid, cid)
  return ("%s:%s:kills:%d"):format(ZONE, eid, cid)
end

local function K_DEATHS(eid, cid)
  return ("%s:%s:deaths:%d"):format(ZONE, eid, cid)
end

local function K_LAST_PAIR(eid, kid, vid)
  return ("%s:%s:lastpair:%d:%d"):format(ZONE, eid, kid, vid)
end

----------------------------- DATA BUCKET HELPERS (with TTL) ---------------------------
local function get_s(key)
  local v = eq.get_data(key)
  return (v == nil) and "" or v
end

local function set_s(key, val, ttl)
  local t = ttl or EVENT_TTL_SECONDS
  if t and t > 0 then
    eq.set_data(key, val or "", tostring(math.floor(t)))
  else
    eq.set_data(key, val or "")
  end
end

local function get_n(key)
  local v = get_s(key)
  if v == "" then return 0 end
  return tonumber(v) or 0
end

local function set_n(key, num, ttl)
  set_s(key, tostring(num or 0), ttl)
end

local function incr_n(key, d, ttl)
  set_n(key, get_n(key) + (d or 1), ttl)
end

----------------------------- MISC HELPERS ---------------------------
local function is_gm(c)
  return c and c.valid and c:GetGM()
end

local function zmsg(msg)
  if ANNOUNCE_SCOPE == "world" then
    if eq.world_message then
      eq.world_message(MT_Yellow, msg)
    elseif eq.world_emote then
      eq.world_emote(MT_Yellow, msg)
    else
      eq.debug("world announce not available; falling back to client/zone message")
    end
    return
  end

  if eq.zone_emote then
    eq.zone_emote(MT_Yellow, msg)
  elseif eq.zone_message then
    eq.zone_message(MT_Yellow, msg)
  elseif eq.world_message then
    eq.world_message(MT_Yellow, msg)
  end
end

local function tell(c, msg)
  if c and c.valid then c:Message(MT_Yellow, msg) end
end

local function split_csv(s)
  local t = {}
  if not s or s == "" then return t end
  for part in s:gmatch("([^,]+)") do
    table.insert(t, part)
  end
  return t
end

local function join_csv(t)
  return table.concat(t, ",")
end

local function set_add_csv(s, item)
  local t = split_csv(s)
  local seen = {}
  for _, v in ipairs(t) do seen[v] = true end
  if not seen[item] then table.insert(t, item) end
  return join_csv(t)
end

local function now()
  return os.time()
end

local function fmt_kd(k, d)
  if d <= 0 then return string.format("%.2f", k) end
  return string.format("%.2f", k / d)
end

local function chunk_and_send(client, text)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then tell(client, line) end
  end
end

-- CSV helper: escape a single field (wrap in quotes if needed)
local function csv_escape(s)
  s = tostring(s or "")
  if s:find('[,"\n]') then
    s = '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

-- Deterministic Event IDs: YYYYMMDD-HHMM[-Name]
local function ymd_hm()
  local t = os.date("*t")
  return string.format("%04d%02d%02d-%02d%02d", t.year, t.month, t.day, t.hour, t.min)
end

-- Human-friendly duration (e.g., "1h 23m", "45s")
local function fmt_duration(sec)
  local s = math.floor(sec or 0)
  local h = math.floor(s / 3600); s = s % 3600
  local m = math.floor(s / 60);   s = s % 60
  local parts = {}
  if h > 0 then table.insert(parts, h .. "h") end
  if m > 0 or (h > 0 and s > 0) then table.insert(parts, m .. "m") end
  if h == 0 and m == 0 then table.insert(parts, s .. "s") end
  return table.concat(parts, " ")
end

----------------------------- EVENT LIFECYCLE ---------------------------
local function current_event_id()
  return get_s(KEY_EVENT_ID())
end

local function event_active()
  if get_s(KEY_EVENT_ACTIVE()) ~= "1" then return false end
  local endts = get_n(KEY_EVENT_END_TS())
  if endts > 0 and now() >= endts then
    set_s(KEY_EVENT_ACTIVE(), "0", EVENT_TTL_SECONDS) -- auto stop
    zmsg("PvP Event has auto-ended. Use !event export or !event post to share the results.")
    return false
  end
  return true
end

local function start_event(starter, name_opt, duration_minutes_opt)
  local eid = ymd_hm()

  if name_opt and name_opt ~= "" then
    local name = name_opt
    name = name:gsub("%s+", "-")     -- normalize whitespace to single dashes
    name = name:gsub("[^%w_%-]", "") -- keep alnum / _ / -
    if name ~= "" then
      eid = eid .. "-" .. name
    end
  end

  set_s(KEY_EVENT_ID(), eid, EVENT_TTL_SECONDS)
  set_s(KEY_EVENT_ACTIVE(), "1", EVENT_TTL_SECONDS)

  local dur = tonumber(duration_minutes_opt or 0) or 0
  if dur > 0 then
    set_n(KEY_EVENT_END_TS(), now() + (dur * 60), EVENT_TTL_SECONDS)
  else
    set_n(KEY_EVENT_END_TS(), 0, EVENT_TTL_SECONDS)
  end

  set_s(KEY_INDEX(eid), "", EVENT_TTL_SECONDS) -- fresh index

  zmsg(("PvP Event started%s!"):format(
    (name_opt and name_opt ~= "") and (": " .. name_opt) or ""
  ))
  if dur > 0 then
    zmsg(("Event will auto-end in %d minute(s)."):format(dur))
  end

  tell(starter, "Event ID: " .. eid)
end

local function stop_event(stopper)
  if not event_active() then
    tell(stopper, "No active event.")
    return
  end
  set_s(KEY_EVENT_ACTIVE(), "0", EVENT_TTL_SECONDS)
  zmsg("PvP Event has ended! Use !event export or !event post to share the leaderboard.")
end

local function clear_event(clarifier)
  local eid = current_event_id()
  if eid == "" then
    tell(clarifier, "No event data to clear.")
    return
  end
  set_s(KEY_EVENT_ID(), "", EVENT_TTL_SECONDS)
  set_s(KEY_EVENT_ACTIVE(), "0", EVENT_TTL_SECONDS)
  set_n(KEY_EVENT_END_TS(), 0, EVENT_TTL_SECONDS)
  zmsg("PvP Event data cleared (old stats will expire shortly).")
end

-- Summarize current event status
local function event_status()
  local eid = current_event_id()
  if eid == "" then return false, "No event initialized." end

  local active = event_active()
  local endts  = get_n(KEY_EVENT_END_TS())
  local timeleft = (endts > 0) and math.max(0, endts - now()) or nil

  local ids = split_csv(get_s(KEY_INDEX(eid)))
  local participants, total_k, total_d = 0, 0, 0

  for _, id in ipairs(ids) do
    local k = get_n(K_KILLS(eid, id))
    local d = get_n(K_DEATHS(eid, id))
    if k > 0 or d > 0 then
      participants = participants + 1
      total_k = total_k + k
      total_d = total_d + d
    end
  end

  return true, {
    eid = eid,
    active = active,
    timeleft = timeleft,
    participants = participants,
    total_k = total_k,
    total_d = total_d
  }
end

----------------------------- RECORD KILL/DEATH (ACTIVE EVENT ONLY) ---------------------------
local function record_kill(killer, victim)
  if not event_active() then return end

  local eid = current_event_id()
  if eid == "" then return end

  local kid = killer:CharacterID()
  local vid = victim:CharacterID()

  -- guard against weird self-kills
  if kid == vid then return end

  -- anti-feed: same pair within short window
  local pair_key = K_LAST_PAIR(eid, kid, vid)
  local last_ts = get_n(pair_key)
  if last_ts > 0 and (now() - last_ts) < ANTI_FEED_SECONDS then
    set_n(pair_key, now(), ANTI_FEED_SECONDS) -- refresh window but do not count
    return
  end
  set_n(pair_key, now(), ANTI_FEED_SECONDS)

  -- update names and counts
  set_s(K_NAME(eid, kid), killer:GetCleanName(), EVENT_TTL_SECONDS)
  set_s(K_NAME(eid, vid),  victim:GetCleanName(), EVENT_TTL_SECONDS)
  incr_n(K_KILLS(eid, kid), 1, EVENT_TTL_SECONDS)
  incr_n(K_DEATHS(eid, vid), 1, EVENT_TTL_SECONDS)

  -- maintain participant index
  local idx_key = KEY_INDEX(eid)
  local idx = get_s(idx_key)
  idx = set_add_csv(idx, tostring(kid))
  idx = set_add_csv(idx, tostring(vid))
  set_s(idx_key, idx, EVENT_TTL_SECONDS)

  -- announce (no zone tag, always "PvP")
  local msg = ("PvP: %s has slain %s! (Event Kills: %d)"):format(
    killer:GetCleanName(),
    victim:GetCleanName(),
    get_n(K_KILLS(eid, kid))
  )
  zmsg(msg)
end

----------------------------- BUILD & RENDER LEADERBOARD -----------------------------
-- NOTE: returns *all* rows; callers paginate/slice as needed
local function collect_rows()
  local eid = current_event_id()
  if eid == "" then return {}, "" end

  local ids = split_csv(get_s(KEY_INDEX(eid)))
  local rows = {} -- {name=, kills=, deaths=, ratio=}

  for _, id in ipairs(ids) do
    local k = get_n(K_KILLS(eid, id))
    local d = get_n(K_DEATHS(eid, id))
    if k > 0 or d > 0 then
      local nm = get_s(K_NAME(eid, id))
      if nm == "" then nm = ("#" .. tostring(id)) end
      table.insert(rows, {
        name  = nm,
        kills = k,
        deaths= d,
        ratio = (d == 0) and k or (k / d)
      })
    end
  end

  table.sort(rows, function(a, b)
    if a.kills ~= b.kills then return a.kills > b.kills end
    if a.ratio ~= b.ratio then return a.ratio > b.ratio end
    return a.deaths < b.deaths
  end)

  return rows, eid
end

local function render_table(rows, title)
  local header = string.format("%s\n%s", title, "-------------------------------------------")
  local lines = {
    header,
    string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D")
  }
  for i, r in ipairs(rows) do
    table.insert(lines, string.format("%-5s %-18s %5d %5d %7s",
      "#" .. i, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
  end
  return table.concat(lines, "\n")
end

local function render_markdown(rows, eid)
  local t = { ("**PvP — Event %s**"):format(eid), "", "```" }
  table.insert(t, string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D"))
  for i, r in ipairs(rows) do
    table.insert(t, string.format("%-5s %-18s %5d %5d %7s",
      "#" .. i, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
  end
  table.insert(t, "```")
  table.insert(t, string.format(
    "_Temporary event stats. Will expire ~%dh after last update._",
    math.floor(EVENT_TTL_SECONDS / 3600)
  ))
  return table.concat(t, "\n")
end

-- Pagination helper (used by !event top and !event post)
local function paginate_rows(rows, n, page, default_page_size)
  local total = #rows
  local per = (n and n > 0) and n or (default_page_size or 10)
  local pages = math.max(1, math.ceil(total / per))
  local p = math.max(1, math.min(page and page > 0 and page or 1, pages))
  local start_i = (p - 1) * per + 1
  local end_i = math.min(start_i + per - 1, total)
  local slice = {}
  for i = start_i, end_i do
    table.insert(slice, rows[i])
  end
  return slice, p, pages, total, start_i, end_i
end

----------------------------- COMMANDS ---------------------------
local function handle_command(e)
  local raw = e.message or ""
  if raw:sub(1,1) ~= "!" then return false end

  local msg = raw:lower()
  local tokens = {}
  for t in raw:gmatch("%S+") do
    table.insert(tokens, t)
  end

  -- help
  if msg == "!event" or msg == "!event help" then
    tell(e.self, "PvP Event commands:")
    tell(e.self, "!event start [name …] [minutes]   (GM) — start event (optional name/duration)")
    tell(e.self, "!event stop                        (GM) — stop the active event")
    tell(e.self, "!event clear                       (GM) — clear event id/data (soft)")
    tell(e.self, "!event status                           — show state, time left, participants, totals")
    tell(e.self, "!event me                               — your event K/D")
    tell(e.self, "!event top [N] [page]                  — show top N (default 10), paginated")
    tell(e.self, "!event export                     (GM) — export Markdown + CSV to files")
    tell(e.self, "!event post [N] [page]            (GM) — broadcast leaderboard to zone/world")
    return true
  end

  -- GM: start (supports names with spaces + optional minutes as last token)
  if msg:find("^!event start") == 1 then
    if not is_gm(e.self) then
      tell(e.self, "You do not have permission.")
      return true
    end

    local mins_num = tonumber(tokens[#tokens])  -- last token might be minutes
    local name_tokens = {}
    local last_name_idx = mins_num and (#tokens - 1) or #tokens
    for i = 3, last_name_idx do
      table.insert(name_tokens, tokens[i])
    end
    local name = table.concat(name_tokens, " ")
    start_event(e.self, name, mins_num or "")
    return true
  end

  -- GM: stop (exact match)
  if msg == "!event stop" then
    if not is_gm(e.self) then
      tell(e.self, "You do not have permission.")
      return true
    end
    stop_event(e.self)
    return true
  end

  -- GM: clear (exact match)
  if msg == "!event clear" then
    if not is_gm(e.self) then
      tell(e.self, "You do not have permission.")
      return true
    end
    clear_event(e.self)
    return true
  end

  -- Player/GM: status
  if msg == "!event status" then
    local ok, st = event_status()
    if not ok then
      tell(e.self, st)
      return true
    end

    local lines = {}
    table.insert(lines, string.format("PvP — Event %s", st.eid))
    table.insert(lines, "-------------------------------------------")
    table.insert(lines, "State: " .. (st.active and "ACTIVE" or "INACTIVE"))
    if st.timeleft then
      table.insert(lines, "Time left: " .. fmt_duration(st.timeleft))
    end
    table.insert(lines, string.format("Participants: %d", st.participants))
    table.insert(lines, string.format("Totals: Kills %d, Deaths %d", st.total_k, st.total_d))
    chunk_and_send(e.self, table.concat(lines, "\n"))
    return true
  end

  -- Player: me
  if msg == "!event me" then
    local eid = current_event_id()
    if eid == "" or not event_active() then
      tell(e.self, "No active PvP event.")
      return true
    end
    local cid = e.self:CharacterID()
    local k = get_n(K_KILLS(eid, cid))
    local d = get_n(K_DEATHS(eid, cid))
    tell(e.self, string.format("PvP Event — %s: Kills %d, Deaths %d, K/D %s",
      e.self:GetCleanName(), k, d, fmt_kd(k, d)))
    return true
  end

  -- Player: top [N] [page]
  if msg:find("^!event top") == 1 then
    local n = tonumber(tokens[3] or "") or TOP_PAGE_SIZE
    local page = tonumber(tokens[4] or "") or 1

    local rows, eid = collect_rows()
    if eid == "" then
      tell(e.self, "No event is initialized. GM can start one with !event start")
      return true
    end
    if #rows == 0 then
      tell(e.self, "No PvP stats recorded for this event yet.")
      return true
    end

    local slice, p, pages, total, start_i, end_i =
      paginate_rows(rows, n, page, TOP_PAGE_SIZE)

    if #slice == 0 then
      tell(e.self, string.format("No entries for page %d. Valid pages: 1-%d.", page, pages))
      return true
    end

    local header = string.format(
      "PvP — Event %s | Top %d (Page %d/%d, Showing %d–%d of %d)",
      eid, n, p, pages, start_i, end_i, total
    )

    local lines = {
      header,
      string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D")
    }

    for i, r in ipairs(slice) do
      local global_rank = start_i + i - 1
      table.insert(lines, string.format("%-5s %-18s %5d %5d %7s",
        "#" .. global_rank, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
    end

    if p < pages then
      table.insert(lines, string.format("Use !event top %d %d for next page.", n, p + 1))
    end

    chunk_and_send(e.self, table.concat(lines, "\n"))
    return true
  end

  -- GM: export — Markdown + CSV (fresh file, write mode)
  if msg == "!event export" then
    if not is_gm(e.self) then
      tell(e.self, "You do not have permission to export event data.")
      return true
    end

    local rows_all, eid = collect_rows()
    if eid == "" then
      tell(e.self, "No event is initialized.")
      return true
    end
    if #rows_all == 0 then
      tell(e.self, "No PvP stats recorded for this event yet.")
      return true
    end

    -- top DEFAULT_TOP_N rows
    local rows = {}
    local n = math.min(DEFAULT_TOP_N, #rows_all)
    for i = 1, n do rows[i] = rows_all[i] end

    local md = render_markdown(rows, eid)
    chunk_and_send(e.self, md)

    if eq.write_zone_file then
      local md_file = string.format("%s_pvp_event_%s.md", ZONE, eid)
      eq.write_zone_file(md_file, md)
      tell(e.self, "Saved Markdown export to " .. md_file)
    else
      eq.debug("write_zone_file not available; skipping Markdown file export")
    end

    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local csv = {}
    table.insert(csv, "ExportedAt,EventID")
    table.insert(csv, csv_escape(ts) .. "," .. csv_escape(eid))
    table.insert(csv, "")
    table.insert(csv, "Rank,Name,K,D,KD")
    for i, r in ipairs(rows) do
      table.insert(csv, table.concat({
        tostring(i),
        csv_escape(r.name),
        tostring(r.kills),
        tostring(r.deaths),
        csv_escape(fmt_kd(r.kills, r.deaths))
      }, ","))
    end
    csv = table.concat(csv, "\n") .. "\n"

    local quests_path = string.format("quests/%s/%s_event.csv", ZONE, ZONE)
    local file = io.open(quests_path, "w")
    if not file then
      local fallback = string.format("quests/%s_event.csv", ZONE)
      eq.debug(quests_path .. " could not be opened; trying " .. fallback)
      file = io.open(fallback, "w")
      if not file then
        eq.debug("CSV export failed: could not open either path for writing.")
      else
        file:write(csv)
        file:close()
        tell(e.self, "Saved CSV export to " .. fallback)
      end
    else
      file:write(csv)
      file:close()
      tell(e.self, "Saved CSV export to " .. quests_path)
    end

    if eq.write_zone_file then
      local csv_file = string.format("%s_pvp_event_%s.csv", ZONE, eid)
      eq.write_zone_file(csv_file, csv)
      tell(e.self, "Saved per-event CSV to " .. csv_file)
    else
      eq.debug("write_zone_file not available; skipping CSV snapshot export")
    end

    return true
  end

  -- GM: post [N] [page] — broadcast (paginated)
  if msg:find("^!event post") == 1 then
    if not is_gm(e.self) then
      tell(e.self, "You do not have permission to broadcast event results.")
      return true
    end

    local n = tonumber(tokens[3] or "") or POST_PAGE_SIZE
    local page = tonumber(tokens[4] or "") or 1

    local rows, eid = collect_rows()
    if eid == "" then
      zmsg("No event is initialized.")
      return true
    end
    if #rows == 0 then
      zmsg("No PvP stats recorded for this event yet.")
      return true
    end

    local slice, p, pages, total, start_i, end_i =
      paginate_rows(rows, n, page, POST_PAGE_SIZE)

    if #slice == 0 then
      zmsg(string.format("No entries for page %d. Valid pages: 1-%d.", page, pages))
      return true
    end

    zmsg(string.format(
      "PvP — Event %s | Top %d (Page %d/%d, Showing %d–%d of %d)",
      eid, n, p, pages, start_i, end_i, total
    ))
    zmsg(string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D"))

    for i, r in ipairs(slice) do
      local global_rank = start_i + i - 1
      zmsg(string.format("%-5s %-18s %5d %5d %7s",
        "#" .. global_rank, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
    end

    if p < pages then
      zmsg(string.format("Use !event post %d %d for next page.", n, p + 1))
    end

    return true
  end

  return false
end

----------------------------- EVENTS ---------------------------
function event_enter_zone(e)
  tell(e.self, "PvP: Type !event for commands. GMs can start/stop an event.")
end

function event_say(e)
  if handle_command(e) then return end
end

-- Fires on the KILLER; victim is e.other
function event_pvp_kill(e)
  -- Some server builds do not raise this callback; event_death handles fallback.
  if not event_active() then return end

  local killer = e.self
  local victim = e.other

  if killer and killer.valid and killer:IsClient()
     and victim and victim.valid and victim:IsClient() then
    record_kill(killer:CastToClient(), victim:CastToClient())
  end
end

function event_death(e)
  if not event_active() then return end

  local killer = e.other
  local victim = e.self

  if killer and killer.valid and killer:IsClient()
     and victim and victim.valid and victim:IsClient() then
    -- guard against self-kill just in case
    if killer:CharacterID() == victim:CharacterID() then return end
    record_kill(killer:CastToClient(), victim:CastToClient())
  end
end

function event_connect(e)
  if event_active() then
    local eid = current_event_id()
    if eid ~= "" then
      tell(e.self, ("PvP Event %s is ACTIVE — type !event for info."):format(eid))
    end
  end
end
