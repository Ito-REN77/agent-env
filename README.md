# agent-env — Claude Code を無人で回すための専用 WSL2 環境

GitHub Issue に `agent` ラベルを付けると、寝ている間にエージェントが1件ずつ処理して PR を出す。

```
Issue (agent) ─▶ agent-loop.sh ─▶ claude -p (確認なし, 60分まで) ─▶ PR (agent-pr)
                                                        ├▶ 質問 (agent-question)
                                                        └▶ 失敗 (agent-failed)
```

## 中身

| ファイル | 役割 |
|---|---|
| `wsl.conf` | Windows 側マウントと interop を切る |
| `bootstrap.sh` | ディストリ初期化（ユーザー、sudo、gh、Claude Code、mise、uv） |
| `agent-loop.sh` | Issue → PR のループ本体 |
| `start.sh` | tmux でループを起動し、WSL を起こしたままにする |
| `add-repo.sh` | 対象リポジトリの追加とラベル作成 |
| `CLAUDE.md` | 共通ルール（`~/.claude/CLAUDE.md` に置かれる） |
| `repos.txt.example` | 対象リポジトリ一覧のひな形 |

---

## セットアップ

### 1. Windows 側の準備（PowerShell・管理者）

```powershell
wsl --install --no-distribution   # WSL2 未導入なら。終わったら再起動
wsl --update

# スリープ・休止を無効化（AC 電源時）
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
```

- Windows Update: 設定 → Windows Update → 詳細オプション → **アクティブ時間** を「夜も含む」ように設定し、勝手に再起動させない
- `%UserProfile%\.wslconfig` に以下を書いて、アイドルで WSL の VM が止まらないようにする

```ini
[wsl2]
vmIdleTimeout=-1
```

### 2. agent ディストリを作る

```powershell
wsl --install Ubuntu-24.04 --name agent --location C:\wsl\agent --no-launch
```

`--name` が使えない古い WSL の場合は、エクスポートとインポートで作る:

```powershell
wsl --install -d Ubuntu-24.04          # 一度作ってユーザー作成まで済ませる
wsl --export Ubuntu-24.04 $env:TEMP\ubuntu.tar
wsl --import agent C:\wsl\agent $env:TEMP\ubuntu.tar
```

### 3. 初期化する

このフォルダを Windows 側の分かりやすい場所（例 `C:\agent-env`）に置いてから:

```powershell
wsl -d agent -u root -- bash /mnt/c/agent-env/bootstrap.sh
wsl --terminate agent
wsl -d agent          # agent ユーザーで入る
```

入り直したら、境界が閉じていることを確認する:

```bash
ls /mnt/c          # → 存在しない or 空
cmd.exe            # → command not found
```

### 4. GitHub の PAT を作る

GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate

- **Expiration**: 90日など（期限切れになったら作り直す）
- **Repository access**: Only select repositories → 対象リポジトリ（まず `agent-inbox`）
- **Permissions**（Repository）:
  - Contents: Read and write
  - Pull requests: Read and write
  - Issues: Read and write
  - Metadata: Read-only（自動）
  - Workflows は付けない

ディストリの中で:

```bash
gh auth login --with-token   # PAT を貼り付けて Enter → Ctrl-D
gh auth setup-git
gh auth status
```

### 5. Claude Code にログインする

```bash
claude                                  # サブスクのアカウントでログイン → /exit
claude --dangerously-skip-permissions   # 初回の確認画面を一度承認しておく → /exit
```

### 6. 対象リポジトリを登録する

まず `agent-inbox`（コード以外の依頼用）を GitHub に作ってから:

```bash
cd ~/agent-env
./add-repo.sh <your-name>/agent-inbox
./add-repo.sh <your-name>/<他のリポジトリ>
```

追加のたびに、PAT の Repository access にもそのリポジトリを足す。

> **ブランチ保護について**: 無料プランの private リポジトリではブランチ保護・ruleset が使えない。
> その代わり `agent-loop.sh` が各クローンに **`agent/*` 以外への push を拒否する pre-push フック** を入れ、
> `CLAUDE.md` でも禁止している。public リポジトリや有料プランなら、デフォルトブランチに保護をかけておく。

### 7. 手動で試す

```bash
tmux new -s agent ~/agent-env/agent-loop.sh
```

`agent-inbox` に Issue を1つ立てて `agent` ラベルを付け、PR が出るのを確認する。
例: 「`hello.md` に今日の日付と自己紹介を書いて」

### 8. 自動起動にする（PowerShell）

```powershell
$a = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d agent -- /home/agent/agent-env/start.sh"
$t = New-ScheduledTaskTrigger -AtLogOn
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "agent-wsl" -Action $a -Trigger $t -Settings $s
```

ログオン時に tmux セッション `agent` でループが立ち上がる。

### 9. 外から覗けるようにする

1. Windows に [Tailscale](https://tailscale.com/) を入れ、スマホにも入れて同じアカウントでログイン
2. Windows に OpenSSH Server を入れる（PowerShell・管理者）

   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service sshd -StartupType Automatic
   ```
3. スマホの SSH アプリ（Termius など）から Tailscale の IP に接続して:

   ```
   wsl -d agent -- tmux attach -t agent
   ```
   離れるときは `Ctrl-b d`（ループは止まらない）

---

## 毎日の使い方

**夜**: Issue を書いて `agent` ラベルを付ける（スマホの GitHub アプリで OK）。

**朝**: GitHub で3つのラベルを見る。

| ラベル | やること |
|---|---|
| `agent-pr` | PR をレビューしてマージ（Issue は `Closes #N` で閉じる） |
| `agent-question` | Issue のコメントに回答し、ラベルを `agent` に戻す |
| `agent-failed` | コメントのログを見て Issue を直し、ラベルを `agent` に戻す |

回答後に `agent` へ戻すと、既存の `agent/issue-N` ブランチの続きから再開する。

## 調整

環境変数で上書きできる（`start.sh` の中で export するのが楽）。

| 変数 | 既定 | 意味 |
|---|---|---|
| `TASK_TIMEOUT` | `60m` | 1件の制限時間 |
| `POLL_INTERVAL` | `300` | Issue が無いときの待ち（秒） |
| `LIMIT_WAIT` | `1800` | 使用量上限時の待ち（秒） |

- 止める: `touch ~/agent-env/STOP`（今のタスクが終わったら止まる）
- ログ: `~/agent-env/logs/loop.log` と、タスクごとの `*.log`

## 壊れたとき・リセット

```powershell
wsl --export agent C:\wsl\agent-backup.tar     # 調子の良いときにスナップショット
wsl --unregister agent                          # 壊れたら消す
wsl --import agent C:\wsl\agent C:\wsl\agent-backup.tar
```

漏洩が疑われるときは、**PAT を GitHub 上で即失効** → ディストリを作り直す。箱の中にある秘密は PAT と Claude のログインだけ。

## 安全の前提（変えるときは注意）

- 箱の中に普段使いの SSH 鍵、`.env`、他サービスのトークンを**入れない**
- `agent` ラベルの Issue は **自分が作者のものだけ** 処理し、コメントも自分のものだけ渡している
- Unity など Windows 側のアプリが必要なリポジトリは対象外（interop を切っているため）
