#!/bin/bash
# ccmud — text MUD for the Claude Code status line. Pure bash + jq.
#
# Subcommands:
#   render                          — status-line output (multi-line); reads stdin JSON
#   feed-prompt                     — UserPromptSubmit hook (advances turn)
#   feed-stop                       — Stop hook (drains haiku cache, forks next gen)
#   stats                           — JSON dump of state (after decay)
#   preview                         — render once with current state (no stdin)
#   hatch <player_name> [genre]     — start a new save
#   set-genre <genre_id>            — swap active genre (state preserved)
#   list-genres                     — list available genre JSON files
#   debug-set <field> <value>       — manual state mutation
#   usage                           — tail token usage log
#   update                          — pull latest mud.sh from GitHub
#
# State: ~/.claude/mud/state.json (locked via mkdir).
# Genre configs: ~/.claude/mud/genres/<id>.json
# Narrative cache: $TMPDIR/ccmud/<session_id>.next.txt (written by background haiku)
# Token log: ~/.claude/mud/usage.log (append-only CSV)

set -u

MUD_DIR="$HOME/.claude/mud"
STATE_FILE="$MUD_DIR/state.json"
GENRES_DIR="$MUD_DIR/genres"
PROMPTS_DIR="$MUD_DIR/prompts"
LOCK_DIR="$MUD_DIR/.lock"
USAGE_LOG="$MUD_DIR/usage.log"
STORY_LOG="$MUD_DIR/story.log"
SAVES_DIR="$MUD_DIR/saves"
TMPDIR_MUD="${TMPDIR:-/tmp}/ccmud"

JQ=$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)

now() { date +%s; }

# Cross-platform mtime: GNU coreutils first, BSD/macOS fallback.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Cross-platform ISO 8601 → epoch.
iso_to_epoch() {
  local s="$1"
  local e
  e=$(date -d "$s" +%s 2>/dev/null) || e=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$s" +%s 2>/dev/null) || e=0
  printf '%s' "$e"
}

# --- locking (mkdir-based, atomic) ---------------------------------------
acquire_lock() {
  mkdir -p "$MUD_DIR"
  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 60 ]; then
      if [ -d "$LOCK_DIR" ]; then
        local age=$(( $(now) - $(file_mtime "$LOCK_DIR") ))
        [ "$age" -gt 10 ] && rmdir "$LOCK_DIR" 2>/dev/null
      fi
      tries=0
    fi
    sleep 0.05
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
}
release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null
  trap - EXIT
}

# --- default state -------------------------------------------------------
default_state() {
  local player="${1:-玩家}"
  local genre="${2:-dating-sim}"
  local t=$(now)
  local genre_file="$GENRES_DIR/$genre.json"
  local starting_char="" start_scene=""
  if [ -f "$genre_file" ]; then
    starting_char=$("$JQ" -r '.starting_chars[0] // ""' "$genre_file" 2>/dev/null || echo "")
    start_scene=$("$JQ" -r '.scenes[0] // ""' "$genre_file" 2>/dev/null || echo "")
  fi
  starting_char="${starting_char:-雪奈}"
  start_scene="${start_scene:-教室}"

  "$JQ" -n \
    --arg genre "$genre" \
    --arg name "$player" \
    --argjson t "$t" \
    --arg sc "$starting_char" \
    --arg scene "$start_scene" \
    '{
      genre: $genre,
      player_name: $name,
      started_at: $t,
      turn: 0,
      day: 1,
      scene: $scene,
      active_chars: [$sc],
      focus_char: $sc,
      affections: ({} | .[$sc] = 0),
      moods: ({} | .[$sc] = "中立"),
      flags: [],
      inventory: [],
      stats: {},
      events: [],
      last_narrative: "",
      narrative_source: "seed",
      session_id: "",
      last_haiku_at: 0,
      last_haiku_status: "",
      last_interaction: $t,
      alive: true,
      ending: null
    }'
}

ensure_state() {
  mkdir -p "$MUD_DIR" "$TMPDIR_MUD"
  if [ ! -f "$STATE_FILE" ]; then
    default_state > "$STATE_FILE"
  fi
}

# --- bulk state I/O ------------------------------------------------------
# Scalars via \x1f-joined string; nested objects/arrays kept as JSON strings
# in MD_*_json vars, mutated via jq when tags fire.
sload() {
  local raw
  raw=$("$JQ" -r '
    [
      (.genre // "dating-sim"),
      (.player_name // "玩家"),
      (.started_at // 0),
      (.turn // 0),
      (.day // 1),
      (.scene // ""),
      (.focus_char // ""),
      (.last_narrative // ""),
      (.narrative_source // "seed"),
      (.session_id // ""),
      (.last_haiku_at // 0),
      (.last_haiku_status // ""),
      (.last_interaction // 0),
      (if has("alive") then .alive else true end),
      (.ending // "")
    ] | map(tostring) | join("")
  ' "$STATE_FILE")
  IFS=$'\x1f' read -r \
    MD_genre MD_player_name MD_started_at MD_turn MD_day \
    MD_scene MD_focus_char MD_last_narrative MD_narrative_source \
    MD_session_id MD_last_haiku_at MD_last_haiku_status MD_last_interaction \
    MD_alive MD_ending <<<"$raw"
  MD_active_chars_json=$("$JQ" -c '.active_chars // []' "$STATE_FILE")
  MD_affections_json=$("$JQ" -c '.affections // {}' "$STATE_FILE")
  MD_moods_json=$("$JQ" -c '.moods // {}' "$STATE_FILE")
  MD_flags_json=$("$JQ" -c '.flags // []' "$STATE_FILE")
  MD_inventory_json=$("$JQ" -c '.inventory // []' "$STATE_FILE")
  MD_stats_json=$("$JQ" -c '.stats // {}' "$STATE_FILE")
  MD_events_json=$("$JQ" -c '.events // []' "$STATE_FILE")
}

swrite() {
  local tmp="$STATE_FILE.tmp.$$"
  cat > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

DIRTY=0
persist_state() {
  [ "$DIRTY" -eq 0 ] && return
  local end_arg="null"
  if [ -n "$MD_ending" ] && [ "$MD_ending" != "null" ]; then
    end_arg=$("$JQ" -n --arg v "$MD_ending" '$v')
  fi
  "$JQ" -n \
    --arg genre "$MD_genre" \
    --arg name "$MD_player_name" \
    --argjson started "${MD_started_at:-0}" \
    --argjson turn "${MD_turn:-0}" \
    --argjson day "${MD_day:-1}" \
    --arg scene "$MD_scene" \
    --argjson active "$MD_active_chars_json" \
    --arg focus "$MD_focus_char" \
    --argjson aff "$MD_affections_json" \
    --argjson moods "$MD_moods_json" \
    --argjson flags "$MD_flags_json" \
    --argjson inv "$MD_inventory_json" \
    --argjson stats "$MD_stats_json" \
    --argjson events "$MD_events_json" \
    --arg narr "$MD_last_narrative" \
    --arg nsrc "$MD_narrative_source" \
    --arg sid "$MD_session_id" \
    --argjson lha "${MD_last_haiku_at:-0}" \
    --arg lhs "$MD_last_haiku_status" \
    --argjson lint "${MD_last_interaction:-0}" \
    --argjson alive "${MD_alive:-true}" \
    --argjson ending "$end_arg" \
    '{
      genre: $genre, player_name: $name, started_at: $started,
      turn: $turn, day: $day, scene: $scene,
      active_chars: $active, focus_char: $focus,
      affections: $aff, moods: $moods, flags: $flags,
      inventory: $inv, stats: $stats, events: $events,
      last_narrative: $narr, narrative_source: $nsrc,
      session_id: $sid, last_haiku_at: $lha, last_haiku_status: $lhs,
      last_interaction: $lint, alive: $alive, ending: $ending
    }' \
    | swrite
  DIRTY=0
}

# --- decay ---------------------------------------------------------------
# Minimal: in-game day advances every 10 turns; 30+ real days idle = neglect death.
apply_decay() {
  [ "$MD_alive" != "true" ] && return
  local target_day=$(( 1 + ${MD_turn:-0} / 10 ))
  if [ "$target_day" -gt "${MD_day:-1}" ]; then
    MD_day=$target_day
    DIRTY=1
  fi
  local elapsed=$(( $(now) - ${MD_last_interaction:-0} ))
  if [ "$elapsed" -gt $(( 86400 * 30 )) ]; then
    MD_alive=false
    MD_ending="neglect"
    DIRTY=1
  fi
}

# --- genre loader --------------------------------------------------------
# Populates GENRE_* vars from the active genre's JSON. Call after sload.
load_genre() {
  # Always reset the optional bash hooks so a previous genre's overrides
  # don't leak into a new one when set-genre is called within one process.
  unset -f genre_apply_tag genre_event_style 2>/dev/null || true

  local f="$GENRES_DIR/$MD_genre.json"
  if [ ! -f "$f" ]; then
    GENRE_FILE=""
    GENRE_DISPLAY="?"
    GENRE_PRIMARY_LABEL="好感"
    GENRE_PRIMARY_MAX=100
    GENRE_STAT_NAMES_JSON='[]'
    GENRE_STAT_ICONS_JSON='{}'
    GENRE_CHAR_EMOJIS_JSON='{}'
    GENRE_SCENE_DECOS_JSON='{}'
    GENRE_SCENE_AMBIENT_JSON='{}'
    GENRE_FALLBACK_JSON='[]'
    GENRE_BAR_FOCUS="💕"
    GENRE_BAR_OTHER="🤍"
    GENRE_SYSTEM_PROMPT=""
    return 1
  fi
  GENRE_FILE="$f"
  local raw
  raw=$("$JQ" -r '
    [
      (.display_name // "?"),
      (.primary_resource.label // "好感"),
      (.primary_resource.max // 100)
    ] | map(tostring) | join("")
  ' "$f")
  IFS=$'\x1f' read -r GENRE_DISPLAY GENRE_PRIMARY_LABEL GENRE_PRIMARY_MAX <<<"$raw"
  GENRE_STAT_NAMES_JSON=$("$JQ" -c '.stat_names // []' "$f")
  GENRE_STAT_ICONS_JSON=$("$JQ" -c '.stat_icons // {}' "$f")
  GENRE_CHAR_EMOJIS_JSON=$("$JQ" -c '.char_emojis // {}' "$f")
  GENRE_SCENE_DECOS_JSON=$("$JQ" -c '.scene_decos // {}' "$f")
  GENRE_SCENE_AMBIENT_JSON=$("$JQ" -c '.scene_ambient // {}' "$f")
  GENRE_FALLBACK_JSON=$("$JQ" -c '.fallback_snippets // []' "$f")
  GENRE_BAR_FOCUS=$("$JQ" -r '.bar_markers.focus // "💕"' "$f")
  GENRE_BAR_OTHER=$("$JQ" -r '.bar_markers.other // "🤍"' "$f")
  GENRE_SYSTEM_PROMPT=$("$JQ" -r '.system_prompt // ""' "$f")

  # Genre-specific bash hooks: optional file genres/<id>.lib.sh defining
  # functions like genre_apply_tag / genre_event_style. apply_tag and
  # event_style call the genre hook first; if it returns 0 / non-empty the
  # default code is skipped.
  local lib="$GENRES_DIR/$MD_genre.lib.sh"
  if [ -f "$lib" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$lib" 2>/dev/null \
      || printf '[ccmud] warning: failed to source %s\n' "$lib" >&2
    set -u
  fi
  return 0
}

char_emoji() {
  local who="$1"
  printf '%s' "$GENRE_CHAR_EMOJIS_JSON" | "$JQ" -r --arg k "$who" '.[$k] // "👤"'
}

# Push a one-line event into MD_events_json (ring buffer, capped).
EVENTS_MAX=16
push_event() {
  local line="$1"
  [ -z "$line" ] && return
  MD_events_json=$(printf '%s' "$MD_events_json" \
    | "$JQ" -c --arg v "$line" --argjson cap "$EVENTS_MAX" \
        '. + [$v] | (if length > $cap then .[length-$cap:] else . end)')
  DIRTY=1
}

# --- tag parser ----------------------------------------------------------
# Tag DSL (without << >> wrapping):
#   AFFECTION±N:角色      (delta to that char's affection, clamped 0..max)
#   MOOD:心情:角色        (set mood string)
#   SCENE:場景            (change scene)
#   FOCUS:角色            (change focus_char)
#   FLAG±:旗標名          (add or remove flag)
#   ITEM±:物品名          (add to or remove from inventory)
#   STAT±N:屬性           (delta to a player stat, key from genre.stat_names)
#   NEW_CHAR:角色         (add to active_chars; affection=0, mood=中立)
#   ENDING:結局名         (alive=false, ending=<string>)
# Each tag also pushes a one-line MUD-style event into MD_events_json.
# Genre-specific handler (genre_apply_tag) runs first if defined; if it
# returns 0 the tag is considered handled and the default cases are skipped.
apply_tag() {
  local tag="$1"
  if declare -F genre_apply_tag >/dev/null 2>&1; then
    if genre_apply_tag "$tag"; then return; fi
  fi
  local kind body rest sign delta who key val mood
  case "$tag" in
    AFFECTION[+-]*)
      sign="${tag:9:1}"
      body="${tag:10}"
      delta="${body%%:*}"
      who="${body#*:}"
      [ "$sign" = "-" ] && delta="-$delta"
      MD_affections_json=$(printf '%s' "$MD_affections_json" \
        | "$JQ" -c --arg k "$who" --argjson d "${delta:-0}" --argjson max "${GENRE_PRIMARY_MAX:-100}" \
            '.[$k] = ((.[$k] // 0) + $d)
             | .[$k] = (if .[$k] < 0 then 0 elif .[$k] > $max then $max else .[$k] end)')
      DIRTY=1
      if [ "$sign" = "+" ]; then
        push_event "+${delta} 💕 ${who}"
      else
        push_event "${delta} 💔 ${who}"
      fi
      ;;
    MOOD:*)
      body="${tag#MOOD:}"
      mood="${body%%:*}"
      who="${body#*:}"
      [ "$who" = "$body" ] && who="$MD_focus_char"
      MD_moods_json=$(printf '%s' "$MD_moods_json" \
        | "$JQ" -c --arg k "$who" --arg v "$mood" '.[$k] = $v')
      DIRTY=1
      push_event "${who}：${mood}"
      ;;
    SCENE:*)
      MD_scene="${tag#SCENE:}"
      DIRTY=1
      push_event "→ 進入 ${MD_scene}"
      ;;
    FOCUS:*)
      MD_focus_char="${tag#FOCUS:}"
      DIRTY=1
      push_event "✦ 視線：${MD_focus_char}"
      ;;
    FLAG[+-]:*)
      sign="${tag:4:1}"
      val="${tag:6}"
      if [ "$sign" = "+" ]; then
        MD_flags_json=$(printf '%s' "$MD_flags_json" \
          | "$JQ" -c --arg v "$val" 'if any(. == $v) then . else . + [$v] end')
        push_event "▶ 觸發：${val}"
      else
        MD_flags_json=$(printf '%s' "$MD_flags_json" \
          | "$JQ" -c --arg v "$val" 'map(select(. != $v))')
        push_event "⊘ 解除：${val}"
      fi
      DIRTY=1
      ;;
    ITEM[+-]:*)
      sign="${tag:4:1}"
      val="${tag:6}"
      if [ "$sign" = "+" ]; then
        MD_inventory_json=$(printf '%s' "$MD_inventory_json" \
          | "$JQ" -c --arg v "$val" '. + [$v]')
        push_event "✦ 獲得「${val}」"
      else
        MD_inventory_json=$(printf '%s' "$MD_inventory_json" \
          | "$JQ" -c --arg v "$val" '
              . as $arr
              | (if any(. == $v) then ([range(length)] as $idx
                  | $idx | map(select($arr[.] != $v) // null) | map($arr[.]))
                else . end)')
        push_event "✗ 失去「${val}」"
      fi
      DIRTY=1
      ;;
    STAT[+-]*)
      sign="${tag:4:1}"
      body="${tag:5}"
      delta="${body%%:*}"
      key="${body#*:}"
      [ "$sign" = "-" ] && delta="-$delta"
      MD_stats_json=$(printf '%s' "$MD_stats_json" \
        | "$JQ" -c --arg k "$key" --argjson d "${delta:-0}" \
            '.[$k] = ((.[$k] // 0) + $d)')
      DIRTY=1
      if [ "$sign" = "+" ]; then
        push_event "+${delta} 📈 ${key}"
      else
        push_event "${delta} 📉 ${key}"
      fi
      ;;
    NEW_CHAR:*)
      who="${tag#NEW_CHAR:}"
      MD_active_chars_json=$(printf '%s' "$MD_active_chars_json" \
        | "$JQ" -c --arg v "$who" 'if any(. == $v) then . else . + [$v] end')
      MD_affections_json=$(printf '%s' "$MD_affections_json" \
        | "$JQ" -c --arg k "$who" '.[$k] = (.[$k] // 0)')
      MD_moods_json=$(printf '%s' "$MD_moods_json" \
        | "$JQ" -c --arg k "$who" '.[$k] = (.[$k] // "中立")')
      DIRTY=1
      push_event "❉ 相遇：${who}"
      ;;
    ENDING:*)
      MD_ending="${tag#ENDING:}"
      MD_alive=false
      DIRTY=1
      push_event "※ 結局：${MD_ending}"
      ;;
    *)
      printf '[ccmud] unknown tag: %s\n' "$tag" >&2
      ;;
  esac
}

# Drain a haiku narrative file: extract tags, apply them, save the cleaned
# narrative text to MD_last_narrative. Marks DIRTY=1 if anything changed.
# Argument: path to next.txt
# Refusals (Haiku declined to roleplay) are detected by zero tags + refusal
# phrase, and dropped — the previous narrative stays in place.
drain_narrative_file() {
  local f="$1"
  [ ! -s "$f" ] && return 1
  local raw
  raw=$(cat "$f")
  local tags clean
  tags=$(printf '%s' "$raw" | grep -oE '<<[^>]+>>' || true)
  clean=$(printf '%s' "$raw" | sed -E 's/<<[^>]+>>//g')
  clean=$(printf '%s' "$clean" | awk 'NF { print } !NF { next }' | tr -d '\r')
  clean=$(printf '%s' "$clean" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

  # Refusal guard: if zero tags AND text looks like a meta/refusal reply,
  # drop it. Common patterns: 無法/不能/抱歉/Sorry/I (cannot|can't|won't).
  if [ -z "$tags" ] && [ -n "$clean" ]; then
    if printf '%s' "$clean" | grep -qE '無法[完協]|無法[協回]|不能[協回]|很抱歉|對不起|超出.*範圍|^Sorry|I (cannot|can.t|won.t|am unable|.m unable|can.t help)'; then
      MD_last_haiku_status="refused"
      DIRTY=1
      return 1
    fi
  fi

  if [ -n "$tags" ]; then
    while IFS= read -r raw_tag; do
      [ -z "$raw_tag" ] && continue
      local body="${raw_tag#<<}"
      body="${body%>>}"
      apply_tag "$body"
    done <<<"$tags"
  fi

  if [ -n "$clean" ]; then
    MD_last_narrative="$clean"
    MD_narrative_source="haiku"
    DIRTY=1
    append_story "$clean" "$tags"
  fi
  return 0
}

# Append one Haiku-drained entry to story.log. Plain text, human readable.
# Format:
#   ─── Turn 23 · Day 3 · 教室 · focus 雪奈 · 2026-05-08 06:50:23 ───
#   <narrative text>
#   tags: <<TAG1>><<TAG2>>...
#
append_story() {
  local narr="$1" tags="$2"
  mkdir -p "$MUD_DIR"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  {
    printf '─── Turn %d · Day %d · %s · focus %s · %s ───\n' \
      "${MD_turn:-0}" "${MD_day:-1}" "${MD_scene:-?}" "${MD_focus_char:-?}" "$ts"
    printf '%s\n' "$narr"
    if [ -n "$tags" ]; then
      printf 'tags: '
      printf '%s' "$tags" | tr '\n' ' '
      printf '\n'
    fi
    printf '\n'
  } >> "$STORY_LOG"
}

# Pick a random fallback snippet from the genre. Sets MD_last_narrative
# only if currently empty or the source is already "fallback" or "seed".
maybe_fallback_narrative() {
  [ "$MD_narrative_source" = "haiku" ] && return 0
  local count
  count=$(printf '%s' "$GENRE_FALLBACK_JSON" | "$JQ" 'length')
  [ "$count" -le 0 ] && return 0
  local pick=$(( RANDOM % count ))
  local snip
  snip=$(printf '%s' "$GENRE_FALLBACK_JSON" | "$JQ" -r --argjson i "$pick" '.[$i] // ""')
  if [ -n "$snip" ] && [ "$snip" != "$MD_last_narrative" ]; then
    MD_last_narrative="$snip"
    MD_narrative_source="fallback"
    DIRTY=1
  fi
}

# --- LCD frame -----------------------------------------------------------
# Text-MUD scrollback: 6 inner rows show ambient lines (top, dim) overflowing
# into real events (bottom, cyan). Real events come from MD_events_json,
# pushed by apply_tag. Ambient lines come from genre.scene_ambient[scene]
# and only fill rows that don't have a real event yet.
LCD_FRAME_WIDTH=${MUD_LCD_WIDTH:-40}
LCD_CONTENT_ROWS=6

render_lcd_frame() {
  local outer=$LCD_FRAME_WIDTH
  [ "$outer" -lt 12 ] && outer=12
  local inner=$(( outer - 2 ))
  local content_w=$(( inner - 2 ))

  # Read up to LCD_CONTENT_ROWS most-recent events.
  local events_arr=()
  if [ -n "$MD_events_json" ] && [ "$MD_events_json" != "[]" ]; then
    local events_raw
    events_raw=$(printf '%s' "$MD_events_json" \
      | "$JQ" -r --argjson n "$LCD_CONTENT_ROWS" '
          (if length > $n then .[length-$n:] else . end) | .[]')
    if [ -n "$events_raw" ]; then
      while IFS= read -r line; do
        events_arr+=("$line")
      done <<<"$events_raw"
    fi
  fi
  local n_events=${#events_arr[@]}
  [ "$n_events" -gt "$LCD_CONTENT_ROWS" ] && n_events=$LCD_CONTENT_ROWS
  local n_ambient=$(( LCD_CONTENT_ROWS - n_events ))

  # Pick ambient lines for the empty rows.
  local ambient_arr=()
  if [ "$n_ambient" -gt 0 ]; then
    local pool_arr=()
    if [ -n "$MD_scene" ]; then
      local pool_raw
      pool_raw=$(printf '%s' "$GENRE_SCENE_AMBIENT_JSON" \
        | "$JQ" -r --arg s "$MD_scene" '(.[$s] // [])[]?' 2>/dev/null)
      if [ -n "$pool_raw" ]; then
        while IFS= read -r line; do
          pool_arr+=("$line")
        done <<<"$pool_raw"
      fi
    fi
    local plen=${#pool_arr[@]}
    local k
    for ((k=0; k<n_ambient; k++)); do
      if [ "$plen" -gt 0 ]; then
        ambient_arr+=("${pool_arr[$(( RANDOM % plen ))]}")
      else
        ambient_arr+=("")
      fi
    done
  fi

  # Top border with embedded header: "╭── 📍 教室 · Day 2 · Turn 19 ──╮"
  local header=""
  if [ "$MD_alive" = "true" ]; then
    header=$(printf '📍 %s · Day %d · Turn %d' \
      "${MD_scene:-?}" "${MD_day:-1}" "${MD_turn:-0}")
  else
    header=$(printf '💀 END · %s' "${MD_ending:-?}")
  fi
  local hdr_w
  hdr_w=$(vis_width "$header")
  # Layout: ╭── <header> ──...──╮  (4 cells "╭── " + header + 1 space + "─"*N + 1 cell ╮)
  local hdr_pad=$(( inner - 3 - hdr_w - 1 ))
  [ "$hdr_pad" -lt 2 ] && hdr_pad=2
  local i hdash=""
  for ((i=0; i<hdr_pad; i++)); do hdash+="─"; done
  if [ "$MD_alive" = "true" ]; then
    printf '╭── \033[1;33m%s\033[0m %s╮\n' "$header" "$hdash"
  else
    printf '╭── \033[1;31m%s\033[0m %s╮\n' "$header" "$hdash"
  fi

  # Content rows: ambient (dim) for empty top rows, then events.
  local row content style line_w pad
  for ((row=0; row<LCD_CONTENT_ROWS; row++)); do
    local is_event=0
    if [ "$row" -lt "$n_ambient" ]; then
      content="${ambient_arr[row]}"
      style="\033[2;90m"   # darker dim grey for ambient
    else
      content="${events_arr[$(( row - n_ambient ))]}"
      is_event=1
      style=$(event_style "$content")
    fi
    [ "$MD_alive" != "true" ] && style="\033[2;31m"

    content=$(truncate_to_width "$content" "$content_w")
    line_w=$(vis_width "$content")
    pad=$(( content_w - line_w ))
    [ "$pad" -lt 0 ] && pad=0
    printf '│ %b%s\033[0m%*s │\n' "$style" "$content" "$pad" ""
  done

  # Bottom border
  local border2=""
  for ((i=0; i<inner; i++)); do border2+="─"; done
  printf '╰%s╯\n' "$border2"
}

# Pick an ANSI color style for an event line based on its prefix marker.
# Genre-specific style (genre_event_style) runs first if defined; if it
# emits a non-empty string we use it, otherwise fall through to defaults.
event_style() {
  local line="$1"
  if declare -F genre_event_style >/dev/null 2>&1; then
    local s
    s=$(genre_event_style "$line" 2>/dev/null || true)
    if [ -n "$s" ]; then printf '%s' "$s"; return; fi
  fi
  case "$line" in
    "+"*"💕"*)        printf '\033[1;35m' ;;  # bright magenta: + affection
    "-"*"💔"*)        printf '\033[31m'   ;;  # red: - affection
    "→ "*)            printf '\033[33m'   ;;  # yellow: scene change
    "✦ 視線："*)      printf '\033[36m'   ;;  # cyan: focus shift
    "✦ 獲得"*)        printf '\033[32m'   ;;  # green: item gain
    "✗ "*)            printf '\033[31m'   ;;  # red: item loss
    "▶ "*)            printf '\033[1;34m' ;;  # bright blue: flag set
    "⊘ "*)            printf '\033[2;34m' ;;  # dim blue: flag clear
    "❉ "*)            printf '\033[1;35m' ;;  # bright magenta: new char
    "※ "*)            printf '\033[1;31m' ;;  # bright red: ending
    "+"*"📈"*|"+"*"📉"*) printf '\033[32m' ;; # green: stat
    "-"*"📈"*|"-"*"📉"*) printf '\033[31m' ;; # red: stat down
    *)                printf '\033[36m'   ;;  # cyan default (mood lines)
  esac
}

# --- bars ----------------------------------------------------------------
bar() {
  local val=$1 max=$2 width=$3 color=$4
  [ "$max" -le 0 ] && max=1
  local filled=$(( val * width / max ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  local empty=$(( width - filled ))
  local f="" e=""
  local i
  for ((i=0; i<filled; i++)); do f="${f}━"; done
  for ((i=0; i<empty; i++)); do e="${e}─"; done
  printf '\033[%sm%s\033[2;37m%s\033[0m' "$color" "$f" "$e"
}

# --- countdown / token formatting ---------------------------------------
fmt_tokens() {
  local n=${1:-0}
  if   [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
  elif [ "$n" -ge 1000 ];    then awk -v n="$n" 'BEGIN{printf "%.1fk", n/1000}'
  else printf '%d' "$n"
  fi
}

human_countdown() {
  local target=$1 epoch
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    epoch=$target
  else
    epoch=$(iso_to_epoch "$target")
  fi
  local d=$(( epoch - $(now) ))
  if   [ "$d" -le 0 ];     then printf 'now'
  elif [ "$d" -lt 60 ];    then printf '%ds' "$d"
  elif [ "$d" -lt 3600 ];  then printf '%dm' $(( d / 60 ))
  elif [ "$d" -lt 86400 ]; then printf '%dh%dm' $(( d / 3600 )) $(( (d % 3600) / 60 ))
  else                          printf '%dd%dh' $(( d / 86400 )) $(( (d % 86400) / 3600 ))
  fi
}

# --- tail (user@host | model | dir) -------------------------------------
emit_tail() {
  local input="$1"
  local model="" style="" dir_full="" dir="" branch=""
  if [ -n "$input" ]; then
    local raw
    raw=$(printf '%s' "$input" | "$JQ" -r '[
      (.model.display_name // ""),
      (.output_style.name // ""),
      (.workspace.current_dir // "")
    ] | @tsv' 2>/dev/null)
    IFS=$'\t' read -r model style dir_full <<<"$raw"
  fi
  [ -n "$dir_full" ] && dir=$(basename "$dir_full")
  if [ -n "$dir_full" ]; then
    branch=$(git -C "$dir_full" symbolic-ref --short HEAD 2>/dev/null)
    [ -n "$branch" ] && branch=" ($branch)"
  fi
  printf '\033[2m[%s@%s | Claude: %s | %s | %s%s]\033[0m' \
    "$USER" "$(hostname -s 2>/dev/null || hostname)" "${model:-?}" "${style:-?}" "${dir:-?}" "$branch"
}

# --- visual width (CJK + emoji = 2 cells via UTF-8 byte heuristic) ------
# Lead byte → cells mapping (LC_ALL=C so awk iterates bytes):
#   0x00-0x7F (ASCII)            : 1 cell, 1 byte
#   0xC2-0xDF (2-byte: Latin)    : 1 cell, 2 bytes
#   0xE0-0xEF (3-byte)           : 3 bytes, width depends on lead byte:
#     0xE2 (U+2000-U+2FFF: arrows, box drawing, math, geometric, dingbats)
#       : 1 cell — these render narrow in terminals
#     others (0xE3-0xEF: CJK, Hiragana, Katakana, fullwidth forms)
#       : 2 cells
#   0xF0-0xF7 (4-byte: emoji)    : 2 cells, 4 bytes
# ZWJ / combining sequences are still over-counted (known limitation).
WIDE_EMOJIS_BASE=""
vis_width() {
  local s="$1" stripped
  stripped=$(printf '%s' "$s" | sed -E 's/\x1b\[[0-9;]*[mGKHJABCDsuf]//g; s/\x1b\][^\x07]*\x07//g')
  LC_ALL=C printf '%s' "$stripped" | LC_ALL=C awk '
    BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    {
      n = length($0); w = 0; i = 1
      while (i <= n) {
        b = ord[substr($0, i, 1)]
        if      (b < 128) { w += 1; i += 1 }
        else if (b < 192) { i += 1 }
        else if (b < 224) { w += 1; i += 2 }
        else if (b < 240) {
          # 3-byte: lead 0xE2 covers U+2000-U+2FFF (mostly narrow symbols);
          # 0xE3-0xEF covers CJK ranges (wide).
          if (b == 226) { w += 1 } else { w += 2 }
          i += 3
        }
        else              { w += 2; i += 4 }
      }
      total += w
    }
    END { printf "%d", total + 0 }'
}

# Truncate a string so its visual width is at most max cells. If trimmed,
# appends "…". Uses bash codepoint indexing (UTF-8 locale) and treats any
# non-ASCII char as 2 cells.
truncate_to_width() {
  local s="$1" max=$2
  local cur=$(vis_width "$s")
  [ "$cur" -le "$max" ] && { printf '%s' "$s"; return; }
  local n=${#s}
  local out="" w=0 i ch cw
  for ((i=0; i<n; i++)); do
    ch="${s:i:1}"
    cw=$(vis_width "$ch")
    [ -z "$cw" ] && cw=1
    if [ $((w + cw + 1)) -gt "$max" ]; then
      out+="…"
      break
    fi
    out+="$ch"
    w=$((w + cw))
  done
  printf '%s' "$out"
}

# --- render --------------------------------------------------------------
cmd_render() {
  ensure_state

  local stdin_json=""
  [ ! -t 0 ] && stdin_json=$(cat)

  local q5p="" q5r="" q7p="" q7r="" ctx_pct="" session_id=""
  if [ -n "$stdin_json" ]; then
    local quota_raw
    quota_raw=$(printf '%s' "$stdin_json" | "$JQ" -r '[
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // ""),
      (.context_window.used_percentage // ""),
      (.session_id // "")
    ] | map(tostring) | join("")' 2>/dev/null)
    IFS=$'\x1f' read -r q5p q5r q7p q7r ctx_pct session_id <<<"$quota_raw"
  fi

  acquire_lock
  sload
  apply_decay
  # Persist session_id if we just learned a new one — feed-stop will use it
  # to find the right /tmp/ccmud/<sid>.next.txt.
  if [ -n "$session_id" ] && [ "$session_id" != "$MD_session_id" ]; then
    MD_session_id="$session_id"
    DIRTY=1
  fi
  load_genre
  maybe_fallback_narrative
  persist_state
  release_lock

  # Build runtime wide-emoji set (genre char emojis + base set).
  local extra_wide
  extra_wide=$(printf '%s' "$GENRE_CHAR_EMOJIS_JSON" | "$JQ" -r '[.[]] | join("")' 2>/dev/null || echo "")
  WIDE_RUNTIME="${WIDE_EMOJIS_BASE}${extra_wide}"

  local sprite_lines=()
  local stat_lines=()
  local quota_pin=""

  while IFS= read -r line; do sprite_lines+=("$line"); done < <(render_lcd_frame)

  if [ "$MD_alive" != "true" ]; then
    stat_lines+=("$(printf '\033[2m%s · 重新開始：mud.sh hatch <name>\033[0m' "$MD_player_name")")
  else
    # (Scene/Day/Turn header now lives in the LCD top border — keep right
    # side dedicated to bars / narrative / inventory / quota.)

    # Heroine bars (top 3 by affection desc)
    local rows_json
    rows_json=$(printf '%s' "$MD_affections_json" \
      | "$JQ" -c --argjson moods "$MD_moods_json" --arg focus "$MD_focus_char" '
          to_entries
          | map({name: .key, val: .value, mood: ($moods[.key] // "中立"), focus: (.key == $focus)})
          | sort_by(-.val)
          | .[0:3]')
    local n_chars
    n_chars=$(printf '%s' "$rows_json" | "$JQ" 'length')
    local i
    for ((i=0; i<n_chars; i++)); do
      local cname cval cmood cfocus
      cname=$(printf '%s' "$rows_json" | "$JQ" -r --argjson i "$i" '.[$i].name')
      cval=$(printf '%s' "$rows_json" | "$JQ" -r --argjson i "$i" '.[$i].val')
      cmood=$(printf '%s' "$rows_json" | "$JQ" -r --argjson i "$i" '.[$i].mood')
      cfocus=$(printf '%s' "$rows_json" | "$JQ" -r --argjson i "$i" '.[$i].focus')
      local marker="${GENRE_BAR_OTHER:-🤍}"; [ "$cfocus" = "true" ] && marker="${GENRE_BAR_FOCUS:-💕}"
      local cb
      cb=$(bar "$cval" "${GENRE_PRIMARY_MAX:-100}" 8 35)
      stat_lines+=("$(printf '%s \033[1m%s\033[0m %b \033[2m%d · %s\033[0m' "$marker" "$cname" "$cb" "$cval" "$cmood")")
    done

    # Player stats line — iterates genre.stat_names in order, looks up icons
    # in genre.stat_icons (default •), shows only stats with value > 0.
    local stats_total
    stats_total=$(printf '%s' "$MD_stats_json" | "$JQ" '[.[]] | add // 0' 2>/dev/null)
    if [ -n "$stats_total" ] && [ "$stats_total" -gt 0 ]; then
      local stats_str
      stats_str=$(printf '%s' "$MD_stats_json" \
        | "$JQ" -r --argjson names "$GENRE_STAT_NAMES_JSON" --argjson icons "$GENRE_STAT_ICONS_JSON" '
            . as $stats
            | $names
            | map(
                . as $n
                | ($stats[$n] // 0) as $v
                | if $v > 0 then "\($icons[$n] // "•") \($n) \($v)" else empty end)
            | join("  ")')
      [ -n "$stats_str" ] && stat_lines+=("$(printf '\033[2m%s\033[0m' "$stats_str")")
    fi

    # Narrative (wrapped to multiple lines, capped to fit available rows).
    # LCD content has 6 usable rows (1..6); row 7 is bottom border + quota.
    # Reserve rows already occupied by bars + stats line, give the rest to
    # narrative; if narrative would overflow, end the last visible line with "…".
    if [ -n "$MD_last_narrative" ]; then
      local nstyle="\033[36m"
      [ "$MD_narrative_source" != "haiku" ] && nstyle="\033[2;36m"
      local narr="$MD_last_narrative"
      local nlen=${#narr}
      local LW=22
      local used=${#stat_lines[@]}
      local n_max=$(( 6 - used ))
      [ "$n_max" -lt 1 ] && n_max=1
      local total_lines=$(( (nlen + LW - 1) / LW ))
      local visible=$total_lines
      [ "$visible" -gt "$n_max" ] && visible=$n_max
      local li ni=0
      for ((li=0; li<visible; li++)); do
        local chunk="${narr:ni:LW}"
        if [ "$li" -eq $((visible - 1)) ] && [ "$visible" -lt "$total_lines" ]; then
          # truncated last line: trim 1 codepoint and append "…"
          chunk="${chunk:0:$((${#chunk} - 1))}…"
        fi
        stat_lines+=("$(printf '%b%s\033[0m' "$nstyle" "$chunk")")
        ni=$((ni + LW))
      done
    fi

    # Inventory (1 line, max 4 items)
    local inv_count
    inv_count=$(printf '%s' "$MD_inventory_json" | "$JQ" 'length')
    if [ "$inv_count" -gt 0 ]; then
      local inv_str
      inv_str=$(printf '%s' "$MD_inventory_json" | "$JQ" -r '.[0:4] | map("🎁 " + .) | join("  ")')
      stat_lines+=("$(printf '\033[2m%s\033[0m' "$inv_str")")
    fi

    # Quota pin (last LCD row)
    if [ -n "$ctx_pct" ] || [ -n "$q5p" ] || [ -n "$q7p" ]; then
      local qsep=$'\033[2m  │  \033[0m' qseg=""
      if [ -n "$ctx_pct" ]; then
        local ctx_int=${ctx_pct%.*}; [ -z "$ctx_int" ] && ctx_int=0
        printf -v qseg '🧠 \033[36m%d%%\033[0m \033[2mctx\033[0m' "$ctx_int"
        quota_pin="$qseg"
      fi
      if [ -n "$q5p" ]; then
        local q5p_int=${q5p%.*}; [ -z "$q5p_int" ] && q5p_int=0
        local q5_when=""
        [ -n "$q5r" ] && q5_when=" \033[2m$(human_countdown "$q5r")\033[0m"
        printf -v qseg '⏱ \033[2m5h\033[0m \033[36m%d%%\033[0m%b' "$q5p_int" "$q5_when"
        [ -n "$quota_pin" ] && quota_pin="${quota_pin}${qsep}${qseg}" || quota_pin="$qseg"
      fi
      if [ -n "$q7p" ]; then
        local q7p_int=${q7p%.*}; [ -z "$q7p_int" ] && q7p_int=0
        local q7_when=""
        [ -n "$q7r" ] && q7_when=" \033[2m$(human_countdown "$q7r")\033[0m"
        printf -v qseg '📅 \033[2m7d\033[0m \033[33m%d%%\033[0m%b' "$q7p_int" "$q7_when"
        [ -n "$quota_pin" ] && quota_pin="${quota_pin}${qsep}${qseg}" || quota_pin="$qseg"
      fi
    fi
  fi

  # Pad sprite lines to max width
  local trimmed_lines=() trimmed_widths=() max_w=0
  local sline
  for sline in "${sprite_lines[@]}"; do
    local trimmed="${sline#"${sline%%[![:space:]]*}"}"
    local w=$(vis_width "$trimmed")
    trimmed_lines+=("$trimmed")
    trimmed_widths+=("$w")
    [ "$w" -gt "$max_w" ] && max_w=$w
  done
  local padded_lines=() idx=0
  for sline in "${trimmed_lines[@]}"; do
    local vw=${trimmed_widths[idx]}
    local pad=$(( max_w - vw )); [ "$pad" -lt 0 ] && pad=0
    local padded
    printf -v padded '%s%*s' "$sline" "$pad" ""
    padded_lines+=("$padded")
    idx=$((idx + 1))
  done
  sprite_lines=("${padded_lines[@]}")

  # Pair box rows with stat rows. Stats start at LCD row 1 (right next to
  # header) so there's no gap between top border and the first bar.
  # Quota stays pinned to the last LCD row regardless.
  local n_sprite=${#sprite_lines[@]}
  local n_stats=${#stat_lines[@]}
  local v_offset=1
  local rows=$(( n_sprite > n_stats + v_offset ? n_sprite : n_stats + v_offset ))
  local last_row=$(( n_sprite - 1 ))
  local i
  for ((i=0; i<rows; i++)); do
    local s="${sprite_lines[i]:-}"
    local t=""
    local stat_idx=$(( i - v_offset ))
    if [ "$stat_idx" -ge 0 ] && [ "$stat_idx" -lt "$n_stats" ]; then
      t="${stat_lines[stat_idx]}"
    fi
    if [ -n "$quota_pin" ] && [ "$i" -eq "$last_row" ]; then
      t="$quota_pin"
    fi
    if [ -n "$t" ]; then
      printf '%b  %b\n' "$s" "$t"
    else
      printf '%b\n' "$s"
    fi
  done

  local cols=${MUD_RULE_WIDTH:-80}
  if [ "$cols" -gt 0 ]; then
    local rule="" i
    for ((i=0; i<cols; i++)); do rule="${rule}─"; done
    printf '\033[2m%s\033[0m\n' "$rule"
  fi
  emit_tail "$stdin_json"
}

# --- hooks ---------------------------------------------------------------
cmd_feed_prompt() {
  # Re-entrancy guard: when fork_haiku_generation runs `claude -p`, that
  # sub-session's UserPromptSubmit hook would re-trigger this — so we'd
  # double-count turns and write garbage prompts. Bail early when called
  # from within our own haiku invocation.
  [ -n "${CCMUD_INTERNAL:-}" ] && return 0
  ensure_state
  # Capture the prompt body for the haiku context — written to a per-session
  # file that feed-stop's background fork reads. Optional; haiku runs without
  # it, just with less relevance.
  local payload=""
  [ ! -t 0 ] && payload=$(cat)
  acquire_lock
  sload
  apply_decay
  if [ "$MD_alive" = "true" ]; then
    MD_turn=$(( ${MD_turn:-0} + 1 ))
    MD_last_interaction=$(now)
    DIRTY=1
  fi
  if [ -n "$payload" ]; then
    local sid prompt
    sid=$(printf '%s' "$payload" | "$JQ" -r '.session_id // ""' 2>/dev/null)
    prompt=$(printf '%s' "$payload" | "$JQ" -r '.prompt // ""' 2>/dev/null)
    if [ -n "$sid" ]; then
      MD_session_id="$sid"
      DIRTY=1
      mkdir -p "$TMPDIR_MUD"
      printf '%s' "$prompt" > "$TMPDIR_MUD/$sid.last_prompt" 2>/dev/null || true
    fi
  fi
  persist_state
  release_lock
}

# Synchronous part of feed-stop: drain previous-turn cache + log usage.
# Async part forks claude -p in background and disowns.
cmd_feed_stop() {
  # Re-entrancy guard: see cmd_feed_prompt. Without this, every haiku call
  # would recursively spawn another haiku call → runaway fork loop.
  [ -n "${CCMUD_INTERNAL:-}" ] && return 0
  ensure_state
  local payload=""
  [ ! -t 0 ] && payload=$(cat)

  # Parse stdin: session_id, transcript_path, rate_limits.
  local sid="" transcript=""
  if [ -n "$payload" ]; then
    sid=$(printf '%s' "$payload" | "$JQ" -r '.session_id // ""' 2>/dev/null)
    transcript=$(printf '%s' "$payload" | "$JQ" -r '.transcript_path // ""' 2>/dev/null)
  fi

  # Tail transcript for last assistant message's token usage.
  local tin=0 tout=0 tcc=0 tcr=0
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    local raw
    raw=$(tail -50 "$transcript" 2>/dev/null | "$JQ" -rs '
      [.[] | select(.type=="assistant") | .message.usage // {}] | last // {} |
      [(.input_tokens // 0),
       (.output_tokens // 0),
       (.cache_creation_input_tokens // 0),
       (.cache_read_input_tokens // 0)] | @tsv' 2>/dev/null)
    if [ -n "$raw" ]; then
      IFS=$'\t' read -r tin tout tcc tcr <<<"$raw"
      : "${tin:=0}" "${tout:=0}" "${tcc:=0}" "${tcr:=0}"
    fi
  fi

  acquire_lock
  sload
  apply_decay
  load_genre

  if [ -n "$sid" ] && [ "$sid" != "$MD_session_id" ]; then
    MD_session_id="$sid"
    DIRTY=1
  fi
  [ -z "$sid" ] && sid="$MD_session_id"

  # Drain previous turn's haiku output if ready.
  # Cache file is genre-tagged so that an in-flight Haiku started under one
  # genre cannot leak its narrative into a different genre's save after the
  # user runs `set-genre`. Drain only matches the currently-active genre.
  local cache_file="$TMPDIR_MUD/${sid:-default}.${MD_genre:-_}.next.txt"
  if [ -f "$cache_file" ]; then
    local cache_mtime
    cache_mtime=$(file_mtime "$cache_file")
    if [ "$cache_mtime" -gt "${MD_last_haiku_at:-0}" ]; then
      drain_narrative_file "$cache_file"
      MD_last_haiku_at="$cache_mtime"
      MD_last_haiku_status="ok"
      DIRTY=1
    fi
  fi

  if [ "$MD_alive" = "true" ]; then
    MD_last_interaction=$(now)
    DIRTY=1
  fi

  persist_state
  release_lock

  # Append daily usage row.
  log_usage "$tin" "$tout" "$tcc" "$tcr"

  # Fire background haiku for the next turn (no-op if dead or no-genre).
  if [ "$MD_alive" = "true" ] && [ -n "$GENRE_FILE" ] && [ -n "$sid" ]; then
    fork_haiku_generation "$sid" "$tin" "$tout" "$tcc" "$tcr" &
    disown 2>/dev/null || true
  fi
}

# --- usage log -----------------------------------------------------------
log_usage() {
  local tin=$1 tout=$2 tcc=$3 tcr=$4
  mkdir -p "$MUD_DIR"
  local today
  today=$(date +%Y-%m-%d)
  if [ ! -f "$USAGE_LOG" ]; then
    printf 'date,turns,prompts,haiku_calls,input_tokens,output_tokens,cc_tokens,cr_tokens\n' > "$USAGE_LOG"
  fi
  # Read or initialize today's row, then update.
  local existing
  existing=$(grep -E "^${today}," "$USAGE_LOG" 2>/dev/null | tail -1 || true)
  local turns=0 prompts=0 haiku=0 in=0 out=0 cc=0 cr=0
  if [ -n "$existing" ]; then
    IFS=',' read -r _ turns prompts haiku in out cc cr <<<"$existing"
  fi
  prompts=$(( prompts + 1 ))
  haiku=$(( haiku + 1 ))
  in=$(( in + tin ))
  out=$(( out + tout ))
  cc=$(( cc + tcc ))
  cr=$(( cr + tcr ))
  # Atomic rewrite: drop today's row, append new one.
  local tmp="${USAGE_LOG}.tmp.$$"
  grep -vE "^${today}," "$USAGE_LOG" > "$tmp" 2>/dev/null || true
  printf '%s,%d,%d,%d,%d,%d,%d,%d\n' "$today" "$turns" "$prompts" "$haiku" "$in" "$out" "$cc" "$cr" >> "$tmp"
  mv "$tmp" "$USAGE_LOG"
}

# --- background haiku fork ----------------------------------------------
# Builds context, calls `claude -p --model haiku`, writes atomically.
fork_haiku_generation() {
  local sid="$1" tin="$2" tout="$3" tcc="$4" tcr="$5"
  # Genre-tagged so this output only drains under the genre that forked it.
  local out_path="$TMPDIR_MUD/${sid}.${MD_genre:-_}.next.txt"
  local tmp_path="${out_path}.tmp.$$"
  local prompt_file="$TMPDIR_MUD/${sid}.last_prompt"

  local user_prompt=""
  [ -f "$prompt_file" ] && user_prompt=$(head -c 800 "$prompt_file" 2>/dev/null || echo "")

  # Activity intensity bucket from token usage.
  local total=$(( tin + tout + tcc + tcr ))
  local intensity="輕度"
  [ "$total" -ge 1000 ]  && intensity="中度"
  [ "$total" -ge 10000 ] && intensity="重度"

  # State summary as compact JSON.
  local state_summary
  state_summary=$("$JQ" -nc \
    --arg scene "$MD_scene" \
    --argjson day "${MD_day:-1}" \
    --argjson turn "${MD_turn:-0}" \
    --arg focus "$MD_focus_char" \
    --argjson active "$MD_active_chars_json" \
    --argjson aff "$MD_affections_json" \
    --argjson moods "$MD_moods_json" \
    --argjson flags "$MD_flags_json" \
    --arg prev "$MD_last_narrative" \
    '{scene: $scene, day: $day, turn: $turn, focus: $focus,
      active: $active, affections: $aff, moods: $moods, flags: $flags,
      previous_narrative: $prev}')

  local base_prompt=""
  [ -f "$PROMPTS_DIR/haiku-base.txt" ] && base_prompt=$(cat "$PROMPTS_DIR/haiku-base.txt")

  # Compose the user-message payload for haiku. Genre's system_prompt sets
  # the rules; this message gives turn-specific context.
  local user_msg
  user_msg=$(cat <<EOF
[ccmud turn 上下文]
當前狀態：$state_summary
玩家剛輸入給 Claude Code 的工作 prompt（截斷至 800 字）：
"""$user_prompt"""
玩家活動強度：$intensity（依 token 用量推斷）

請依照 system 規則，輸出下一段 2–4 句中文敘述 + 0–3 個行內 tag。只輸出純文字，不要 markdown。
EOF
)

  # Compose system prompt.
  local sys_prompt
  if [ -n "$base_prompt" ]; then
    sys_prompt="${base_prompt}

${GENRE_SYSTEM_PROMPT}"
  else
    sys_prompt="$GENRE_SYSTEM_PROMPT"
  fi

  # Run claude -p with hard timeout. Append-system-prompt instead of system
  # is more compatible across versions; pass --print + --model.
  # IMPORTANT: cd to a CLAUDE.md-free dir before invoking claude — otherwise
  # the CLI loads the parent project's CLAUDE.md as context, ballooning the
  # request and easily blowing past the timeout.
  local cli
  cli=$(command -v claude 2>/dev/null || echo "")
  if [ -z "$cli" ]; then
    return 0
  fi

  local safe_cwd="$TMPDIR_MUD"
  [ -d "$safe_cwd" ] || safe_cwd="${TMPDIR:-/tmp}"

  local timeout_bin
  timeout_bin=$(command -v timeout 2>/dev/null || echo "")
  # CCMUD_INTERNAL=1 propagates to the sub-claude so its hooks bail out of
  # ccmud (and the user can guard their own hooks too). This breaks the
  # recursive Stop-hook → fork → Stop-hook loop.
  if [ -n "$timeout_bin" ]; then
    ( cd "$safe_cwd" && CCMUD_INTERNAL=1 "$timeout_bin" 180 "$cli" -p \
      --model claude-haiku-4-5-20251001 \
      --append-system-prompt "$sys_prompt" \
      "$user_msg" \
      > "$tmp_path" )
    rc=$?
  else
    ( cd "$safe_cwd" && CCMUD_INTERNAL=1 "$cli" -p \
      --model claude-haiku-4-5-20251001 \
      --append-system-prompt "$sys_prompt" \
      "$user_msg" \
      > "$tmp_path" )
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp_path"
    return 0
  fi
  if [ -s "$tmp_path" ]; then
    mv "$tmp_path" "$out_path"
  else
    rm -f "$tmp_path"
  fi
}

# --- utilities -----------------------------------------------------------
cmd_stats() {
  ensure_state
  acquire_lock
  sload
  apply_decay
  persist_state
  release_lock
  cat "$STATE_FILE"
}

cmd_hatch() {
  local name="${1:-玩家}"
  local genre="${2:-dating-sim}"
  if [ ! -f "$GENRES_DIR/$genre.json" ]; then
    printf '✗ genre not found: %s\n' "$GENRES_DIR/$genre.json" >&2
    printf '  available genres:\n' >&2
    local f
    for f in "$GENRES_DIR"/*.json; do
      [ -f "$f" ] || continue
      printf '    %s\n' "$(basename "$f" .json)" >&2
    done
    exit 1
  fi
  acquire_lock
  default_state "$name" "$genre" > "$STATE_FILE"
  release_lock
  printf '🌸 %s 開始了 %s 的故事\n' "$name" "$genre"
}

cmd_set_genre() {
  local genre="${1:?usage: mud.sh set-genre <genre_id>}"
  if [ ! -f "$GENRES_DIR/$genre.json" ]; then
    printf '✗ genre not found: %s\n' "$GENRES_DIR/$genre.json" >&2
    exit 1
  fi
  ensure_state
  acquire_lock
  sload
  local old=$MD_genre

  if [ "$old" = "$genre" ]; then
    release_lock
    printf '(already %s)\n' "$genre"
    return
  fi

  # Snapshot the current state to saves/<old>.json before swapping. Future
  # `set-genre <old>` will restore exactly this snapshot.
  mkdir -p "$SAVES_DIR"
  if [ -n "$old" ]; then
    cp "$STATE_FILE" "$SAVES_DIR/$old.json"
  fi

  if [ -f "$SAVES_DIR/$genre.json" ]; then
    # Restore the saved slot for the target genre. Force `.genre` field in
    # case the save was written by an older version with a different id.
    "$JQ" --arg g "$genre" '.genre = $g' "$SAVES_DIR/$genre.json" | swrite
    release_lock
    printf '🎭 genre %s → %s (restored from saves/%s.json)\n' "$old" "$genre" "$genre"
  else
    # No save for the new genre yet — carry over current state, rebrand.
    MD_genre="$genre"
    DIRTY=1
    persist_state
    release_lock
    printf '🎭 genre %s → %s (state carried over; %s snapshot saved to saves/%s.json)\n' \
      "$old" "$genre" "$old" "$old"
  fi
}

cmd_list_genres() {
  if [ ! -d "$GENRES_DIR" ]; then
    printf '(no genres dir at %s)\n' "$GENRES_DIR" >&2
    return 1
  fi
  local f
  for f in "$GENRES_DIR"/*.json; do
    [ -f "$f" ] || continue
    local id name
    id=$("$JQ" -r '.id // ""' "$f")
    name=$("$JQ" -r '.display_name // ""' "$f")
    printf '%-20s  %s\n' "$id" "$name"
  done
}

cmd_preview() {
  ensure_state
  acquire_lock
  sload
  load_genre
  release_lock

  local extra_wide
  extra_wide=$(printf '%s' "$GENRE_CHAR_EMOJIS_JSON" | "$JQ" -r '[.[]] | join("")' 2>/dev/null || echo "")
  WIDE_RUNTIME="${WIDE_EMOJIS_BASE}${extra_wide}"

  render_lcd_frame
}

cmd_debug_set() {
  local field="$1" value="$2"
  ensure_state
  acquire_lock
  if [[ "$value" =~ ^-?[0-9]+$ ]]; then
    "$JQ" --arg f "$field" --argjson v "$value" '.[$f] = $v' "$STATE_FILE" | swrite
  elif [ "$value" = "true" ] || [ "$value" = "false" ] || [ "$value" = "null" ]; then
    "$JQ" --arg f "$field" --argjson v "$value" '.[$f] = $v' "$STATE_FILE" | swrite
  else
    "$JQ" --arg f "$field" --arg v "$value" '.[$f] = $v' "$STATE_FILE" | swrite
  fi
  release_lock
  printf 'set .%s = %s\n' "$field" "$value"
}

cmd_usage() {
  if [ ! -f "$USAGE_LOG" ]; then
    printf '(no usage log yet at %s)\n' "$USAGE_LOG" >&2
    return 0
  fi
  printf '%s\n' "──────────  ccmud usage log  ──────────"
  column -s, -t < "$USAGE_LOG" 2>/dev/null || cat "$USAGE_LOG"
  printf '\n'
  awk -F, 'NR>1 { in_+=$5; out_+=$6; cc_+=$7; cr_+=$8; haiku_+=$4; days+=1 }
       END { if (days==0) exit
             printf "totals: %d days · %d haiku calls · in %d · out %d · cc %d · cr %d\n",
                    days, haiku_, in_, out_, cc_, cr_ }' "$USAGE_LOG"
}

cmd_story() {
  if [ ! -f "$STORY_LOG" ]; then
    printf '(no story log yet at %s — write your first turn first)\n' "$STORY_LOG" >&2
    return 0
  fi
  local mode="${1:-tail}"
  case "$mode" in
    tail)   tail -n 60 "$STORY_LOG" ;;
    head)   head -n 60 "$STORY_LOG" ;;
    full|all|cat) cat "$STORY_LOG" ;;
    path)   printf '%s\n' "$STORY_LOG" ;;
    count)  grep -cE '^─── Turn [0-9]+' "$STORY_LOG" ;;
    *)      tail -n "${mode:-60}" "$STORY_LOG" 2>/dev/null \
            || tail -n 60 "$STORY_LOG" ;;
  esac
}

cmd_uninstall() {
  local settings="$HOME/.claude/settings.json"
  printf 'This will:\n'
  printf '  • Remove ccmud hooks from %s\n' "$settings"
  printf '  • Remove statusLine if it is ccmud (otherwise leave it alone)\n'
  printf '  • Delete %s/mud.sh and %s/genres/* and %s/prompts/*\n' "$MUD_DIR" "$MUD_DIR" "$MUD_DIR"
  printf '  • Delete %s/saves/ (all per-genre snapshots)\n' "$MUD_DIR"
  printf 'Will KEEP (in case you reinstall):\n'
  printf '  • %s (current save)\n' "$STATE_FILE"
  printf '  • %s (story log)\n' "$STORY_LOG"
  printf '  • %s (token usage)\n' "$USAGE_LOG"
  printf '\nProceed? [y/N] '
  local reply=""
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "(aborted)"; return 0 ;;
  esac

  if [ -f "$settings" ] && command -v "$JQ" >/dev/null 2>&1; then
    local tmp="${settings}.tmp.$$"
    "$JQ" --arg mud "$MUD_DIR/mud.sh" '
      (if (.statusLine.command // "") | startswith($mud) then del(.statusLine) else . end)
      | (.hooks.UserPromptSubmit //= [])
      | .hooks.UserPromptSubmit |= map(
          select(((.hooks // []) | map(.command) | any(startswith($mud))) | not))
      | (.hooks.Stop //= [])
      | .hooks.Stop |= map(
          select(((.hooks // []) | map(.command) | any(startswith($mud))) | not))
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"
    printf '✓ ccmud entries removed from %s\n' "$settings"
  fi

  rm -f "$MUD_DIR/mud.sh"
  rm -rf "$MUD_DIR/genres" "$MUD_DIR/prompts" "$MUD_DIR/saves"
  rm -f "$HOME/.claude/commands/mud.md"
  printf '✓ binaries + genres + prompts + saves + /mud command deleted\n'
  printf '\nRetained (for next install): %s, %s, %s\n' "$STATE_FILE" "$STORY_LOG" "$USAGE_LOG"
  printf '↻ Restart Claude Code so it stops calling the removed hooks.\n'
}

cmd_update() {
  local url="${CCMUD_UPDATE_URL:-https://raw.githubusercontent.com/richardvt/ccmud/main/mud.sh}"
  local target="$HOME/.claude/mud/mud.sh"
  local tmp="${target}.new.$$"
  printf '→ fetching %s\n' "$url"
  if ! command -v curl >/dev/null 2>&1; then
    echo "✗ curl not found" >&2; exit 1
  fi
  if ! curl -fsSL "$url" -o "$tmp"; then
    echo "✗ download failed" >&2; rm -f "$tmp"; exit 1
  fi
  if [ ! -s "$tmp" ] || ! head -1 "$tmp" | grep -q '^#!'; then
    echo "✗ downloaded file does not look like a script" >&2; rm -f "$tmp"; exit 1
  fi
  chmod +x "$tmp"
  mv "$tmp" "$target"
  printf '✓ %s updated (state.json + settings.json untouched)\n' "$target"
}

# --- dispatch ------------------------------------------------------------
case "${1:-render}" in
  render)        cmd_render ;;
  feed-prompt)   cmd_feed_prompt ;;
  feed-stop)     cmd_feed_stop ;;
  stats)         cmd_stats ;;
  hatch)         shift; cmd_hatch "$@" ;;
  set-genre)     shift; cmd_set_genre "$@" ;;
  list-genres)   cmd_list_genres ;;
  preview)       cmd_preview ;;
  debug-set)     shift; cmd_debug_set "$@" ;;
  usage)         cmd_usage ;;
  story)         shift; cmd_story "$@" ;;
  update)        cmd_update ;;
  uninstall)     cmd_uninstall ;;
  *) echo "usage: mud.sh {render|feed-prompt|feed-stop|stats|preview|hatch <name> [genre]|set-genre <id>|list-genres|debug-set <field> <value>|usage|story [tail|full|count|<N>]|update|uninstall}" >&2; exit 1 ;;
esac
