#!/usr/bin/env bash
# Windows のタスクスケジューラから呼ぶ。
# tmux セッション "agent" でループを起動し、sleep で WSL を起こしたままにする。
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
if ! tmux has-session -t agent 2>/dev/null; then
  tmux new-session -d -s agent "$HOME/agent-env/agent-loop.sh; exec bash"
fi
exec sleep infinity
