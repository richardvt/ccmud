# ccmud genre lib: pokemon
#
# Sourced by load_genre when MD_genre = "pokemon". Defines genre-specific
# tag handlers + event styling. Returns 0 from genre_apply_tag iff the tag
# was handled (default apply_tag is then skipped).

genre_apply_tag() {
  local tag="$1"
  local body val
  case "$tag" in
    # <<CATCH:皮卡丘>>  Capture a wild Pokémon: add to active_chars,
    # init level (affection) to 5, mood to "健康".
    CATCH:*)
      body="${tag#CATCH:}"
      MD_active_chars_json=$(printf '%s' "$MD_active_chars_json" \
        | "$JQ" -c --arg v "$body" 'if any(. == $v) then . else . + [$v] end')
      MD_affections_json=$(printf '%s' "$MD_affections_json" \
        | "$JQ" -c --arg k "$body" '.[$k] = (.[$k] // 5)')
      MD_moods_json=$(printf '%s' "$MD_moods_json" \
        | "$JQ" -c --arg k "$body" '.[$k] = (.[$k] // "健康")')
      DIRTY=1
      push_event "🎯 捕獲：${body}"
      return 0
      ;;
    # <<BADGE:岩石徽章>>  Win a gym: add to flags + bump stats.徽章 by 1.
    BADGE:*)
      val="${tag#BADGE:}"
      MD_flags_json=$(printf '%s' "$MD_flags_json" \
        | "$JQ" -c --arg v "$val" 'if any(. == $v) then . else . + [$v] end')
      MD_stats_json=$(printf '%s' "$MD_stats_json" \
        | "$JQ" -c '.["徽章"] = ((.["徽章"] // 0) + 1)')
      DIRTY=1
      push_event "🏅 獲得：${val}"
      return 0
      ;;
    # <<HEAL:皮卡丘>>  Pokémon Center: HP back to max, mood "健康".
    HEAL:*)
      body="${tag#HEAL:}"
      MD_affections_json=$(printf '%s' "$MD_affections_json" \
        | "$JQ" -c --arg k "$body" --argjson max "${GENRE_PRIMARY_MAX:-100}" \
            '.[$k] = $max')
      MD_moods_json=$(printf '%s' "$MD_moods_json" \
        | "$JQ" -c --arg k "$body" '.[$k] = "健康"')
      DIRTY=1
      push_event "✚ 治癒：${body}"
      return 0
      ;;
    # <<FAINT:皮卡丘>>  HP → 0, mood "瀕死".
    FAINT:*)
      body="${tag#FAINT:}"
      MD_affections_json=$(printf '%s' "$MD_affections_json" \
        | "$JQ" -c --arg k "$body" '.[$k] = 0')
      MD_moods_json=$(printf '%s' "$MD_moods_json" \
        | "$JQ" -c --arg k "$body" '.[$k] = "瀕死"')
      DIRTY=1
      push_event "💀 瀕死：${body}"
      return 0
      ;;
    # <<EVOLVE:皮卡丘:雷丘>>  Replace name in active_chars; carry over
    # level (affection) to the new form, drop the old key.
    EVOLVE:*)
      body="${tag#EVOLVE:}"
      local from="${body%%:*}" to="${body#*:}"
      [ "$from" = "$body" ] && return 0   # malformed
      MD_active_chars_json=$(printf '%s' "$MD_active_chars_json" \
        | "$JQ" -c --arg from "$from" --arg to "$to" \
            'map(if . == $from then $to else . end) | unique')
      MD_affections_json=$(printf '%s' "$MD_affections_json" \
        | "$JQ" -c --arg from "$from" --arg to "$to" \
            '.[$to] = (.[$from] // 5) | del(.[$from])')
      MD_moods_json=$(printf '%s' "$MD_moods_json" \
        | "$JQ" -c --arg from "$from" --arg to "$to" \
            '.[$to] = "興奮" | del(.[$from])')
      [ "$MD_focus_char" = "$from" ] && MD_focus_char="$to"
      DIRTY=1
      push_event "🌟 進化：${from} → ${to}"
      return 0
      ;;
    *) return 1 ;;
  esac
}

genre_event_style() {
  case "$1" in
    "🎯 "*) printf '\033[1;32m' ;;   # bright green: catch
    "🏅 "*) printf '\033[1;33m' ;;   # bright yellow: badge
    "✚ "*)  printf '\033[1;36m' ;;   # bright cyan: heal
    "💀 "*) printf '\033[1;31m' ;;   # bright red: faint
    "🌟 "*) printf '\033[1;35m' ;;   # bright magenta: evolve
    *) return 1 ;;
  esac
}
