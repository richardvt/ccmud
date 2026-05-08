# ccmud genre lib: english-learn
#
# Sourced by load_genre when MD_genre = "english-learn". Adds two new tags
# for collecting English vocabulary and phrases:
#
#   <<WORD+:serendipity:意外發現的喜悅>>
#       Append "serendipity:意外發現的喜悅" to inventory (no dup),
#       bump stats.詞彙 +1, push event "📖 serendipity — 意外發現的喜悅".
#
#   <<PHRASE+:break the ice:破冰>>
#       Same shape, but with ✿ marker so events render distinctly from
#       single-word entries.
#
# Default tags (AFFECTION/MOOD/SCENE/FOCUS/FLAG/ITEM/STAT/NEW_CHAR/ENDING)
# fall through to mud.sh's apply_tag.

genre_apply_tag() {
  local tag="$1"
  local body word meaning
  case "$tag" in
    WORD+:*)
      body="${tag#WORD+:}"
      word="${body%%:*}"
      meaning="${body#*:}"
      [ -z "$word" ] && return 0
      [ "$meaning" = "$body" ] && meaning=""   # malformed — no meaning given
      local entry="$word"
      [ -n "$meaning" ] && entry="$word:$meaning"
      MD_inventory_json=$(printf '%s' "$MD_inventory_json" \
        | "$JQ" -c --arg v "$entry" 'if any(. == $v) then . else . + [$v] end')
      MD_stats_json=$(printf '%s' "$MD_stats_json" \
        | "$JQ" -c '.["詞彙"] = ((.["詞彙"] // 0) + 1)')
      DIRTY=1
      if [ -n "$meaning" ]; then
        push_event "📖 ${word} — ${meaning}"
      else
        push_event "📖 ${word}"
      fi
      return 0
      ;;
    PHRASE+:*)
      body="${tag#PHRASE+:}"
      word="${body%%:*}"
      meaning="${body#*:}"
      [ -z "$word" ] && return 0
      [ "$meaning" = "$body" ] && meaning=""
      local entry="$word"
      [ -n "$meaning" ] && entry="$word:$meaning"
      MD_inventory_json=$(printf '%s' "$MD_inventory_json" \
        | "$JQ" -c --arg v "$entry" 'if any(. == $v) then . else . + [$v] end')
      MD_stats_json=$(printf '%s' "$MD_stats_json" \
        | "$JQ" -c '.["詞彙"] = ((.["詞彙"] // 0) + 1)')
      DIRTY=1
      if [ -n "$meaning" ]; then
        push_event "✿ ${word} — ${meaning}"
      else
        push_event "✿ ${word}"
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

genre_event_style() {
  case "$1" in
    "📖 "*) printf '\033[1;32m' ;;   # bright green: new word
    "✿ "*)  printf '\033[1;36m' ;;   # bright cyan: new phrase
    *) return 1 ;;
  esac
}
