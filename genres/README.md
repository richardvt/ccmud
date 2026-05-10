# Genres

Each `<id>.json` in this directory defines a pluggable genre. Drop one in, run `mud.sh set-genre <id>`, and the game switches over without losing player progress (turn / day / interaction history are kept; characters / scene / narrative reset to genre defaults).

## Schema

```jsonc
{
  "id":           "dating-sim",       // must match filename
  "display_name": "戀愛養成",          // shown in `mud.sh list-genres`
  "version":      1,

  // Player-side stats. Keys appear in state.stats once a STAT tag fires.
  "stat_names":   ["魅力", "智慧", "體力"],

  // The "main resource" — what the win condition tracks. For dating-sim
  // this is per-character affection.
  "primary_resource": {
    "key":   "affections",            // matches state field name
    "label": "好感",
    "max":   100
  },

  // Characters (NPCs). starting_chars are alive at hatch; char_pool is the
  // set Haiku may introduce later via <<NEW_CHAR:…>>.
  "starting_chars": ["雪奈"],
  "char_pool":      ["雪奈", "小薇", "凜"],
  "char_emojis":    { "雪奈": "👧", "小薇": "👩", "凜": "🧑" },

  // Scenes Haiku can pick from via <<SCENE:…>>.
  "scenes": ["教室", "圖書館", "咖啡廳"],
  "scene_decos": {                    // 1–2 emojis pinned in LCD corners
    "教室":   ["📝", "🪑"],
    "圖書館": ["📚", "📖"]
  },

  // Documentation only — actual parsing is hardcoded in mud.sh apply_tag.
  // Use this section to tell Haiku (via system_prompt) what tags to emit.
  "tag_schema": {
    "AFFECTION": "<<AFFECTION+N:角色>>",
    "MOOD":      "<<MOOD:心情:角色>>",
    "SCENE":     "<<SCENE:場景>>"
    // ... see dating-sim.json for the full list
  },

  // The system prompt sent to Haiku each turn. Should explain:
  //   - Tone / style / length constraints
  //   - When to fire tags (especially ENDING — be conservative)
  //   - Output format (plain text + inline tags only, no markdown)
  "system_prompt": "你是 ... 劇情敘述生成器 ...",

  // Hand-written generic narrative pool used as visual padding when
  // Haiku hasn't generated yet (first install, mid-flight, failure).
  // 50–100 entries recommended. These do NOT advance state.
  "fallback_snippets": [
    "雪奈在窗邊翻書，陽光灑在她髮梢。",
    "走廊外有人經過，腳步聲漸遠。"
  ],

  // Optional. mud.sh doesn't enforce these in v1 — Haiku is expected to
  // detect them and fire <<ENDING:…>>. Documented for future use.
  "win_condition":  { "type": "affection", "char_any": true, "threshold": 100 },
  "lose_condition": { "type": "neglect_days", "threshold": 30 }
}
```

## Adding a new genre

1. Copy `dating-sim.json` to `your-genre.json`.
2. Edit fields. The `system_prompt` is the most important — it's what Haiku sees every turn.
3. Drop the file in `~/.claude/mud/genres/` (or run `bash install.sh` if your genre lives in the repo).
4. `mud.sh set-genre your-genre`.
5. Test with `mud.sh preview` (renders LCD with current state) and a manual Stop simulation:
   ```bash
   echo '{"session_id":"test"}' | mud.sh feed-stop
   sleep 10                                 # let Haiku finish
   ls -la "$TMPDIR/ccmud/test.<id>.next.txt"  # macOS uses $TMPDIR, not /tmp
   echo '{"session_id":"test"}' | mud.sh feed-stop   # drains it
   mud.sh stats | jq '.last_narrative, .narrative_source'
   ```

## Tag types (hardcoded in mud.sh `apply_tag`)

| Tag | Format | Effect |
|-----|--------|--------|
| `AFFECTION` | `<<AFFECTION±N:char>>` | Delta to that char's affection (clamped 0..max) |
| `MOOD` | `<<MOOD:mood:char>>` | Set char's mood string (char optional → focus_char) |
| `SCENE` | `<<SCENE:name>>` | Change scene |
| `FOCUS` | `<<FOCUS:char>>` | Change narrative focus |
| `FLAG` | `<<FLAG±:name>>` | Add or remove a flag |
| `ITEM` | `<<ITEM±:name>>` | Add to or remove from inventory |
| `STAT` | `<<STAT±N:key>>` | Delta to a player stat (key from `stat_names`) |
| `NEW_CHAR` | `<<NEW_CHAR:char>>` | Add to active_chars (affection=0, mood=中立) |
| `ENDING` | `<<ENDING:name>>` | Set ending; alive=false; render switches to "END" |

To add a new tag type: edit `apply_tag` in `mud.sh`, document it in `genre.tag_schema`, and explain it in `genre.system_prompt`.
