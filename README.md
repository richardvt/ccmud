# ccmud

A prompt-driven text MUD that lives in your Claude Code status line. Every prompt you send to Claude advances one game turn — a background `claude -p --model haiku` reads your work prompt, transforms it metaphorically into in-fiction activity, and writes the next 2-4 sentences of story plus typed events (好感+N、捕獲新寶可夢、收集英文單字⋯) which appear in the LCD frame above your status bar.

```
╭── 📍 café · Day 4 · Turn 36 ─────────╮
│ +2 💕 Mia                            │  🎓 Mia ━━━─────── 22 · 溫柔
│ 📖 drizzle — 細雨                    │  📚 詞彙 47  👂 聽力 12  💬 口說 8
│ 📖 overwhelmed — 不知所措的          │  你皺著眉盯著筆記本，旁邊咖啡都涼了。
│ ✿ break the ice — 打破僵局          │  Mia 端著馬克杯走過來：'You look
│ 雪奈：感動                           │  exhausted. Take a break?' 你揉了揉眼
│ +1 📈 聽力                           │  睛，這個 *exhausted* 比中文「累」精準
╰──────────────────────────────────────╯  🧠 31% │ ⏱ 5h 55% │ 📅 7d 49%
```

## Genres bundled

| id | 中文 | 主題 | 主資源 | 玩家屬性 |
|---|---|---|---|---|
| `dating-sim` | 戀愛養成 | 校園戀愛 | 角色好感 0-100 | 智慧 / 魅力 / 體力 |
| `pokemon` | 寶可夢冒險 | 寶可夢訓練家 | 寶可夢等級 | 徽章 / 金錢 / 里程 |
| `english-learn` | 英語留學 | 留學日常 | 親近度 0-100 | 詞彙 / 聽力 / 口說 |

切換完全無損：`mud.sh set-genre <id>` 自動 snapshot 當前進度，下次切回去完整還原。每個 genre 都有獨立存檔。

## Install

```bash
git clone https://github.com/richardvt/ccmud.git
cd ccmud
bash install.sh
```

The installer is interactive — **arrow keys** (↑/↓) + Enter, no typing required for genre / yes-no choices. It will:

- Detect existing save and ask if you want to keep it
- List bundled genres and let you pick one
- Copy `mud.sh` + all `genres/*.json` + `*.lib.sh` + `prompts/` to `~/.claude/mud/`
- Merge ccmud's `statusLine` + `UserPromptSubmit` + `Stop` hooks into `~/.claude/settings.json` (asks before replacing an existing statusLine like ccpet)
- Install a `/mud` slash command for in-Claude-Code state inspection
- Render a sample LCD at the end

Idempotent. Re-run any time to pick up `mud.sh` updates. Existing saves preserved.

**👉 Restart Claude Code after installing** so the statusLine + hooks load.

**Requirements:** bash 4+, `jq`, `curl`, `claude` CLI on PATH (logged-in), Claude Code with statusLine + hooks support.

## How it works

```
你打 prompt
  └ UserPromptSubmit hook → mud.sh feed-prompt
      ├ turn += 1
      └ stash 你的 prompt body 到 $TMPDIR/ccmud/<sid>.last_prompt

(Claude 處理你的請求中…statusLine 每次刷新呼叫 mud.sh render
 — 重畫 LCD，不阻塞、不呼 Haiku)

Claude 結束 → Stop hook → mud.sh feed-stop
  ├ drain 上一輪的 Haiku cache（如有）
  │   ├ 抽 <<TAG>> 套用到 state（push events、改 affection、換 mood⋯）
  │   ├ 寫進 story.log（永久存檔）
  │   └ 設 last_narrative
  ├ 累計 token 用量到 usage.log
  └ 背景 fork claude -p --model haiku 寫下一輪劇情
       └ 寫到 <sid>.<genre>.next.txt（給下個 Stop hook drain）
```

**重要：drain 永遠晚一個 turn。** 你 prompt 第一次後等 60-180s，再 prompt 一次才會看到上一輪的劇情顯示出來。

## Prompt → 劇情映射

Haiku 把你的工作 prompt 隱喻轉換成遊戲世界活動。每個 genre 的對應方式不同：

| 你在做 | dating-sim | pokemon | english-learn |
|---|---|---|---|
| debug / 修 bug | 念書卡關 | 對戰思考 | 啃英文文獻 |
| 寫 code | 練字、寫信 | 訓練寶可夢 | 寫英文 essay |
| 寫 SQL / 查資料 | 翻舊書 | 看圖鑑 | library 找文獻 |
| 開會 / chat | 課堂討論 | 訓練家交流 | study group |
| 跑測試 | 模擬考 | 模擬對戰 | TOEFL practice |

詳細映射規則放在每個 `genres/<id>.json:system_prompt` 裡。

## Commands

```bash
~/.claude/mud/mud.sh preview              # 印一次 LCD 到 terminal
~/.claude/mud/mud.sh stats                # JSON 印當前 state
~/.claude/mud/mud.sh story                # 看劇情 log（最後 60 行）
~/.claude/mud/mud.sh story full           # 整份劇情史
~/.claude/mud/mud.sh story count          # 至今寫了幾個 turn
~/.claude/mud/mud.sh usage                # 每日 token 用量
~/.claude/mud/mud.sh hatch <name> [genre] # 開新存檔
~/.claude/mud/mud.sh set-genre <id>       # 切 genre（per-genre snapshot）
~/.claude/mud/mud.sh list-genres          # 列出可用 genre
~/.claude/mud/mud.sh debug-set <f> <v>    # 直接寫 state.json 欄位
~/.claude/mud/mud.sh update               # 抓 GitHub 最新版蓋過去
~/.claude/mud/mud.sh uninstall            # 移除 hook + 刪 binaries（保留 state）
```

Hook entry points (Claude Code 自動呼叫，不要手動)：`feed-prompt` / `feed-stop` / `render`。

## Tag DSL

每個 genre 共用以下 tag。Haiku 在敘述後面加 `<<TAG>>`，drain 時 mud.sh 套用到 state。

```
<<AFFECTION+3:雪奈>>     好感變化（±N，N=1~5）
<<MOOD:害羞:雪奈>>        心情字串
<<SCENE:咖啡廳>>          場景轉換
<<FOCUS:小薇>>            焦點角色
<<FLAG+:告白_未>>          設置劇情旗標
<<ITEM+:玫瑰>>             獲得物品
<<STAT+1:智慧>>            玩家屬性增減（key 須在 genre.stat_names）
<<NEW_CHAR:凜>>            新角色登場
<<ENDING:雪奈Good>>        終局
```

**Genre 可加自訂 tag** 透過 `genres/<id>.lib.sh` 定義 `genre_apply_tag` hook：

| Genre | 自訂 tag |
|---|---|
| `pokemon` | `<<CATCH:小火龍>>`、`<<HEAL:皮卡丘>>`、`<<FAINT:皮卡丘>>`、`<<BADGE:岩石徽章>>`、`<<EVOLVE:皮卡丘:雷丘>>` |
| `english-learn` | `<<WORD+:exhausted:筋疲力盡的>>`、`<<PHRASE+:break the ice:破冰>>` |

每個 tag 套用後也會自動 push 一行人話到 `events` ring buffer（例：`+3 💕 雪奈`、`📖 exhausted — 筋疲力盡的`）給 LCD 顯示。

## Add your own genre

1. 寫一份 `genres/<id>.json`（schema 見 [`genres/README.md`](genres/README.md)）
2. 可選：寫 `genres/<id>.lib.sh` 定義 `genre_apply_tag` 跟 `genre_event_style`，加自訂 tag
3. `bash install.sh` 重裝（會 copy 新檔案）或直接 `cp` 到 `~/.claude/mud/genres/`
4. `mud.sh set-genre <id>`

範例參考：
- 純 JSON 換皮：[`genres/dating-sim.json`](genres/dating-sim.json)
- JSON + 自訂 tag handler：[`genres/pokemon.json`](genres/pokemon.json) + [`genres/pokemon.lib.sh`](genres/pokemon.lib.sh)

## Files

```
~/.claude/mud/
  ├─ mud.sh                       # 引擎
  ├─ state.json                   # 當前存檔（單一 active slot）
  ├─ saves/<genre>.json           # 每個 genre 的 snapshot（set-genre 自動寫）
  ├─ genres/
  │   ├─ <id>.json                # genre 設定
  │   └─ <id>.lib.sh              # 可選：genre 專屬 tag handler
  ├─ prompts/haiku-base.txt       # 所有 genre 共用的 system prompt 前綴
  ├─ usage.log                    # 每日 token 累計
  └─ story.log                    # 完整劇情史（append-only、跨 genre）
```

## Cost & privacy

- 每個 turn = 一次 Haiku 呼叫（~500 input + ~200 output token），透過你已登入的 `claude` CLI session，**計入你的 quota**。`mud.sh usage` 看每日累計。
- 你的 prompt body 截前 800 字會傳給背景 Haiku（劇情驅動材料）。要關掉：刪 `cmd_feed_prompt` 裡寫 `.last_prompt` 那行，或定期 `rm $TMPDIR/ccmud/*.last_prompt`。
- `state.json` / `story.log` / `usage.log` 都在本機 `~/.claude/mud/`，不外傳。

## Uninstall

```bash
~/.claude/mud/mud.sh uninstall
```

從 `~/.claude/settings.json` 拔掉 ccmud 的 statusLine 跟 hooks，刪除 `mud.sh` / `genres/` / `prompts/` / `saves/` / `/mud` 指令。**保留** `state.json` / `story.log` / `usage.log` 以便將來再裝接續。

完全清光：`rm -rf ~/.claude/mud/`。

## Coexistence with ccpet

兩個工具都想佔 statusLine。`install.sh` 偵測到既有 statusLine 會詢問再覆寫。`UserPromptSubmit` / `Stop` hooks 是 append（兩邊都會 fire）。Hook 之間有 `CCMUD_INTERNAL` env var guard 防止子 claude session 觸發遞迴。

## License

MIT.
