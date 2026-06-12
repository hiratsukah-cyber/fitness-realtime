-- ============================================================
-- finance_pipeline.sql
-- P-3: raw_finance_data → monthly_finance_summary 変換(MERGE)
-- ------------------------------------------------------------
-- プロジェクト: ilex-dashboard / データセット: store_data_v2
-- リージョン   : asia-northeast2(大阪)
--
-- 処理内容:
--   raw_finance_data(確定後)を店舗別・科目別に集計し、
--   store_master と INNER JOIN(未登録 div_id は除外=23店舗のみ)、
--   monthly_finance_summary へ date+div_id キーで MERGE。
--   対象月のみ更新し、他月は保持。何度実行しても結果は同じ(冪等)。
--
-- ★ 月次運用(これだけ):
--   先頭の DECLARE target_date の日付を対象月(YYYY-MM-01)に変えて実行する。
--   変更箇所はこの1行のみ。プリフライト/ポストフライトも同じ target_date を参照する。
--
-- 実行モード:
--   [モードA/推奨] ファイル全体を1スクリプトとして実行
--       → プリフライト → MERGE → ポストフライト が順に走り、各結果が確認できる。
--   [モードB/確認ゲートを挟む] 破壊操作の前に止めて確認したい場合:
--       (1) 先頭の DECLARE 行 ＋ 「プリフライト」ブロックを選択して実行 → 数字を確認
--       (2) 先頭の DECLARE 行 ＋ 「MERGE」ブロックを選択して実行
--       (3) 先頭の DECLARE 行 ＋ 「ポストフライト」ブロックを選択して実行
--       ※どのブロックを単体実行する場合も、必ず先頭の DECLARE 行を一緒に選択する
--         (target_date を共有させるため)。
--
-- 前提(科目名は完全一致が必須):
--   ・人　件　費   … 全角スペース2つ
--   ・ﾊﾟｰｿﾅﾙ有料売上 … 半角カナ
--   ・純売上高 / 販売費及び一般管理費計 は合計科目。内訳とは別列に並存させる
--     (合計と内訳を足すと二重計上になるため、下流で足さないこと)。
--
-- 設計上の注意:
--   ・MERGE採用(CREATE OR REPLACE 不使用)。手入力列(AIコメント等)・他月を壊さない。
--   ・旧BQ(別リージョン)とは直接JOIN不可。本SQLは新BQ内で完結。
--   ・エイリアスに rows / op / ord は予約語で不可。cnt / op_sum / ord_sum を使う。
--
-- 作成: 2026-06-11 (v24セッションで新規作成)
-- 更新: 2026-06-12 (検証クエリの埋め込み日付を target_date 参照に統一/GitHub恒久保存)
-- ============================================================

DECLARE target_date DATE DEFAULT DATE '2026-05-01';  -- ★毎月ここだけ変更する(YYYY-MM-01)


-- ============================================================
-- 【プリフライト】MERGE前に集計結果を確認
--   期待: stores=23 / sum_op・sum_ord が monthly_kpi_summary の合計と一致
-- ============================================================
-- SELECT
--   'preflight' AS phase,
--   COUNT(*) AS stores,
--   SUM(net_sales)        AS sum_net_sales,
--   SUM(operating_profit) AS sum_op,
--   SUM(ordinary_profit)  AS sum_ord
-- FROM (
--   SELECT r.div_id,
--     SUM(IF(r.account_item='純売上高', r.amount,0)) AS net_sales,
--     SUM(IF(r.account_item='営業損益', r.amount,0)) AS operating_profit,
--     SUM(IF(r.account_item='経常損益', r.amount,0)) AS ordinary_profit
--   FROM `ilex-dashboard.store_data_v2.raw_finance_data` r
--   WHERE r.date = target_date
--   GROUP BY r.div_id
-- ) agg
-- INNER JOIN `ilex-dashboard.store_data_v2.store_master` m ON agg.div_id = m.div_id;


-- ============================================================
-- 【本処理】MERGE
-- ============================================================
MERGE `ilex-dashboard.store_data_v2.monthly_finance_summary` T
USING (
  SELECT
    agg.date,
    agg.div_id,
    m.store_id,
    m.store_name,
    m.format,
    m.area,
    agg.net_sales,
    agg.monthly_fee,
    agg.admission_fee,
    agg.other_fee_sales,
    agg.personal_sales,
    agg.event_sales,
    agg.goods_sales,
    agg.sga,
    agg.promotion_cost,
    agg.advertising_cost,
    agg.personnel_cost,
    agg.utility_cost,
    agg.repair_cost,
    agg.operating_profit,
    agg.ordinary_profit
  FROM (
    SELECT
      r.date,
      r.div_id,
      SUM(IF(r.account_item = '純売上高',              r.amount, 0)) AS net_sales,
      SUM(IF(r.account_item = '月会費',                r.amount, 0)) AS monthly_fee,
      SUM(IF(r.account_item = '入会金',                r.amount, 0)) AS admission_fee,
      SUM(IF(r.account_item = 'その他会費売上',         r.amount, 0)) AS other_fee_sales,
      SUM(IF(r.account_item = 'ﾊﾟｰｿﾅﾙ有料売上',        r.amount, 0)) AS personal_sales,
      SUM(IF(r.account_item = '物販催事売上',           r.amount, 0)) AS event_sales,
      SUM(IF(r.account_item = '物販売上',              r.amount, 0)) AS goods_sales,
      SUM(IF(r.account_item = '販売費及び一般管理費計',  r.amount, 0)) AS sga,
      SUM(IF(r.account_item = '販売促進費',            r.amount, 0)) AS promotion_cost,
      SUM(IF(r.account_item = '広告宣伝費',            r.amount, 0)) AS advertising_cost,
      SUM(IF(r.account_item = '人　件　費',            r.amount, 0)) AS personnel_cost,
      SUM(IF(r.account_item = '水道光熱費',            r.amount, 0)) AS utility_cost,
      SUM(IF(r.account_item = '修繕費',                r.amount, 0)) AS repair_cost,
      SUM(IF(r.account_item = '営業損益',              r.amount, 0)) AS operating_profit,
      SUM(IF(r.account_item = '経常損益',              r.amount, 0)) AS ordinary_profit
    FROM `ilex-dashboard.store_data_v2.raw_finance_data` r
    WHERE r.date = target_date
    GROUP BY r.date, r.div_id
  ) agg
  INNER JOIN `ilex-dashboard.store_data_v2.store_master` m
    ON agg.div_id = m.div_id
) S
ON  T.date   = S.date
AND T.div_id = S.div_id
WHEN MATCHED THEN UPDATE SET
  store_id         = S.store_id,
  store_name       = S.store_name,
  format           = S.format,
  area             = S.area,
  net_sales        = S.net_sales,
  monthly_fee      = S.monthly_fee,
  admission_fee    = S.admission_fee,
  other_fee_sales  = S.other_fee_sales,
  personal_sales   = S.personal_sales,
  event_sales      = S.event_sales,
  goods_sales      = S.goods_sales,
  sga              = S.sga,
  promotion_cost   = S.promotion_cost,
  advertising_cost = S.advertising_cost,
  personnel_cost   = S.personnel_cost,
  utility_cost     = S.utility_cost,
  repair_cost      = S.repair_cost,
  operating_profit = S.operating_profit,
  ordinary_profit  = S.ordinary_profit,
  updated_at       = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
  date, div_id, store_id, store_name, format, area,
  net_sales, monthly_fee, admission_fee, other_fee_sales, personal_sales,
  event_sales, goods_sales, sga, promotion_cost, advertising_cost,
  personnel_cost, utility_cost, repair_cost, operating_profit, ordinary_profit,
  updated_at
) VALUES (
  S.date, S.div_id, S.store_id, S.store_name, S.format, S.area,
  S.net_sales, S.monthly_fee, S.admission_fee, S.other_fee_sales, S.personal_sales,
  S.event_sales, S.goods_sales, S.sga, S.promotion_cost, S.advertising_cost,
  S.personnel_cost, S.utility_cost, S.repair_cost, S.operating_profit, S.ordinary_profit,
  CURRENT_TIMESTAMP()
);


-- ============================================================
-- 【ポストフライト】MERGE後の確認
--   ※ エイリアスに rows / op / ord は予約語でエラー。cnt / op_sum / ord_sum を使う
--   期待: cnt=23 / 各合計がプリフライトと一致 / updated_at が実行時刻
-- ============================================================
-- SELECT
--   'postflight' AS phase,
--   COUNT(*) AS cnt,
--   SUM(net_sales)        AS net_sales_sum,
--   SUM(operating_profit) AS op_sum,
--   SUM(ordinary_profit)  AS ord_sum,
--   MIN(updated_at) AS oldest,
--   MAX(updated_at) AS newest
-- FROM `ilex-dashboard.store_data_v2.monthly_finance_summary`
-- WHERE date = target_date;
