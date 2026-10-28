DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_monitor_auc;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_monitor_auc AS
-- =====================================================================
WITH

-- =====================================================================
-- 1) application 级别去重 + 拉 ai_base_score + fpd7_flag + 时间字段
-- =====================================================================
base_dedup AS (
    SELECT *
    FROM (
        SELECT
            t.application_id,
            t.application_date,
            t.app_order_desc,

            t.old_risk_bid_submodel_250909_txn,
            t.old_risk_bid_mltmodel_v1_1_20251021,
            t.old_risk_bid_appmodel_v1_1_20250911,

            t.duedate_1m_5,
            t.duedate_1m_30,
            t.duedate_2m_30,
            t.duedate_3m_30,

            -- ================= 新增模型分 =================
            (1 - cp.base_probability) AS ai_base_score,

            CASE
                WHEN 1 - cp.base_probability < 0.111014 THEN 20
                WHEN 1 - cp.base_probability < 0.175004 THEN 40
                WHEN 1 - cp.base_probability < 0.270748 THEN 60
                WHEN 1 - cp.base_probability < 0.426544 THEN 80
                ELSE 100
            END AS ai_base_bin,

            -- ================= FPD7 标签 =================
            CASE
                WHEN cp.application_status = '4.Funded'
                 AND cp.first_payment_scheduled_date < CURRENT_DATE()-7
                 AND cp.first_payment_days_past_due_ever > 7
                THEN 1
                WHEN cp.application_status = '4.Funded'
                 AND cp.first_payment_scheduled_date < CURRENT_DATE()-7
                THEN 0
                ELSE NULL
            END AS fpd7_flag,

            -- ================= 时间字段统一来自 cp =================
            cp.dispersal_week  AS dispersal_week,
            cp.dispersal_month AS dispersal_month,

            ROW_NUMBER() OVER (
                PARTITION BY t.application_id
                ORDER BY t.app_order_desc DESC
            ) AS rn

        FROM model.tmp_eliam_risk_000004_strategy_monitor t
        LEFT JOIN ba.customer_profile_rawdata cp
            ON t.application_id = cp.application_id
        WHERE t.application_date > DATE '2024-01-01'
    ) x
    WHERE rn = 1
),

-- =====================================================================
-- 2) WEEK 粒度长表
-- =====================================================================
week_long AS (
    SELECT
        'WEEK' AS time_grain,
        COALESCE(base_dedup.dispersal_week, 'UNFUNDED') AS time_key,
        application_id,
        label_name,
        model_name,
        model_score,
        label_value
    FROM base_dedup
    LATERAL VIEW STACK (
        20,

        'duedate_1m_5','submodel',old_risk_bid_submodel_250909_txn,duedate_1m_5,
        'duedate_1m_5','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_5,
        'duedate_1m_5','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_5,
        'duedate_1m_5','ai_base',ai_base_score,duedate_1m_5,

        'duedate_1m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_1m_30,
        'duedate_1m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_30,
        'duedate_1m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_30,
        'duedate_1m_30','ai_base',ai_base_score,duedate_1m_30,

        'duedate_2m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_2m_30,
        'duedate_2m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_2m_30,
        'duedate_2m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_2m_30,
        'duedate_2m_30','ai_base',ai_base_score,duedate_2m_30,

        'duedate_3m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_3m_30,
        'duedate_3m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_3m_30,
        'duedate_3m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_3m_30,
        'duedate_3m_30','ai_base',ai_base_score,duedate_3m_30,

        'fpd7_flag','submodel',old_risk_bid_submodel_250909_txn,fpd7_flag,
        'fpd7_flag','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,fpd7_flag,
        'fpd7_flag','appmodel',old_risk_bid_appmodel_v1_1_20250911,fpd7_flag,
        'fpd7_flag','ai_base',ai_base_score,fpd7_flag
    ) AS label_name, model_name, model_score, label_value
),

-- =====================================================================
-- 3) MONTH 粒度
-- =====================================================================
month_long AS (
    SELECT
        'MONTH' AS time_grain,
        COALESCE(base_dedup.dispersal_month, 'UNFUNDED') AS time_key,
        application_id,
        label_name,
        model_name,
        model_score,
        label_value
    FROM base_dedup
    LATERAL VIEW STACK (
        20,

        'duedate_1m_5','submodel',old_risk_bid_submodel_250909_txn,duedate_1m_5,
        'duedate_1m_5','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_5,
        'duedate_1m_5','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_5,
        'duedate_1m_5','ai_base',ai_base_score,duedate_1m_5,

        'duedate_1m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_1m_30,
        'duedate_1m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_30,
        'duedate_1m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_30,
        'duedate_1m_30','ai_base',ai_base_score,duedate_1m_30,

        'duedate_2m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_2m_30,
        'duedate_2m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_2m_30,
        'duedate_2m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_2m_30,
        'duedate_2m_30','ai_base',ai_base_score,duedate_2m_30,

        'duedate_3m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_3m_30,
        'duedate_3m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_3m_30,
        'duedate_3m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_3m_30,
        'duedate_3m_30','ai_base',ai_base_score,duedate_3m_30,

        'fpd7_flag','submodel',old_risk_bid_submodel_250909_txn,fpd7_flag,
        'fpd7_flag','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,fpd7_flag,
        'fpd7_flag','appmodel',old_risk_bid_appmodel_v1_1_20250911,fpd7_flag,
        'fpd7_flag','ai_base',ai_base_score,fpd7_flag
    ) AS label_name, model_name, model_score, label_value
),

union_long AS (
    SELECT * FROM week_long
    UNION ALL
    SELECT * FROM month_long
),

-- =====================================================================
-- 5) ROC 累计量（仅对已表现样本）
-- =====================================================================
roc_base AS (
    SELECT
        time_grain,
        time_key,
        label_name,
        model_name,
        application_id,
        model_score,
        label_value,

        SUM(label_value) OVER (
            PARTITION BY time_grain, time_key, label_name, model_name
        ) AS tot_y1,

        SUM(1 - label_value) OVER (
            PARTITION BY time_grain, time_key, label_name, model_name
        ) AS tot_y0,

        SUM(label_value) OVER (
            PARTITION BY time_grain, time_key, label_name, model_name
            ORDER BY model_score DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS csum_y1,

        SUM(1 - label_value) OVER (
            PARTITION BY time_grain, time_key, label_name, model_name
            ORDER BY model_score DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS csum_y0
    FROM union_long
    WHERE
        label_value IN (0,1)
        AND model_score IS NOT NULL
),

-- =====================================================================
-- 6) TPR / FPR + 前一节点
-- =====================================================================
roc_curve AS (
    SELECT
        time_grain,
        time_key,
        label_name,
        model_name,

        csum_y1 / tot_y1 AS tpr,
        csum_y0 / tot_y0 AS fpr,

        LEAD(csum_y1 / tot_y1) OVER (
            PARTITION BY time_grain, time_key, label_name, model_name
            ORDER BY csum_y1 / tot_y1 DESC
        ) AS pre_tpr,

        LEAD(csum_y0 / tot_y0) OVER (
            PARTITION BY time_grain, time_key, label_name, model_name
            ORDER BY csum_y0 / tot_y0 DESC
        ) AS pre_fpr,

        tot_y1,
        tot_y0
    FROM roc_base
),

-- =====================================================================
-- 7) ROC 梯形积分 AUC
-- =====================================================================
auc_agg AS (
    SELECT
        time_grain,
        time_key,
        label_name,
        model_name,

        MAX(tot_y1) AS pos_cnt,
        MAX(tot_y0) AS neg_cnt,

        SUM((tpr + pre_tpr) / 2 * (fpr - pre_fpr)) AS auc
    FROM roc_curve
    WHERE pre_tpr IS NOT NULL
      AND pre_fpr IS NOT NULL
    GROUP BY
        time_grain,
        time_key,
        label_name,
        model_name
),

-- =====================================================================
-- 8) 样本量统计（保持你原口径）
-- =====================================================================
cnt_agg AS (
    SELECT
        time_grain,
        time_key,
        label_name,
        model_name,

        COUNT(DISTINCT application_id) AS total_application_cnt,
        SUM(CASE WHEN label_value IN (0,1) THEN 1 END) AS performance_cnt,
        SUM(CASE WHEN label_value = 1 THEN 1 END) AS pos_cnt,
        SUM(CASE WHEN label_value = 0 THEN 1 END) AS neg_cnt,
        SUM(CASE WHEN label_value IS NULL THEN 1 END) AS unperformance_cnt
    FROM union_long
    GROUP BY
        time_grain,
        time_key,
        label_name,
        model_name
)

-- =====================================================================
-- 9) 最终输出
-- =====================================================================
SELECT
    c.time_grain,
    c.time_key,
    c.label_name,
    c.model_name,

    c.total_application_cnt,
    c.performance_cnt,
    c.pos_cnt,
    c.neg_cnt,
    c.unperformance_cnt,

    a.pos_cnt   AS auc_pos_cnt,
    a.neg_cnt   AS auc_neg_cnt,
    a.auc
FROM cnt_agg c
LEFT JOIN auc_agg a
    ON  c.time_grain = a.time_grain
    AND c.time_key   = a.time_key
    AND c.label_name = a.label_name
    AND c.model_name = a.model_name;