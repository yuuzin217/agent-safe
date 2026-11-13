# agent-safe

**やり直しではなく、続きから。** 長時間走る CLI コーディングエージェントが、
ホストの再起動・VM 入れ替わり・プロセス kill を生き延びて、ゼロからではなく
*止まった所から* 再開するための bash ラッパー集です。

設計は共通で、ラッパーは2つ：

| ラッパー | 対象 CLI | 保存先（既定） |
|---|---|---|
| [`agy-safe/`](agy-safe/) | Antigravity CLI (`agy`) | `$HOME/agy-runs/` |
| [`cursor-safe/`](cursor-safe/) | Cursor CLI (`cursor-agent`) | `$HOME/cursor-runs/` |

English: [README.md](README.md)

## 解く問題

揮発性の VM（クラウド開発環境、CI ランナー、入れ替わるサンドボックス）で
エージェントを30〜60分走らせると、途中でホストが再起動・入れ替わることが
あります。本当の被害は再起動そのものではなく、*何をどこまでやったか・
何を決めたか・何を試して捨てたか* が失われて、次の実行がゼロからやり直し、
捨てたはずの案まで繰り返すことです。

## やっていること

1. **実行前に run を永続保存** — prompt・repo・branch・HEAD・`boot_id` を
   永続ストレージ上の run ディレクトリに保存する
2. **60秒ごとのチェックポイント** — git status・diff 全文・diffstat・
   変更ファイルの実物コピーを、tmp 経由で原子的にスナップショットする
   （部分書き込みで前世代が壊れない）。失うのは最大で直近のチェックポイント
   間隔分の未コミット作業まで。これは git コミットではなくスナップショット
   なので履歴は汚れない。コミットはエージェント自身が節目で行う
3. **判断ログ (`PROGRESS.md`)** — 生の推論過程は保存できないため、その蒸留版
   として、節目コミットの「前」に「やったこと／判断と理由／試して捨てた案と
   理由／次の一手／未解決事項」を追記するようラッパーが指示する。追記のみ。
   再開 run はログ全体を引き継ぐ
4. **中断の検出** — `*-check.sh` が、status が `running` のまま boot が
   変わった／PID が消えた run を検出する
5. **再開 prompt の生成** — `--resume RUN_ID` が、元の prompt・チェックポイント
   の diffstat・判断ログ全文を結んだ再開 prompt を作り、後任に「やり直すな・
   捨てた案を再試行するな・未コミット変更を引き継げ」と指示する。さらに
   **再開 run では `git push` を絶対にしない**（commit までで止まる。push は
   別の明示判断のままにする）

自動再開はあえて含めていません。検出と再開 prompt 生成までが範囲で、
cron や監視フックや人間への接続は使う側の自由です。

## 使い方

```bash
agy-safe/agy-check.sh                 # boot 経過と中断 run の確認
agy-safe/agy-run.sh --repo /path/to/repo --prompt task.md --slug my-task

# 途中で落ちたら:
agy-safe/agy-check.sh --mark
agy-safe/agy-run.sh --resume 20261113-101500-my-task
# -> RESUME-prompt.txt を生成し、それで再開 run を始めるコマンドを表示する
```

`cursor-safe/` も `cursor-run.sh` / `cursor-check.sh` で全く同じです。

主なオプション・環境変数： `--model`（既定は agy が
`claude-sonnet-5-5-medium`、Cursor が `composer-2.5`。`AGY_MODEL` /
`CURSOR_MODEL` でも指定可）、`--timeout-min`（既定55）、
`--checkpoint-sec`（既定60）、`AGY_RUNS_DIR` / `CURSOR_RUNS_DIR`、
リスク表示の閾値 `*_RISK_MED_MIN` / `*_RISK_HIGH_MIN`（ヒューリスティクス
なので、ホストの再起動周期が分かる場合はそれに合わせて調整してください）、
テスト用の `DRY_RUN_CMD`。

## 要件

- Linux（`/proc/sys/kernel/random/boot_id`、`uptime -s`、GNU `date -d` を使用。
  macOS はそのままでは非対応）
- bash、git、GNU coreutils
- `agy` および/または `cursor-agent` がインストール・認証済みであること

## 安全上の注意

- エージェントは無人実行モードで起動します（`agy
  --dangerously-skip-permissions`、`cursor-agent --force`）。それを許容できる
  repo・マシンでのみ使ってください。初回利用前に各 `*-run.sh` の起動行を
  確認してください
- run ディレクトリには prompt・diff・ファイルコピーが入ります。対象 repo の
  外に置く設計です。バージョン管理に入れないでください（`.gitignore` 参照）。
  判断ログへの秘密情報の記入は注入ルールで禁止していますが、渡した prompt
  自体はそのままコピーされます
- チェックポイントは同じホストの永続領域にあり、そのホストの再起動は
  生き延びますが、ホスト外バックアップではありません

## 限界

- エージェント内部の推論過程は保存できません。残るのはファイル・コミット・
  チェックポイント・元の prompt・判断ログで、再開したエージェントがそれを
  読み直して文脈を再構成する前提です
- エージェントが判断ログを書かなかった場合も再開は動きます（文脈が薄くなるだけ）
- boot 経過のリスク表示は目安の表示のみで、何かを強制するものではありません

## 出自

「エージェント用 VM が数時間おきに入れ替わり、委任が最大1時間走る」という
個人環境のために作ったものです。その環境固有の実測統計や周辺の自動化
（監視・自動再開）は含めず、移植可能な核だけを切り出しました。両ラッパーとも
dry-run の kill テスト（起動→kill→チェックポイント残存→中断検出→再開 prompt
生成）を確認済みです。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
