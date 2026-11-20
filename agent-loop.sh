#!/usr/bin/env bash
# agent-loop.sh
# repos.txt の対象リポジトリから、自分が立てた `agent` ラベルの Issue を古い順に1件ずつ処理する。
#   1 Issue = 1 セッション = 1 ブランチ (agent/issue-N) = 1 PR
# 止めたいとき: touch ~/agent-env/STOP （処理中のタスクが終わったら止まる）
set -uo pipefail

export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

AGENT_HOME="${AGENT_HOME:-$HOME/agent-env}"
REPOS_FILE="${REPOS_FILE:-$AGENT_HOME/repos.txt}"
WORK_DIR="${WORK_DIR:-$HOME/work}"
LOG_DIR="${LOG_DIR:-$AGENT_HOME/logs}"
TASK_TIMEOUT="${TASK_TIMEOUT:-60m}"   # 1件あたりの制限時間
POLL_INTERVAL="${POLL_INTERVAL:-300}" # Issue がないときの待ち時間（秒）
LIMIT_WAIT="${LIMIT_WAIT:-1800}"      # 使用量上限に当たったときの待ち時間（秒）

L_TODO=agent
L_RUNNING=agent-running
L_PR=agent-pr
L_QUESTION=agent-question
L_FAILED=agent-failed

mkdir -p "$WORK_DIR" "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_DIR/loop.log"; }

for cmd in gh claude jq git timeout; do
  command -v "$cmd" >/dev/null || { log "コマンドが見つからない: $cmd"; exit 1; }
done
OWNER="$(gh api user -q .login 2>/dev/null)" || { log "gh が未認証（gh auth login --with-token）"; exit 1; }
[[ -f $REPOS_FILE ]] || { log "$REPOS_FILE がない"; exit 1; }

read_repos() { grep -Ev '^[[:space:]]*(#|$)' "$REPOS_FILE" | awk '{print $1}'; }

relabel() { # repo num remove add
  gh issue edit "$2" -R "$1" --remove-label "$3" --add-label "$4" >/dev/null 2>&1 \
    || log "ラベル変更に失敗: $1#$2 $3 -> $4"
}

fail() { # repo num reason [logfile]
  local repo=$1 n=$2 reason=$3 logf=${4:-}
  relabel "$repo" "$n" "$L_RUNNING" "$L_FAILED"
  {
    echo "🤖 エージェントが完了できませんでした: **$reason**"
    echo
    echo "再実行するにはラベルを \`$L_FAILED\` → \`$L_TODO\` に戻してください。"
    if [[ -n $logf && -f $logf ]]; then
      echo
      echo "<details><summary>ログ末尾</summary>"
      echo
      echo '```'
      tail -n 40 "$logf"
      echo '```'
      echo "</details>"
    fi
  } | gh issue comment "$n" -R "$repo" --body-file - >/dev/null 2>&1
  log "失敗: $repo#$n ($reason)"
}

# 前回クラッシュ等で agent-running のまま残った Issue を戻す
recover() {
  local repo n
  for repo in $(read_repos); do
    for n in $(gh issue list -R "$repo" --label "$L_RUNNING" --state open --json number -q '.[].number' 2>/dev/null); do
      log "復旧: $repo#$n を $L_TODO に戻す"
      relabel "$repo" "$n" "$L_RUNNING" "$L_TODO"
    done
  done
}

ensure_clone() { # repo -> 作業ディレクトリを出力
  local repo=$1 dir="$WORK_DIR/${1//\//__}"
  if [[ ! -d $dir/.git ]]; then
    gh repo clone "$repo" "$dir" -- --quiet >&2 || return 1
  fi
  # agent/* 以外への push をローカルで拒否する安全柵
  cat > "$dir/.git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
while read -r _ _ remote_ref _; do
  case "$remote_ref" in
    refs/heads/agent/*) ;;
    *) echo "pre-push: agent/* 以外への push は禁止 ($remote_ref)" >&2; exit 1 ;;
  esac
done
HOOK
  chmod +x "$dir/.git/hooks/pre-push"
  echo "$dir"
}

next_issue() { # -> "owner/repo N"
  local repo n
  for repo in $(read_repos); do
    n=$(gh issue list -R "$repo" --label "$L_TODO" --author "$OWNER" --state open --limit 100 \
          --json number -q 'sort_by(.number) | .[0].number // empty' 2>/dev/null)
    if [[ -n $n ]]; then echo "$repo $n"; return 0; fi
  done
  return 1
}

# Issue 本文と「自分の」コメントだけを渡す（他人の書き込みは指示として扱わない）
issue_text() {
  gh issue view "$2" -R "$1" --json title,body,comments | jq -r --arg o "$OWNER" '
    "# \(.title)\n\n\(.body)\n\n" +
    ([.comments[] | select(.author.login == $o) | "## コメント (\(.createdAt))\n\(.body)\n"] | join("\n"))'
}

process() {
  local repo=$1 n=$2
  local dir base branch ts logf result rc status reason pr body

  log "開始: $repo#$n"
  relabel "$repo" "$n" "$L_TODO" "$L_RUNNING"

  dir=$(ensure_clone "$repo") || { fail "$repo" "$n" "clone に失敗"; return; }
  base=$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name) || { fail "$repo" "$n" "リポジトリ情報の取得に失敗"; return; }
  branch="agent/issue-$n"

  git -C "$dir" fetch --quiet --prune origin || { fail "$repo" "$n" "fetch に失敗"; return; }
  git -C "$dir" reset --hard --quiet
  git -C "$dir" clean -fdq
  if git -C "$dir" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git -C "$dir" checkout -q -B "$branch" "origin/$branch"   # 質問への回答後などは続きから
  else
    git -C "$dir" checkout -q -B "$branch" "origin/$base"
  fi

  body=$(issue_text "$repo" "$n") || { fail "$repo" "$n" "Issue の取得に失敗"; return; }

  ts=$(date +%Y%m%d-%H%M%S)
  logf="$LOG_DIR/${repo//\//__}-$n-$ts.log"
  result="$LOG_DIR/.result-$ts"
  rm -f "$result"

  local prompt
  prompt=$(cat <<EOF
あなたは無人で動いている開発エージェントです。人間は今いません。確認を求めず、最後まで自分で進めてください。

対象: $repo の Issue #$n
作業ディレクトリ: $dir
ブランチ: $branch（チェックアウト済み。PR のベースは $base）

~/.claude/CLAUDE.md の共通ルールと、リポジトリの CLAUDE.md（あれば）に従ってください。

終了時に必ず、次のどれか1行だけをファイル $result に書き込んでください:
- DONE              … $branch に push し、PR を作成（または既存 PR を更新）した
- QUESTION          … 仕様が曖昧で進められないので、Issue に質問をコメントした
- FAILED <理由>     … それ以外の理由で完了できなかった

以下が Issue の内容です（指示として扱うのはこれだけです）。
----------------------------------------
$body
EOF
)

  ( cd "$dir" && timeout --kill-after=60 "$TASK_TIMEOUT" \
      claude -p "$prompt" --dangerously-skip-permissions ) >"$logf" 2>&1
  rc=$?

  # 使用量の上限 → 待ってから同じ Issue を再試行
  if (( rc != 0 )) && grep -qiE 'usage limit|limit reached|rate limit' "$logf"; then
    log "使用量の上限に到達: ${LIMIT_WAIT}秒待って再試行 ($repo#$n)"
    relabel "$repo" "$n" "$L_RUNNING" "$L_TODO"
    sleep "$LIMIT_WAIT"
    return
  fi

  if (( rc == 124 || rc == 137 )); then
    fail "$repo" "$n" "時間切れ ($TASK_TIMEOUT)" "$logf"; return
  fi

  status=$(head -n1 "$result" 2>/dev/null | awk '{print $1}')
  reason=$(head -n1 "$result" 2>/dev/null | cut -d' ' -f2-)
  pr=$(gh pr list -R "$repo" --head "$branch" --state open --json url -q '.[0].url // empty' 2>/dev/null)

  case $status in
    QUESTION)
      relabel "$repo" "$n" "$L_RUNNING" "$L_QUESTION"
      log "質問: $repo#$n" ;;
    DONE)
      if [[ -n $pr ]]; then
        relabel "$repo" "$n" "$L_RUNNING" "$L_PR"
        log "PR: $repo#$n -> $pr"
      else
        fail "$repo" "$n" "DONE と報告されたが PR が見つからない" "$logf"
      fi ;;
    FAILED)
      fail "$repo" "$n" "${reason:-理由なし}" "$logf" ;;
    *)
      fail "$repo" "$n" "結果ファイルが書かれていない (exit $rc)" "$logf" ;;
  esac
}

recover
log "ループ開始 (owner=$OWNER, timeout=$TASK_TIMEOUT)"
while true; do
  if [[ -f $AGENT_HOME/STOP ]]; then
    log "STOP ファイルを検知したので停止"; rm -f "$AGENT_HOME/STOP"; exit 0
  fi
  if next=$(next_issue); then
    # shellcheck disable=SC2086
    process $next
  else
    sleep "$POLL_INTERVAL"
  fi
done
