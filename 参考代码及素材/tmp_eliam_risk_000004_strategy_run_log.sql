-- 1) 老客log表更新0228
DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_run_log;

-- 2) 先用“上线后数据(application_id > 2153006)”建表：字段结构完全沿用你原来的逻辑
CREATE TABLE model.tmp_eliam_risk_000004_strategy_run_log AS
WITH strategy AS (
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
        parsed.code,
        parsed.message,
        parsed.data.*,
        parsed.data.old_risk_bid_submodel_250909_txn_features.*
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
            ) AS parsed
        FROM ods.aus_cbd_gidp_core_gidp_strategy_run_log
        WHERE strategy_code = 'RISK_000004'
    ) t
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

-- 3) 再把“上线前 backtrack(application_id <= 2153006)”追加进来
--    只提供 6 个字段 + 两个排序字段，其它字段在目标表里自动补 NULL
INSERT INTO TABLE model.tmp_eliam_risk_000004_strategy_run_log
(
  user_id,
  application_id,
  inserttime,
  old_risk_bid_mltmodel_v1_1_20251021,
  old_risk_bid_appmodel_v1_1_20250911,
  old_risk_bid_submodel_250909_txn,
  app_order_asc,
  app_order_desc
)
SELECT
  user_id,
  application_id,
  sample_datetime AS inserttime,  -- sample_datetime(=inserttime)
  old_risk_apply_mltmodel_v20250910       AS old_risk_bid_mltmodel_v1_1_20251021,
  old_risk_apply_appmodel_v250909         AS old_risk_bid_appmodel_v1_1_20250911,
  old_risk_apply_submodel_250909_bank     AS old_risk_bid_submodel_250909_txn,
  ROW_NUMBER() OVER (PARTITION BY application_id ORDER BY sample_datetime ASC)  AS app_order_asc,
  ROW_NUMBER() OVER (PARTITION BY application_id ORDER BY sample_datetime DESC) AS app_order_desc
FROM model.tmp_lyz_old_risk_bid_v1_1_backtrack_260211
WHERE application_id <= 2153006
;