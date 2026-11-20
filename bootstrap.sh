#!/usr/bin/env bash
# 新しく作った agent ディストリの中で、root として1回だけ実行する。
#   Windows 側から: wsl -d agent -u root -- bash /mnt/c/<このフォルダ>/bootstrap.sh
# （この時点ではまだ /mnt/c が見える。実行後に wsl --terminate agent で境界が閉じる）
set -euo pipefail

U=agent
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== apt パッケージ"
apt-get update
apt-get install -y git curl jq tmux build-essential unzip ca-certificates gnupg

echo "== GitHub CLI"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y gh

echo "== ユーザー $U（パスワードなし sudo）"
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
echo "$U ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$U"
chmod 440 "/etc/sudoers.d/$U"

echo "== /etc/wsl.conf（Windows 側との境界）"
install -m 644 "$SRC_DIR/wsl.conf" /etc/wsl.conf

echo "== キットを /home/$U/agent-env にコピー"
install -d -o "$U" -g "$U" "/home/$U/agent-env"
cp -r "$SRC_DIR"/. "/home/$U/agent-env/"
chown -R "$U:$U" "/home/$U/agent-env"

echo "== ユーザー領域のツール（Claude Code / mise / uv）"
sudo -u "$U" -H bash -l <<'EOF'
set -euo pipefail
curl -fsSL https://claude.ai/install.sh | bash
curl -fsSL https://mise.run | sh
curl -LsSf https://astral.sh/uv/install.sh | sh

mkdir -p ~/.claude ~/work
cp ~/agent-env/CLAUDE.md ~/.claude/CLAUDE.md
chmod +x ~/agent-env/*.sh
[ -f ~/agent-env/repos.txt ] || cp ~/agent-env/repos.txt.example ~/agent-env/repos.txt

# 非対話シェル（tmux 内のループ）でも claude / mise のツールが見えるように
grep -q 'agent-env PATH' ~/.profile 2>/dev/null || cat >> ~/.profile <<'P'
# agent-env PATH
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
P
grep -q 'mise activate' ~/.bashrc || echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc

git config --global user.name  "agent (Claude Code)"
git config --global user.email "agent@localhost"
git config --global init.defaultBranch main
EOF

echo
echo "完了。Windows 側で 'wsl --terminate agent' してから 'wsl -d agent' で入り直してください。"
echo "入り直したら ls /mnt/c が空（または存在しない）ことを確認してください。"
