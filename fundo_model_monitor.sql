-- =====================================================================
-- 1.1 老客模型 by 周 AUC 监控
-- 数据源：model.tmp_eliam_risk_000004_strategy_run_log_v3
--   * 每个 application 取最新一次 run（app_order_desc = 1）
--   * 周口径：放款周 cp.dispersal_week，未放款归入 UNFUNDED
-- 标签：FPD7 + 首期 5+/30+、2 期 30+、3 期 30+
-- 监控分：submodel / mltmodel / appmodel（v1.1）
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_monitor_auc_v1_1;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_monitor_auc_v1_1 AS
WITH base AS (
    SELECT
        r.application_id,
        COALESCE(cp.dispersal_week, 'UNFUNDED') AS time_key,

        r.old_risk_bid_submodel_250909_txn,
        r.old_risk_bid_mltmodel_v1_1_20251021,
        r.old_risk_bid_appmodel_v1_1_20250911,

        CASE
            WHEN cp.application_status = '4.Funded'
             AND cp.first_payment_scheduled_date < CURRENT_DATE() - 7
             AND cp.first_payment_days_past_due_ever > 7
            THEN 1
            WHEN cp.application_status = '4.Funded'
             AND cp.first_payment_scheduled_date < CURRENT_DATE() - 7
            THEN 0
            ELSE NULL
        END AS fpd7_flag,

        lv.duedate_1m_5,
        lv.duedate_1m_30,
        lv.duedate_2m_30,
        lv.duedate_3m_30
    FROM model.tmp_eliam_risk_000004_strategy_run_log_v3 r
    LEFT JOIN ba.customer_profile_rawdata cp
        ON r.application_id = cp.application_id
    LEFT JOIN model.tmp_eliam_listing_vintage lv
        ON r.application_id = lv.application_id
    WHERE r.app_order_desc = 1
),

-- 标签 × 模型 展开成长表
long AS (
    SELECT
        time_key,
        application_id,
        label_name,
        model_name,
        model_score,
        label_value
    FROM base
    LATERAL VIEW STACK (
        15,

        'fpd7_flag','submodel',old_risk_bid_submodel_250909_txn,fpd7_flag,
        'fpd7_flag','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,fpd7_flag,
        'fpd7_flag','appmodel',old_risk_bid_appmodel_v1_1_20250911,fpd7_flag,

        'duedate_1m_5','submodel',old_risk_bid_submodel_250909_txn,duedate_1m_5,
        'duedate_1m_5','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_5,
        'duedate_1m_5','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_5,

        'duedate_1m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_1m_30,
        'duedate_1m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_30,
        'duedate_1m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_30,

        'duedate_2m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_2m_30,
        'duedate_2m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_2m_30,
        'duedate_2m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_2m_30,

        'duedate_3m_30','submodel',old_risk_bid_submodel_250909_txn,duedate_3m_30,
        'duedate_3m_30','mltmodel',old_risk_bid_mltmodel_v1_1_20251021,duedate_3m_30,
        'duedate_3m_30','appmodel',old_risk_bid_appmodel_v1_1_20250911,duedate_3m_30
    ) AS label_name, model_name, model_score, label_value
),

-- ROC 累计量（仅已表现样本）
roc_base AS (
    SELECT
        time_key,
        label_name,
        model_name,
        application_id,
        model_score,
        label_value,

        SUM(label_value) OVER (
            PARTITION BY time_key, label_name, model_name
        ) AS tot_y1,

        SUM(1 - label_value) OVER (
            PARTITION BY time_key, label_name, model_name
        ) AS tot_y0,

        SUM(label_value) OVER (
            PARTITION BY time_key, label_name, model_name
            ORDER BY model_score DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS csum_y1,

        SUM(1 - label_value) OVER (
            PARTITION BY time_key, label_name, model_name
            ORDER BY model_score DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS csum_y0
    FROM long
    WHERE
        label_value IN (0,1)
        AND model_score IS NOT NULL
),

-- TPR / FPR + 前一节点
roc_curve AS (
    SELECT
        time_key,
        label_name,
        model_name,

        csum_y1 / tot_y1 AS tpr,
        csum_y0 / tot_y0 AS fpr,

        LEAD(csum_y1 / tot_y1) OVER (
            PARTITION BY time_key, label_name, model_name
            ORDER BY csum_y1 / tot_y1 DESC
        ) AS pre_tpr,

        LEAD(csum_y0 / tot_y0) OVER (
            PARTITION BY time_key, label_name, model_name
            ORDER BY csum_y0 / tot_y0 DESC
        ) AS pre_fpr,

        tot_y1,
        tot_y0
    FROM roc_base
),

-- ROC 梯形积分 AUC
auc_agg AS (
    SELECT
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
        time_key,
        label_name,
        model_name
),

-- 样本量统计
cnt_agg AS (
    SELECT
        time_key,
        label_name,
        model_name,

        COUNT(DISTINCT application_id) AS total_application_cnt,
        SUM(CASE WHEN label_value IN (0,1) THEN 1 END) AS performance_cnt,
        SUM(CASE WHEN label_value = 1 THEN 1 END) AS pos_cnt,
        SUM(CASE WHEN label_value = 0 THEN 1 END) AS neg_cnt,
        SUM(CASE WHEN label_value IS NULL THEN 1 END) AS unperformance_cnt
    FROM long
    GROUP BY
        time_key,
        label_name,
        model_name
)

SELECT
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
    ON  c.time_key    = a.time_key
    AND c.label_name  = a.label_name
    AND c.model_name  = a.model_name
;
