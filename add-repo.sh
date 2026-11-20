#!/usr/bin/env bash
# 対象リポジトリを追加する: ./add-repo.sh owner/name
# repos.txt への追記とラベル作成を行う。PAT の対象追加は GitHub 上で手動。
set -euo pipefail
repo=${1:?使い方: add-repo.sh owner/name}
cd "$(dirname "$0")"

touch repos.txt
grep -qx "$repo" repos.txt || echo "$repo" >> repos.txt

gh label create agent          -R "$repo" --color 1D76DB --description "エージェントに任せる"        --force
gh label create agent-running  -R "$repo" --color FBCA04 --description "エージェントが作業中"        --force
gh label create agent-pr       -R "$repo" --color 0E8A16 --description "PR が出た。レビュー待ち"      --force
gh label create agent-question -R "$repo" --color D876E3 --description "エージェントからの質問あり"  --force
gh label create agent-failed   -R "$repo" --color B60205 --description "エージェントが完了できず"    --force

echo
echo "追加しました: $repo"
echo "残りの手作業:"
echo "  1. PAT の Repository access にこのリポジトリを追加"
echo "  2. （可能なら）デフォルトブランチにブランチ保護 / ruleset を設定"
