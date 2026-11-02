-- ============================================================
-- v20261102 表版本：在 v2 基础上把 4 个新模型分的“回溯分”拼进来
-- 目标表：model.tmp_eliam_risk_000004_strategy_run_log_v20261102
--
-- 4 张回溯分表（1 行/application_id）：
--   model.tmp_eliam_existing_aus_new_worthiness_bid_3rdmodel_v1_0_20240101_20260914
--     -> aus_new_worthiness_bid_3rdmodel_v1_0_20260429
--   model.tmp_eliam_existing_aus_old_risk_bid_appmodel_v1_2_20240101_20260914
--     -> aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score
--   model.tmp_eliam_existing_aus_old_risk_bid_mltmodel_v1_2_20240101_20260914
--     -> aus_old_risk_bid_mltmodel_v1_2_v20260325_lgb_score
--        映射为 old_risk_bid_mltmodel_v1_2_20260325（线上字段名）
--   model.tmp_eliam_existing_aus_old_risk_bid_submodel_v1_2_20240101_20260914
--     -> aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
--
-- 拼接口径：
--   线上段(application_id > 2153006)：4 个字段 = COALESCE(线上日志解析值, 回溯分)
--     —— 2026-09-15 起线上有值；2025-11-24 ~ 2026-09-14 用回溯分补
--   回溯段(application_id <= 2153006)：INSERT 时直接带上 4 个回溯分
--
-- 注意：maxcompute 非事务表不支持 UPDATE ... JOIN，所以只能“重建”。
--       若 v2 已落表且不想重扫 ODS，可改成
--       v20261102 = (SELECT * FROM v2) LEFT JOIN 宽表 的写法（需 * EXCEPT 语法）。
-- ============================================================


-- ============================================================
-- 0) 4 张分表 -> 1 张宽表（1 行/application_id）
--    __source_file 可能来自多个分片：同一 application_id 取
--    “有值优先、sample_datetime 最新、分片最新”的一条
-- ============================================================
DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_backtest_score_4model;

CREATE TABLE model.tmp_eliam_risk_000004_backtest_score_4model AS
WITH worthiness AS (
    SELECT application_id, user_id, sample_datetime,
           aus_new_worthiness_bid_3rdmodel_v1_0_20260429
    FROM (
        SELECT application_id, user_id, sample_datetime,
               aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
               ROW_NUMBER() OVER (
                   PARTITION BY application_id
                   ORDER BY CASE WHEN aus_new_worthiness_bid_3rdmodel_v1_0_20260429 IS NOT NULL THEN 0 ELSE 1 END,
                            sample_datetime DESC,
                            __source_file DESC
               ) AS rn
        FROM model.tmp_eliam_existing_aus_new_worthiness_bid_3rdmodel_v1_0_20240101_20260914
        WHERE application_id IS NOT NULL
    ) t
    WHERE rn = 1
),
appmodel AS (
    SELECT application_id, user_id, sample_datetime,
           aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score
    FROM (
        SELECT application_id, user_id, sample_datetime,
               aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
               ROW_NUMBER() OVER (
                   PARTITION BY application_id
                   ORDER BY CASE WHEN aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score IS NOT NULL THEN 0 ELSE 1 END,
                            sample_datetime DESC,
                            __source_file DESC
               ) AS rn
        FROM model.tmp_eliam_existing_aus_old_risk_bid_appmodel_v1_2_20240101_20260914
        WHERE application_id IS NOT NULL
    ) t
    WHERE rn = 1
),
mltmodel AS (
    SELECT application_id, user_id, sample_datetime,
           old_risk_bid_mltmodel_v1_2_20260325
    FROM (
        SELECT application_id, user_id, sample_datetime,
               aus_old_risk_bid_mltmodel_v1_2_v20260325_lgb_score AS old_risk_bid_mltmodel_v1_2_20260325,
               ROW_NUMBER() OVER (
                   PARTITION BY application_id
                   ORDER BY CASE WHEN aus_old_risk_bid_mltmodel_v1_2_v20260325_lgb_score IS NOT NULL THEN 0 ELSE 1 END,
                            sample_datetime DESC,
                            __source_file DESC
               ) AS rn
        FROM model.tmp_eliam_existing_aus_old_risk_bid_mltmodel_v1_2_20240101_20260914
        WHERE application_id IS NOT NULL
    ) t
    WHERE rn = 1
),
submodel AS (
    SELECT application_id, user_id, sample_datetime,
           aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
    FROM (
        SELECT application_id, user_id, sample_datetime,
               aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,
               ROW_NUMBER() OVER (
                   PARTITION BY application_id
                   ORDER BY CASE WHEN aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score IS NOT NULL THEN 0 ELSE 1 END,
                            sample_datetime DESC,
                            __source_file DESC
               ) AS rn
        FROM model.tmp_eliam_existing_aus_old_risk_bid_submodel_v1_2_20240101_20260914
        WHERE application_id IS NOT NULL
    ) t
    WHERE rn = 1
),
merged AS (
    SELECT application_id, user_id, sample_datetime,
           aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
           CAST(NULL AS DOUBLE) AS aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
           CAST(NULL AS DOUBLE) AS old_risk_bid_mltmodel_v1_2_20260325,
           CAST(NULL AS DOUBLE) AS aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
    FROM worthiness
    UNION ALL
    SELECT application_id, user_id, sample_datetime,
           CAST(NULL AS DOUBLE) AS aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
           aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
           CAST(NULL AS DOUBLE) AS old_risk_bid_mltmodel_v1_2_20260325,
           CAST(NULL AS DOUBLE) AS aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
    FROM appmodel
    UNION ALL
    SELECT application_id, user_id, sample_datetime,
           CAST(NULL AS DOUBLE) AS aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
           CAST(NULL AS DOUBLE) AS aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
           old_risk_bid_mltmodel_v1_2_20260325,
           CAST(NULL AS DOUBLE) AS aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
    FROM mltmodel
    UNION ALL
    SELECT application_id, user_id, sample_datetime,
           CAST(NULL AS DOUBLE) AS aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
           CAST(NULL AS DOUBLE) AS aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
           CAST(NULL AS DOUBLE) AS old_risk_bid_mltmodel_v1_2_20260325,
           aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
    FROM submodel
)
SELECT
    application_id,
    MAX(user_id)         AS user_id,
    MAX(sample_datetime) AS sample_datetime,
    MAX(aus_new_worthiness_bid_3rdmodel_v1_0_20260429)          AS aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
    MAX(aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score)   AS aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
    MAX(old_risk_bid_mltmodel_v1_2_20260325)                    AS old_risk_bid_mltmodel_v1_2_20260325,
    MAX(aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score) AS aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
FROM merged
GROUP BY application_id
;


-- ============================================================
-- 1) 线上段(application_id > 2153006)
--    4 个新字段：线上优先，线上为空（2026-09-15 前）用回溯分补
--
--    为避免与 parsed.data.* 里的同名列冲突，parsed 的 JSON schema
--    里不再包含这 4 个字段；改由 new_scores 单独解析后 COALESCE
-- ============================================================
DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_run_log_v20261102;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_run_log_v20261102 AS
WITH strategy AS (
    SELECT
        t._id,
        t.serial_number,
        t.user_id,
        t.scene_id,
        t.strategy_id,
        t.strategy_code,
        t.start_time,
        t.end_time,
        t.inserttime,
        t.parsed.code,
        t.parsed.message,
        t.parsed.data.*,
        t.parsed.data.old_risk_bid_submodel_250909_txn_features.*,
        -- 4 个新增模型分：线上值优先；2026-09-15 前线上为空，取回溯分
        COALESCE(t.new_scores.data.aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
                 b.aus_new_worthiness_bid_3rdmodel_v1_0_20260429)
            AS aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
        COALESCE(t.new_scores.data.old_risk_bid_mltmodel_v1_2_20260325,
                 b.old_risk_bid_mltmodel_v1_2_20260325)
            AS old_risk_bid_mltmodel_v1_2_20260325,
        COALESCE(t.new_scores.data.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
                 b.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score)
            AS aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
        COALESCE(t.new_scores.data.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,
                 b.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score)
            AS aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score
    FROM (
        SELECT
            _id,
            serial_number,
            user_id,
            scene_id,
            strategy_id,
            strategy_code,
            start_time,
            end_time,
            inserttime,
            FROM_JSON(
                strategy_result,
                SCHEMA_OF_JSON('{
                  "code": "0000",
                  "data": {
                    "finv_predicted_frequency": null,
                    "finv_hardrule_hit": {},
                    "finv_predicted_loan_amount": null,
                    "finv_is_auto_declined": 1,
                    "old_risk_bid_submodel_250909_txn_features": {
                      "txn_raw_input_cnt": 1879,
                      "bank_txn_category_cluster_debt_share_168d": 0.02398356397931769,
                      "balance_date_max": "2025-11-23",
                      "bank_txn_lender_repay_amount_sum_l168d": 6042.4800000000005,
                      "bank_txn_balance_rate_dec_max_84d": 1.645602736969209,
                      "bank_txn_category_global_credit_cnt_14d": 102,
                      "bank_txn_category_centrelink_avg_ticket_84d": 0.0,
                      "bank_txn_category_dishonours_credit_cnt_168d": 21,
                      "bank_txn_category_sacc_loans_debit_amt_182d": 986.64,
                      "bank_txn_income_wage_amountcv_past6months": 0.19361793153365983,
                      "bank_txn_balance_credit_entropy_182d": 0.6042473954455039,
                      "bank_txn_category_cluster_transfers_share_28d": 0.7213335220838052,
                      "send_time": "2025-11-18 09:46:08",
                      "bank_txn_balance_credit_sum_182d": 78044.23,
                      "transaction_date_max": "2025-11-22",
                      "txn_balance_input_cnt": 543,
                      "bank_txn_lender_disburse_advance_amount_max": 550.0,
                      "bank_txn_category_insurance_debit_cnt_56d": 7,
                      "bank_txn_lender_disburse_loan_amount_sum_l84d": 4600.0,
                      "bank_txn_lender_repay_bnpl_amount_avg_l28d": 49.7321052631579,
                      "bank_txn_category_cluster_utilities_share_84d": 0.01387069511675715,
                      "bank_txn_category_cluster_risk_obligations_share_182d": 0.025156144050093095,
                      "bank_txn_category_cluster_healthcare_share_84d": 0.015286567706311184,
                      "bank_txn_lender_repay_loan_amount_sum_l168d": 457.82
                    },
                    "finv_softrule_hit": {},
                    "finv_predicted_pea_surplus_a_period": null,
                    "finv_strategy_label": {},
                    "finv_predicted_pea_surplus_the_period": null,
                    "finv_is_antifraud_approved": 1,
                    "finv_ab_testing_label": {},
                    "finv_predicted_loan_term": null,
                    "finv_predicted_pei_surplus": null,
                    "old_risk_bid_submodel_250909_txn": 0.3096799481436624,
                    "old_risk_bid_mltmodel_v1_1_20251021": 0.29866775034580517,
                    "finv_predicted_max_repayment_amount_fn": 0.0,
                    "finv_predicted_min_loan_term_fn": 5,
                    "finv_predicted_max_loan_term_fn": 19,
                    "finv_risk_level": "F",
                    "finv_is_hardrule_approved": 1,
                    "finv_predicted_max_loan_amount": 0,
                    "finv_recommended_manual_approval": 0,
                    "finv_predicted_repayment_amount": null,
                    "finv_version_id": "prod-old-20251112-v1.0.2",
                    "application_id": 2145246,
                    "old_risk_bid_appmodel_v1_1_20250911": 0.12189618254312477,
                    "finv_is_model_approved": 0,
                    "finv_predicted_net_surplus": null,
                    "finv_predicted_repayment_amount_fn": null,
                    "finv_explanation": [
                      { "detail": "Combination Selection Empty", "type": "No Predicted Amount" },
                      { "detail": "High Risk Level Triggered", "type": "Declined" }
                    ],
                    "finv_is_auto_approved": 0,
                    "finv_risk_color_code": "RED",
                    "finv_predicted_probability_of_default": 0.29866775034580517,
                    "finv_predicted_fee_rate": null
                  },
                  "message": "成功",
                  "reqSerial": "10000072479f43a828-8172-3931-3cf2-51fcd1260e64",
                  "serialNumber": "3ZLB52v3IcGZmjEXwt",
                  "timestamp": "2025-11-23 01:47:37.355"
                }')
            ) AS parsed,
            -- 4 个新增模型分单独解析（避免和 parsed.data.* 同名列冲突）
            FROM_JSON(
                strategy_result,
                SCHEMA_OF_JSON('{
                  "data": {
                    "aus_new_worthiness_bid_3rdmodel_v1_0_20260429": 0.11124540597867838,
                    "old_risk_bid_mltmodel_v1_2_20260325": 0.04734612684051521,
                    "aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score": 0.06690794695567287,
                    "aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score": 0.0589468273601335
                  }
                }')
            ) AS new_scores
        FROM ods.aus_cbd_gidp_core_gidp_strategy_run_log
        WHERE strategy_code = 'RISK_000004'
    ) t
    LEFT JOIN model.tmp_eliam_risk_000004_backtest_score_4model b
        ON t.parsed.data.application_id = b.application_id
),
model AS (
    SELECT
        serial_number,
        FROM_JSON(
            model_input,
            SCHEMA_OF_JSON('{
              "paydebt_overdue_cnt_l184d":7,
              "bid_pay_days_gap_l1t":3,
              "maturity":42,
              "paydebt_pay_bid_days_prop_max_l184d":1.20896,
              "paydebt_overdue_cnt_avg1m_dv_avg6m":0.0714285746216774,
              "paydebt_pay_bid_days_prop_avg":1.0410012006759644,
              "min_monthly_expenses":2516,
              "paydebt_overdue_pay_days_max":28,
              "paydebt_listing_cnt":-1,
              "min_monthly_income":4264.54
            }')
        ) AS model_input_parsed
    FROM ods.aus_cbd_gidp_core_gidp_model_run_log
    WHERE model_code = 'old_risk_bid_appmodel_v1_1'
),
final_join AS (
    SELECT
        s.*,
        m.model_input_parsed.*
    FROM strategy s
    LEFT JOIN model m
        ON s.serial_number = m.serial_number
),
final_filtered AS (
    SELECT *
    FROM final_join
    WHERE application_id > 2153006
)
SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY application_id ORDER BY inserttime ASC)  AS app_order_asc,
    ROW_NUMBER() OVER (PARTITION BY application_id ORDER BY inserttime DESC) AS app_order_desc
FROM final_filtered
;


-- ============================================================
-- 2) 回溯段(application_id <= 2153006)追加
--    在原有 6 个字段基础上，增加 4 个回溯分
-- ============================================================
INSERT INTO TABLE model.tmp_eliam_risk_000004_strategy_run_log_v20261102
(
  user_id,
  application_id,
  inserttime,
  old_risk_bid_mltmodel_v1_1_20251021,
  old_risk_bid_appmodel_v1_1_20250911,
  old_risk_bid_submodel_250909_txn,
  aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
  old_risk_bid_mltmodel_v1_2_20260325,
  aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
  aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,
  app_order_asc,
  app_order_desc
)
SELECT
  t.user_id,
  t.application_id,
  t.sample_datetime AS inserttime,  -- sample_datetime(=inserttime)
  t.old_risk_apply_mltmodel_v20250910       AS old_risk_bid_mltmodel_v1_1_20251021,
  t.old_risk_apply_appmodel_v250909         AS old_risk_bid_appmodel_v1_1_20250911,
  t.old_risk_apply_submodel_250909_bank     AS old_risk_bid_submodel_250909_txn,
  b.aus_new_worthiness_bid_3rdmodel_v1_0_20260429,
  b.old_risk_bid_mltmodel_v1_2_20260325,
  b.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,
  b.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,
  ROW_NUMBER() OVER (PARTITION BY t.application_id ORDER BY t.sample_datetime ASC)  AS app_order_asc,
  ROW_NUMBER() OVER (PARTITION BY t.application_id ORDER BY t.sample_datetime DESC) AS app_order_desc
FROM model.tmp_lyz_old_risk_bid_v1_1_backtrack_260211 t
LEFT JOIN model.tmp_eliam_risk_000004_backtest_score_4model b
    ON t.application_id = b.application_id
WHERE t.application_id <= 2153006
;