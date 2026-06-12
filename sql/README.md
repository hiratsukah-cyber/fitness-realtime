# finance_pipeline.sql — P-3 財務確定値の変換（MERGE）

`raw_finance_data`（PCAから取り込んだ確定後の財務データ）を店舗別・科目別に集計し、
`store_master` と INNER JOIN（23店舗のみ）して `monthly_finance_summary` へ **MERGE** するSQL。

- **プロジェクト**：`ilex-dashboard` / **データセット**：`store_data_v2`
- **リージョン**：`asia-northeast2`（大阪）
- **想定置き場所**：`hiratsukah-cyber/fitness-realtime` リポジトリ `/sql/finance_pipeline.sql`

このSQLは月次確定取込み標準手順（作業継続メモ v24 §A-1）の **ステップ4（P-3）** に対応する。
正本がこれまで引き継ぎメモ本文にしか無く単一障害点だったため、リポジトリへ恒久保存する。

---

## 月次運用（これだけ）

1. 先頭の `DECLARE target_date DATE DEFAULT DATE 'YYYY-MM-01';` の日付を**対象月に変更**（変更はこの1行のみ）。
2. 実行する（下記モードA／B）。
3. ポストフライトで **cnt=23**・主要値が `monthly_kpi_summary` の合計と一致することを確認。

### 実行モード
- **モードA（推奨・一括）**：ファイル全体を1スクリプトとして実行。プリフライト→MERGE→ポストフライトが順に走る。
- **モードB（確認ゲートを挟む）**：破壊操作の前に止めたい場合、
  1. 先頭の `DECLARE` 行 ＋ プリフライトブロックを選択実行 → 数字を確認
  2. 先頭の `DECLARE` 行 ＋ MERGEブロックを選択実行
  3. 先頭の `DECLARE` 行 ＋ ポストフライトブロックを選択実行
  - どのブロックを単体実行する場合も、**必ず先頭の `DECLARE` 行を一緒に選択**する（`target_date` を共有させるため）。

---

## 守るべき原則（このSQLが前提にしていること）

- **MERGE採用（`CREATE OR REPLACE` 不使用）**：対象月の行のみ更新し、他月とAIコメント等の手入力列を壊さない。冪等（何度実行しても同結果）。
- **科目名は完全一致**：`人　件　費`（全角スペース2つ）／`ﾊﾟｰｿﾅﾙ有料売上`（半角カナ）。`純売上高`・`販売費及び一般管理費計` は**合計科目**で、内訳とは別列に並存（合計と内訳を足すと二重計上）。
- **23店舗フィルタ**：`store_master` と INNER JOIN。未登録 div_id（本部・枝番等）は自動除外。`div_id` は INT64 なのでSQLで引用符を付けない。
- **予約語**：エイリアスに `rows`/`op`/`ord` 不可。`cnt`/`op_sum`/`ord_sum` を使う。
- **リージョン制約**：旧BQ（別リージョン）とは直接JOIN不可。本SQLは新BQ内で完結。

---

## 関連（月次確定取込み標準手順 §A-1 の全体像）

1. `raw_finance_data` を確定値に差し替え（`runFinanceImport` → 科目別合計の確定前比較 → `importFinanceToBigQuery`）
2. `monthly_kpi_summary` 財務系8列をUPDATE（raw→store_master JOIN）
3. 該当月のAIコメントを DELETE → 再生成
4. **本SQL（P-3）を実行** ← ここ

> ※プリフライト/ポストフライトを定常運用にも転用できるよう、検証クエリも `target_date` を参照する。
