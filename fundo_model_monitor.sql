-- =====================================================================
-- 老客模型 by 周 AUC 监控（1.1 vs 1.2）
-- 数据源：model.tmp_eliam_risk_000004_strategy_run_log_v3
--   * 每个 application 取最新一次 run（app_order_desc = 1）
--   * 周口径：放款周 cp.dispersal_week，未放款归入 UNFUNDED
-- 标签：FPD7 + 首期 5+/30+、2 期 30+、3 期 30+
-- 监控分（5 标签 × 6 分 = STACK 30 行）：
--   mltmodel（融合主模型）/ submodel（银行流水子模型）/ appmodel（行为子模型）
--   v1.1 与 v1.2 各一套
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_weekly_auc;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_weekly_auc AS
WITH base AS (
    SELECT
        r.application_id,
        COALESCE(CAST(cp.dispersal_week AS STRING), 'UNFUNDED') AS time_key,

        CAST(r.old_risk_bid_submodel_250909_txn AS DOUBLE) AS old_risk_bid_submodel_250909_txn,
        CAST(r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score AS DOUBLE) AS aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,
        CAST(r.old_risk_bid_mltmodel_v1_1_20251021 AS DOUBLE) AS old_risk_bid_mltmodel_v1_1_20251021,
        CAST(r.old_risk_bid_mltmodel_v1_2_20260325 AS DOUBLE) AS old_risk_bid_mltmodel_v1_2_20260325,
        CAST(r.old_risk_bid_appmodel_v1_1_20250911 AS DOUBLE) AS old_risk_bid_appmodel_v1_1_20250911,
        CAST(r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score AS DOUBLE) AS aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,

        CAST(CASE
            WHEN cp.application_status = '4.Funded'
             AND cp.first_payment_scheduled_date < CURRENT_DATE() - 7
             AND cp.first_payment_days_past_due_ever > 7
            THEN 1
            WHEN cp.application_status = '4.Funded'
             AND cp.first_payment_scheduled_date < CURRENT_DATE() - 7
            THEN 0
            ELSE NULL
        END AS INT) AS fpd7_flag,

        CAST(lv.duedate_1m_5 AS INT) AS duedate_1m_5,
        CAST(lv.duedate_1m_30 AS INT) AS duedate_1m_30,
        CAST(lv.duedate_2m_30 AS INT) AS duedate_2m_30,
        CAST(lv.duedate_3m_30 AS INT) AS duedate_3m_30
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
        30,

        'fpd7_flag','old_risk_bid_submodel_250909_txn',old_risk_bid_submodel_250909_txn,fpd7_flag,
        'fpd7_flag','aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score',aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,fpd7_flag,
        'fpd7_flag','old_risk_bid_mltmodel_v1_1_20251021',old_risk_bid_mltmodel_v1_1_20251021,fpd7_flag,
        'fpd7_flag','old_risk_bid_mltmodel_v1_2_20260325',old_risk_bid_mltmodel_v1_2_20260325,fpd7_flag,
        'fpd7_flag','old_risk_bid_appmodel_v1_1_20250911',old_risk_bid_appmodel_v1_1_20250911,fpd7_flag,
        'fpd7_flag','aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score',aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,fpd7_flag,

        'duedate_1m_5','old_risk_bid_submodel_250909_txn',old_risk_bid_submodel_250909_txn,duedate_1m_5,
        'duedate_1m_5','aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score',aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,duedate_1m_5,
        'duedate_1m_5','old_risk_bid_mltmodel_v1_1_20251021',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_5,
        'duedate_1m_5','old_risk_bid_mltmodel_v1_2_20260325',old_risk_bid_mltmodel_v1_2_20260325,duedate_1m_5,
        'duedate_1m_5','old_risk_bid_appmodel_v1_1_20250911',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_5,
        'duedate_1m_5','aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score',aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,duedate_1m_5,

        'duedate_1m_30','old_risk_bid_submodel_250909_txn',old_risk_bid_submodel_250909_txn,duedate_1m_30,
        'duedate_1m_30','aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score',aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,duedate_1m_30,
        'duedate_1m_30','old_risk_bid_mltmodel_v1_1_20251021',old_risk_bid_mltmodel_v1_1_20251021,duedate_1m_30,
        'duedate_1m_30','old_risk_bid_mltmodel_v1_2_20260325',old_risk_bid_mltmodel_v1_2_20260325,duedate_1m_30,
        'duedate_1m_30','old_risk_bid_appmodel_v1_1_20250911',old_risk_bid_appmodel_v1_1_20250911,duedate_1m_30,
        'duedate_1m_30','aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score',aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,duedate_1m_30,

        'duedate_2m_30','old_risk_bid_submodel_250909_txn',old_risk_bid_submodel_250909_txn,duedate_2m_30,
        'duedate_2m_30','aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score',aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,duedate_2m_30,
        'duedate_2m_30','old_risk_bid_mltmodel_v1_1_20251021',old_risk_bid_mltmodel_v1_1_20251021,duedate_2m_30,
        'duedate_2m_30','old_risk_bid_mltmodel_v1_2_20260325',old_risk_bid_mltmodel_v1_2_20260325,duedate_2m_30,
        'duedate_2m_30','old_risk_bid_appmodel_v1_1_20250911',old_risk_bid_appmodel_v1_1_20250911,duedate_2m_30,
        'duedate_2m_30','aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score',aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,duedate_2m_30,

        'duedate_3m_30','old_risk_bid_submodel_250909_txn',old_risk_bid_submodel_250909_txn,duedate_3m_30,
        'duedate_3m_30','aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score',aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score,duedate_3m_30,
        'duedate_3m_30','old_risk_bid_mltmodel_v1_1_20251021',old_risk_bid_mltmodel_v1_1_20251021,duedate_3m_30,
        'duedate_3m_30','old_risk_bid_mltmodel_v1_2_20260325',old_risk_bid_mltmodel_v1_2_20260325,duedate_3m_30,
        'duedate_3m_30','old_risk_bid_appmodel_v1_1_20250911',old_risk_bid_appmodel_v1_1_20250911,duedate_3m_30,
        'duedate_3m_30','aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score',aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score,duedate_3m_30
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

-- =====================================================================
-- 老客转化漏斗（按申请周，仅 user_tag = Existing）
-- 完成率 = 完成 / 申请；通过率 = 通过 / 完成；成交率 = 成交 / 通过
-- 成交口径：status ∈ Active_Account / Closed / Blocked
-- 自动/人工通过：assessment_status 含 Auto Approved / Manual Approved
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_weekly_funnel;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_weekly_funnel AS
WITH apps AS (
    SELECT
        CAST(cp.application_week AS STRING) AS time_key,

        CASE
            WHEN cp.application_status IS NULL
              OR cp.application_status IN ('0.Incomplete', '1.In Progress')
            THEN 0 ELSE 1
        END AS completed_flag,

        CASE
            WHEN LEFT(cp.application_status, 1) IN ('3', '4') THEN 1 ELSE 0
        END AS approved_flag,

        CASE
            WHEN LEFT(cp.application_status, 1) IN ('3', '4')
             AND cp.assessment_status LIKE '%Auto Approved%'
            THEN 1 ELSE 0
        END AS auto_approved_flag,

        CASE
            WHEN LEFT(cp.application_status, 1) IN ('3', '4')
             AND cp.assessment_status LIKE '%Manual Approved%'
            THEN 1 ELSE 0
        END AS manual_approved_flag,

        CASE
            WHEN cp.status IN ('Active_Account', 'Closed', 'Blocked') THEN 1 ELSE 0
        END AS deal_flag,

        CASE
            WHEN cp.application_status = '4.Funded' THEN 1 ELSE 0
        END AS funded_flag

    FROM model.tmp_eliam_risk_000004_strategy_run_log_v3 r
    LEFT JOIN ba.customer_profile_rawdata cp
        ON r.application_id = cp.application_id
    WHERE r.app_order_desc = 1
      AND cp.user_tag = 'Existing'
)
SELECT
    time_key,
    COUNT(*) AS application_cnt,
    SUM(completed_flag) AS completed_cnt,
    SUM(approved_flag) AS approved_cnt,
    SUM(auto_approved_flag) AS auto_approved_cnt,
    SUM(manual_approved_flag) AS manual_approved_cnt,
    SUM(deal_flag) AS deal_cnt,
    SUM(funded_flag) AS funded_cnt
FROM apps
WHERE time_key IS NOT NULL
GROUP BY time_key
;

-- =====================================================================
-- 老客 1.1 / 1.2 分箱坏账率（按放款周）
-- 箱 1-5：分数从低到高（1 最好，5 最差），箱 5 为 > 第 4 个阈值
-- 标签：FPD7、首期 30+
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_weekly_bin;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_weekly_bin AS
WITH base AS (
    SELECT
        COALESCE(CAST(cp.dispersal_week AS STRING), 'UNFUNDED') AS time_key,

        -- v1.1 分箱
        CASE
            WHEN r.old_risk_bid_submodel_250909_txn IS NULL THEN NULL
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.052011 THEN 1
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.07337  THEN 2
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.099983 THEN 3
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.14444  THEN 4
            ELSE 5
        END AS bin_sub_v11,

        CASE
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 IS NULL THEN NULL
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.039873 THEN 1
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.057702 THEN 2
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.089551 THEN 3
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.149927 THEN 4
            ELSE 5
        END AS bin_mlt_v11,

        CASE
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 IS NULL THEN NULL
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.051164 THEN 1
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.071347 THEN 2
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.095801 THEN 3
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.138524 THEN 4
            ELSE 5
        END AS bin_app_v11,

        -- v1.2 分箱
        CASE
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score IS NULL THEN NULL
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.045117 THEN 1
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.063512 THEN 2
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.087708 THEN 3
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.130728 THEN 4
            ELSE 5
        END AS bin_sub_v12,

        CASE
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 IS NULL THEN NULL
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.035078 THEN 1
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.054394 THEN 2
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.081105 THEN 3
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.132466 THEN 4
            ELSE 5
        END AS bin_mlt_v12,

        CASE
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score IS NULL THEN NULL
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.051725 THEN 1
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.069226 THEN 2
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.090624 THEN 3
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.1212   THEN 4
            ELSE 5
        END AS bin_app_v12,

        CAST(CASE
            WHEN cp.application_status = '4.Funded'
             AND cp.first_payment_scheduled_date < CURRENT_DATE() - 7
             AND cp.first_payment_days_past_due_ever > 7
            THEN 1
            WHEN cp.application_status = '4.Funded'
             AND cp.first_payment_scheduled_date < CURRENT_DATE() - 7
            THEN 0
            ELSE NULL
        END AS INT) AS fpd7_flag,

        CAST(lv.duedate_1m_30 AS INT) AS duedate_1m_30
    FROM model.tmp_eliam_risk_000004_strategy_run_log_v3 r
    LEFT JOIN ba.customer_profile_rawdata cp
        ON r.application_id = cp.application_id
    LEFT JOIN model.tmp_eliam_listing_vintage lv
        ON r.application_id = lv.application_id
    WHERE r.app_order_desc = 1
),

long AS (
    SELECT
        time_key,
        label_name,
        model_name,
        model_bin,
        label_value
    FROM base
    LATERAL VIEW STACK (
        12,

        'fpd7_flag','old_risk_bid_submodel_250909_txn',bin_sub_v11,fpd7_flag,
        'fpd7_flag','aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score',bin_sub_v12,fpd7_flag,
        'fpd7_flag','old_risk_bid_mltmodel_v1_1_20251021',bin_mlt_v11,fpd7_flag,
        'fpd7_flag','old_risk_bid_mltmodel_v1_2_20260325',bin_mlt_v12,fpd7_flag,
        'fpd7_flag','old_risk_bid_appmodel_v1_1_20250911',bin_app_v11,fpd7_flag,
        'fpd7_flag','aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score',bin_app_v12,fpd7_flag,

        'duedate_1m_30','old_risk_bid_submodel_250909_txn',bin_sub_v11,duedate_1m_30,
        'duedate_1m_30','aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score',bin_sub_v12,duedate_1m_30,
        'duedate_1m_30','old_risk_bid_mltmodel_v1_1_20251021',bin_mlt_v11,duedate_1m_30,
        'duedate_1m_30','old_risk_bid_mltmodel_v1_2_20260325',bin_mlt_v12,duedate_1m_30,
        'duedate_1m_30','old_risk_bid_appmodel_v1_1_20250911',bin_app_v11,duedate_1m_30,
        'duedate_1m_30','aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score',bin_app_v12,duedate_1m_30
    ) AS label_name, model_name, model_bin, label_value
)
SELECT
    time_key,
    label_name,
    model_name,
    model_bin,
    COUNT(*) AS application_cnt,
    SUM(CASE WHEN label_value IN (0,1) THEN 1 END) AS performance_cnt,
    SUM(CASE WHEN label_value = 1 THEN 1 END) AS pos_cnt,
    SUM(CASE WHEN label_value = 0 THEN 1 END) AS neg_cnt
FROM long
WHERE model_bin IS NOT NULL
GROUP BY time_key, label_name, model_name, model_bin
;

-- =====================================================================
-- 老客模型分分布（按申请周 · 申请样本）
-- 各分箱的申请量占比，用于观察模型分人群分布漂移；与放款/表现无关
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_weekly_score_dist;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_weekly_score_dist AS
WITH base AS (
    SELECT
        CAST(cp.application_week AS STRING) AS time_key,

        CASE
            WHEN r.old_risk_bid_submodel_250909_txn IS NULL THEN NULL
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.052011 THEN 1
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.07337  THEN 2
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.099983 THEN 3
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.14444  THEN 4
            ELSE 5
        END AS bin_sub_v11,

        CASE
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 IS NULL THEN NULL
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.039873 THEN 1
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.057702 THEN 2
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.089551 THEN 3
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.149927 THEN 4
            ELSE 5
        END AS bin_mlt_v11,

        CASE
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 IS NULL THEN NULL
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.051164 THEN 1
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.071347 THEN 2
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.095801 THEN 3
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.138524 THEN 4
            ELSE 5
        END AS bin_app_v11,

        CASE
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score IS NULL THEN NULL
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.045117 THEN 1
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.063512 THEN 2
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.087708 THEN 3
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.130728 THEN 4
            ELSE 5
        END AS bin_sub_v12,

        CASE
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 IS NULL THEN NULL
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.035078 THEN 1
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.054394 THEN 2
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.081105 THEN 3
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.132466 THEN 4
            ELSE 5
        END AS bin_mlt_v12,

        CASE
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score IS NULL THEN NULL
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.051725 THEN 1
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.069226 THEN 2
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.090624 THEN 3
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.1212   THEN 4
            ELSE 5
        END AS bin_app_v12

    FROM model.tmp_eliam_risk_000004_strategy_run_log_v3 r
    LEFT JOIN ba.customer_profile_rawdata cp
        ON r.application_id = cp.application_id
    WHERE r.app_order_desc = 1
),

long AS (
    SELECT time_key, model_name, model_bin
    FROM base
    LATERAL VIEW STACK (
        6,
        'old_risk_bid_submodel_250909_txn', bin_sub_v11,
        'aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score', bin_sub_v12,
        'old_risk_bid_mltmodel_v1_1_20251021', bin_mlt_v11,
        'old_risk_bid_mltmodel_v1_2_20260325', bin_mlt_v12,
        'old_risk_bid_appmodel_v1_1_20250911', bin_app_v11,
        'aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score', bin_app_v12
    ) AS model_name, model_bin
)
SELECT
    time_key,
    model_name,
    model_bin,
    COUNT(*) AS application_cnt
FROM long
WHERE model_bin IS NOT NULL
  AND time_key IS NOT NULL
GROUP BY time_key, model_name, model_bin
;

-- =====================================================================
-- 老客分箱转化率（按申请周，仅老客策略 RISK_000004）
-- 通过率 = approved / completed；成交率 = deal / approved
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_weekly_bin_funnel;

CREATE TABLE model.tmp_eliam_risk_000004_strategy_weekly_bin_funnel AS
WITH base AS (
    SELECT
        CAST(cp.application_week AS STRING) AS time_key,

        CASE
            WHEN r.old_risk_bid_submodel_250909_txn IS NULL THEN NULL
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.052011 THEN 1
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.07337  THEN 2
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.099983 THEN 3
            WHEN r.old_risk_bid_submodel_250909_txn <= 0.14444  THEN 4
            ELSE 5
        END AS bin_sub_v11,

        CASE
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 IS NULL THEN NULL
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.039873 THEN 1
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.057702 THEN 2
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.089551 THEN 3
            WHEN r.old_risk_bid_mltmodel_v1_1_20251021 <= 0.149927 THEN 4
            ELSE 5
        END AS bin_mlt_v11,

        CASE
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 IS NULL THEN NULL
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.051164 THEN 1
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.071347 THEN 2
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.095801 THEN 3
            WHEN r.old_risk_bid_appmodel_v1_1_20250911 <= 0.138524 THEN 4
            ELSE 5
        END AS bin_app_v11,

        CASE
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score IS NULL THEN NULL
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.045117 THEN 1
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.063512 THEN 2
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.087708 THEN 3
            WHEN r.aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score <= 0.130728 THEN 4
            ELSE 5
        END AS bin_sub_v12,

        CASE
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 IS NULL THEN NULL
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.035078 THEN 1
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.054394 THEN 2
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.081105 THEN 3
            WHEN r.old_risk_bid_mltmodel_v1_2_20260325 <= 0.132466 THEN 4
            ELSE 5
        END AS bin_mlt_v12,

        CASE
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score IS NULL THEN NULL
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.051725 THEN 1
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.069226 THEN 2
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.090624 THEN 3
            WHEN r.aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score <= 0.1212   THEN 4
            ELSE 5
        END AS bin_app_v12,

        CASE
            WHEN cp.application_status IS NULL
              OR cp.application_status IN ('0.Incomplete', '1.In Progress')
            THEN 0 ELSE 1
        END AS completed_flag,

        CASE
            WHEN LEFT(cp.application_status, 1) IN ('3', '4') THEN 1 ELSE 0
        END AS approved_flag,

        CASE
            WHEN LEFT(cp.application_status, 1) IN ('3', '4')
             AND cp.assessment_status LIKE '%Auto Approved%'
            THEN 1 ELSE 0
        END AS auto_approved_flag,

        CASE
            WHEN LEFT(cp.application_status, 1) IN ('3', '4')
             AND cp.assessment_status LIKE '%Manual Approved%'
            THEN 1 ELSE 0
        END AS manual_approved_flag,

        CASE
            WHEN cp.status IN ('Active_Account', 'Closed', 'Blocked') THEN 1 ELSE 0
        END AS deal_flag

    FROM model.tmp_eliam_risk_000004_strategy_run_log_v3 r
    LEFT JOIN ba.customer_profile_rawdata cp
        ON r.application_id = cp.application_id
    WHERE r.app_order_desc = 1
),

long AS (
    SELECT
        time_key, model_name, model_bin,
        completed_flag, approved_flag, auto_approved_flag, manual_approved_flag, deal_flag
    FROM base
    LATERAL VIEW STACK (
        6,
        'old_risk_bid_submodel_250909_txn', bin_sub_v11,
        'aus_old_risk_bid_submodel_v20260323_v1_2_txn_lgb_score', bin_sub_v12,
        'old_risk_bid_mltmodel_v1_1_20251021', bin_mlt_v11,
        'old_risk_bid_mltmodel_v1_2_20260325', bin_mlt_v12,
        'old_risk_bid_appmodel_v1_1_20250911', bin_app_v11,
        'aus_old_risk_apply_appmodel_v20260318_v1_2_lgb_score', bin_app_v12
    ) AS model_name, model_bin
)
SELECT
    time_key,
    model_name,
    model_bin,
    COUNT(*) AS application_cnt,
    SUM(completed_flag) AS completed_cnt,
    SUM(approved_flag) AS approved_cnt,
    SUM(auto_approved_flag) AS auto_approved_cnt,
    SUM(manual_approved_flag) AS manual_approved_cnt,
    SUM(deal_flag) AS deal_cnt
FROM long
WHERE model_bin IS NOT NULL
  AND time_key IS NOT NULL
GROUP BY time_key, model_name, model_bin
;
