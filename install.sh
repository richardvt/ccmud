#!/usr/bin/env bash
# Interactive installer for ccmud. Idempotent — re-running keeps your
# existing save by default. Pipe-safe: if stdin isn't a TTY, falls back
# to defaults so `curl … | bash` works.

set -euo pipefail

MUD_DIR="$HOME/.claude/mud"
SETTINGS="$HOME/.claude/settings.json"
COMMANDS_DIR="$HOME/.claude/commands"
SOURCE="$(cd "$(dirname "$0")" && pwd)"

# --- pretty output --------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); CYAN=$(tput setaf 6); RED=$(tput setaf 1); MAGENTA=$(tput setaf 5)
else
  BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; CYAN=""; RED=""; MAGENTA=""
fi

step() { printf '\n%s→%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$1" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
err()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }

INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

ask() {
  local prompt="$1" default="${2:-}" reply=""
  if [ "$INTERACTIVE" -eq 1 ]; then
    if [ -n "$default" ]; then
      printf '  %s?%s %s %s[%s]%s ' "$MAGENTA" "$RESET" "$prompt" "$DIM" "$default" "$RESET" >&2
    else
      printf '  %s?%s %s ' "$MAGENTA" "$RESET" "$prompt" >&2
    fi
    read -r reply
  fi
  printf '%s' "${reply:-$default}"
}

ask_yn() {
  local prompt="$1" default="${2:-n}" reply=""
  local hint="[y/N]"
  [ "$default" = "y" ] && hint="[Y/n]"
  if [ "$INTERACTIVE" -eq 1 ]; then
    printf '  %s?%s %s %s%s%s ' "$MAGENTA" "$RESET" "$prompt" "$DIM" "$hint" "$RESET" >&2
    read -r reply
  fi
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# Arrow-key single-select picker. Args: <prompt> <option-1> [option-2] ...
# Stdout: the chosen option (one of args). Stderr: the menu UI.
# - Up/Down arrows or k/j move cursor; Enter selects; q or Ctrl-C cancels.
# - On non-TTY (curl | bash) or when only one option, prints the first option.
# - Reads from /dev/tty so it works even when the script's stdin is a pipe.
pick_one() {
  local prompt="$1"; shift
  local opts=("$@")
  local n=${#opts[@]}
  if [ "$n" -eq 0 ]; then
    return
  fi
  if [ "$INTERACTIVE" -eq 0 ] || [ "$n" -eq 1 ] || [ ! -t 2 ]; then
    printf '%s\n' "${opts[0]}"
    return
  fi

  local cur=0 key esc i
  printf '  %s?%s %s%s\n' "$MAGENTA" "$RESET" "$prompt" "${DIM} (↑/↓ to move · Enter to select)${RESET}" >&2
  for ((i=0; i<n; i++)); do
    if [ "$i" -eq "$cur" ]; then
      printf '    %s▶ %s%s%s\n' "$CYAN" "$BOLD" "${opts[i]}" "$RESET" >&2
    else
      printf '      %s\n' "${opts[i]}" >&2
    fi
  done

  # Hide cursor, restore on exit
  printf '\033[?25l' >&2
  trap 'printf "\033[?25h" >&2' RETURN

  while true; do
    IFS= read -rsn1 key < /dev/tty || break
    case "$key" in
      $'\e')
        IFS= read -rsn2 -t 0.05 esc < /dev/tty || esc=""
        case "$esc" in
          '[A') (( cur = (cur - 1 + n) % n )) ;;
          '[B') (( cur = (cur + 1) % n )) ;;
        esac
        ;;
      'k') (( cur = (cur - 1 + n) % n )) ;;
      'j') (( cur = (cur + 1) % n )) ;;
      ''|$'\n'|$'\r') break ;;
      'q') cur=-1; break ;;
    esac
    printf '\033[%dA' "$n" >&2
    for ((i=0; i<n; i++)); do
      printf '\033[2K' >&2
      if [ "$i" -eq "$cur" ]; then
        printf '    %s▶ %s%s%s\n' "$CYAN" "$BOLD" "${opts[i]}" "$RESET" >&2
      else
        printf '      %s\n' "${opts[i]}" >&2
      fi
    done
  done

  printf '\033[?25h' >&2
  if [ "$cur" -lt 0 ]; then
    return 1
  fi
  printf '%s\n' "${opts[$cur]}"
}

# Arrow-key Yes/No picker. Args: <prompt> [<default y|n>]
# Returns 0 (Yes) or 1 (No). Default decides initial highlight; non-TTY uses default.
pick_yn() {
  local prompt="$1" default="${2:-n}"
  local choice
  if [ "$INTERACTIVE" -eq 0 ] || [ ! -t 2 ]; then
    [ "$default" = "y" ]
    return
  fi
  if [ "$default" = "y" ]; then
    choice=$(pick_one "$prompt" "Yes" "No")
  else
    choice=$(pick_one "$prompt" "No" "Yes")
  fi
  [ "$choice" = "Yes" ]
}

# --- banner ---------------------------------------------------------------
printf '%s╭───────────────────────╮%s\n' "$DIM" "$RESET"
printf '%s│%s   %s🌸 ccmud installer%s   %s│%s\n' "$DIM" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
printf '%s╰───────────────────────╯%s\n' "$DIM" "$RESET"

# --- dependency checks ----------------------------------------------------
step "Checking dependencies"
missing=()
command -v jq >/dev/null 2>&1 || missing+=(jq)
command -v curl >/dev/null 2>&1 || missing+=(curl)
if [ "${#missing[@]}" -gt 0 ]; then
  err "Missing: ${missing[*]}"
  echo "    macOS:  brew install ${missing[*]}"
  echo "    Linux:  apt install -y ${missing[*]}  (or your distro equivalent)"
  exit 1
fi
ok "jq + curl present"
if ! command -v claude >/dev/null 2>&1; then
  warn "claude CLI not on PATH — installer will continue, but劇情 generation needs it"
else
  ok "claude CLI found at $(command -v claude)"
fi

# --- existing save detection ----------------------------------------------
RE_HATCH=0
EXISTING=""
if [ -f "$MUD_DIR/state.json" ]; then
  EX_NAME=$(jq -r '.player_name // "?"' "$MUD_DIR/state.json" 2>/dev/null || echo "?")
  EX_GENRE=$(jq -r '.genre // "?"' "$MUD_DIR/state.json" 2>/dev/null || echo "?")
  EX_DAY=$(jq -r '.day // 1' "$MUD_DIR/state.json" 2>/dev/null || echo 1)
  EX_TURN=$(jq -r '.turn // 0' "$MUD_DIR/state.json" 2>/dev/null || echo 0)
  EXISTING="${BOLD}${EX_NAME}${RESET}  ${DIM}· ${EX_GENRE} · day ${EX_DAY} · turn ${EX_TURN}${RESET}"
fi

# --- player setup ---------------------------------------------------------
PLAYER_NAME=""
GENRE=""

step "Player setup"
if [ -n "$EXISTING" ]; then
  printf '  %scurrent:%s %b\n' "$DIM" "$RESET" "$EXISTING"
  if pick_yn "Re-hatch with a new save? (state will reset)" "n"; then
    RE_HATCH=1
  else
    ok "Keeping existing save"
  fi
fi

if [ -z "$EXISTING" ] || [ "$RE_HATCH" -eq 1 ]; then
  PLAYER_NAME=$(ask "Player name" "玩家")

  # Pick genre from the list of bundled JSONs so users don't have to type
  # the id (and risk typos that produce a broken save).
  GENRE_IDS=()
  GENRE_LABELS=()
  if [ -d "$SOURCE/genres" ]; then
    for f in "$SOURCE/genres/"*.json; do
      [ -f "$f" ] || continue
      gid=$(jq -r '.id // ""' "$f" 2>/dev/null)
      gname=$(jq -r '.display_name // ""' "$f" 2>/dev/null)
      [ -z "$gid" ] && continue
      GENRE_IDS+=("$gid")
      GENRE_LABELS+=("$gname")
    done
  fi
  if [ "${#GENRE_IDS[@]}" -eq 0 ]; then
    GENRE_IDS=("dating-sim")
    GENRE_LABELS=("戀愛養成")
  fi

  if [ "$INTERACTIVE" -eq 1 ] && [ "${#GENRE_IDS[@]}" -gt 1 ]; then
    # Build display labels "id  —  display_name"
    GENRE_DISPLAY=()
    for i in "${!GENRE_IDS[@]}"; do
      GENRE_DISPLAY+=("$(printf '%-16s  %s' "${GENRE_IDS[i]}" "${GENRE_LABELS[i]}")")
    done
    chosen=$(pick_one "Pick a genre" "${GENRE_DISPLAY[@]}")
    # Map chosen display string back to id (first whitespace-separated token).
    GENRE="${chosen%% *}"
  else
    GENRE="${GENRE_IDS[0]}"
  fi
  ok "Will hatch ${BOLD}${PLAYER_NAME}${RESET} in ${BOLD}${GENRE}${RESET}"
fi

# --- install files --------------------------------------------------------
step "Installing to $MUD_DIR"
mkdir -p "$MUD_DIR" "$MUD_DIR/genres" "$MUD_DIR/prompts"
cp "$SOURCE/mud.sh" "$MUD_DIR/mud.sh"
chmod +x "$MUD_DIR/mud.sh"
ok "mud.sh copied"

if [ -d "$SOURCE/genres" ]; then
  cp "$SOURCE/genres/"*.json "$MUD_DIR/genres/" 2>/dev/null || true
  # Genre lib hooks are optional bash files (see genre_apply_tag /
  # genre_event_style hook architecture). Without these, custom tags like
  # CATCH/HEAL/WORD+ are silently dropped — install always copies them.
  cp "$SOURCE/genres/"*.lib.sh "$MUD_DIR/genres/" 2>/dev/null || true
  local_count=$(ls "$MUD_DIR/genres/"*.json 2>/dev/null | wc -l | tr -d ' ')
  lib_count=$(ls "$MUD_DIR/genres/"*.lib.sh 2>/dev/null | wc -l | tr -d ' ')
  ok "$local_count genre file(s) + $lib_count lib hook(s) copied to $MUD_DIR/genres/"
fi

if [ -d "$SOURCE/prompts" ]; then
  cp "$SOURCE/prompts/"*.txt "$MUD_DIR/prompts/" 2>/dev/null || true
  ok "haiku prompt(s) copied to $MUD_DIR/prompts/"
fi

# --- hatch / re-hatch -----------------------------------------------------
if [ -z "$EXISTING" ] || [ "$RE_HATCH" -eq 1 ]; then
  step "Hatching ${PLAYER_NAME}"
  "$MUD_DIR/mud.sh" hatch "$PLAYER_NAME" "$GENRE" >/dev/null
  ok "Hatched"
fi

# --- settings.json --------------------------------------------------------
step "Wiring statusLine + hooks into settings.json"
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

# Detect existing ccpet statusLine — both can't share status line directly.
EXISTING_SL=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || echo "")
TAKE_STATUSLINE=1
if [ -n "$EXISTING_SL" ] && ! [[ "$EXISTING_SL" == *"$MUD_DIR/mud.sh"* ]]; then
  printf '  %scurrent statusLine:%s %s\n' "$DIM" "$RESET" "$EXISTING_SL"
  if ! pick_yn "Replace it with ccmud's statusLine? (other tool's hooks still run)" "y"; then
    TAKE_STATUSLINE=0
    warn "Keeping existing statusLine — you can switch later by editing $SETTINGS manually"
  fi
fi

TMP=$(mktemp)
if [ "$TAKE_STATUSLINE" -eq 1 ]; then
  jq --arg cmd "$MUD_DIR/mud.sh render" '
    .statusLine = {"type":"command","command":$cmd}
    | .hooks //= {}
    | .hooks.UserPromptSubmit //= []
    | .hooks.UserPromptSubmit |= (
        [.[] | select((.hooks // []) | map(.command) | index("'"$MUD_DIR"'/mud.sh feed-prompt") | not)]
        + [{"hooks":[{"type":"command","command":"'"$MUD_DIR"'/mud.sh feed-prompt","timeout":3}]}]
      )
    | .hooks.Stop //= []
    | .hooks.Stop |= (
        [.[] | select((.hooks // []) | map(.command) | index("'"$MUD_DIR"'/mud.sh feed-stop") | not)]
        + [{"hooks":[{"type":"command","command":"'"$MUD_DIR"'/mud.sh feed-stop","timeout":15}]}]
      )
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  ok "statusLine + UserPromptSubmit + Stop hooks merged"
else
  jq '
    .hooks //= {}
    | .hooks.UserPromptSubmit //= []
    | .hooks.UserPromptSubmit |= (
        [.[] | select((.hooks // []) | map(.command) | index("'"$MUD_DIR"'/mud.sh feed-prompt") | not)]
        + [{"hooks":[{"type":"command","command":"'"$MUD_DIR"'/mud.sh feed-prompt","timeout":3}]}]
      )
    | .hooks.Stop //= []
    | .hooks.Stop |= (
        [.[] | select((.hooks // []) | map(.command) | index("'"$MUD_DIR"'/mud.sh feed-stop") | not)]
        + [{"hooks":[{"type":"command","command":"'"$MUD_DIR"'/mud.sh feed-stop","timeout":15}]}]
      )
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  ok "UserPromptSubmit + Stop hooks merged (statusLine left as-is)"
fi

# --- /mud slash command ---------------------------------------------------
step "Installing /mud slash command"
mkdir -p "$COMMANDS_DIR"
cat > "$COMMANDS_DIR/mud.md" <<'EOF'
# /mud

## Role
Show the current ccmud state: scene, day, focus heroine, affections, last narrative.

## Process
Run `~/.claude/mud/mud.sh stats` and present the JSON in human-readable form.
Then run `~/.claude/mud/mud.sh preview` to render the LCD frame once.
EOF
ok "/mud command installed"

# --- summary --------------------------------------------------------------
step "Done"
"$MUD_DIR/mud.sh" stats 2>/dev/null \
  | jq -r '"  \(.player_name)  ·  \(.genre)  ·  day \(.day)  ·  turn \(.turn)  ·  scene \(.scene)"' 2>/dev/null \
  || warn "could not summarise (state read failed)"

# Show the LCD frame once so the user immediately sees what they get.
printf '\n%s── preview ──────────────────────────────────────────%s\n' "$DIM" "$RESET"
"$MUD_DIR/mud.sh" preview 2>/dev/null || warn "preview failed"
printf '%s─────────────────────────────────────────────────────%s\n' "$DIM" "$RESET"

cat <<EOF

  ${DIM}Try:${RESET}
    ${CYAN}~/.claude/mud/mud.sh preview${RESET}            ${DIM}# render the LCD${RESET}
    ${CYAN}~/.claude/mud/mud.sh stats${RESET}              ${DIM}# JSON state dump${RESET}
    ${CYAN}~/.claude/mud/mud.sh story${RESET}              ${DIM}# read collected narratives${RESET}
    ${CYAN}~/.claude/mud/mud.sh list-genres${RESET}        ${DIM}# see available genres${RESET}
    ${CYAN}~/.claude/mud/mud.sh set-genre <id>${RESET}     ${DIM}# swap genre (state preserved per-genre)${RESET}

  ${YELLOW}!${RESET} ${BOLD}Restart Claude Code${RESET} to pick up the statusLine + hooks.
  ${YELLOW}!${RESET} Background haiku generation requires the ${BOLD}claude${RESET} CLI on PATH and authenticated.
    Without it the LCD still works but only shows fallback narratives.
EOF
