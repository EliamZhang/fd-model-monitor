-- =====================================================================
-- 老客模型 by 周 AUC 监控（1.1 vs 1.2）
-- 驱动表：ba.customer_profile_rawdata（1 行/申请，user_tag = 'Existing'）
-- 分数源：model.tmp_eliam_risk_000004_strategy_run_log_v20261102
--   * 每个 application 取最新一次 run（app_order_desc = 1），LEFT JOIN 补分数
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
        cp.application_id,
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
    FROM ba.customer_profile_rawdata cp
    LEFT JOIN model.tmp_eliam_risk_000004_strategy_run_log_v20261102 r
        ON cp.application_id = r.application_id
       AND r.app_order_desc = 1
    LEFT JOIN model.tmp_eliam_listing_vintage lv
        ON cp.application_id = lv.application_id
    WHERE cp.user_tag = 'Existing'
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

    FROM ba.customer_profile_rawdata cp
    WHERE cp.user_tag = 'Existing'
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
    FROM ba.customer_profile_rawdata cp
    LEFT JOIN model.tmp_eliam_risk_000004_strategy_run_log_v20261102 r
        ON cp.application_id = r.application_id
       AND r.app_order_desc = 1
    LEFT JOIN model.tmp_eliam_listing_vintage lv
        ON cp.application_id = lv.application_id
    WHERE cp.user_tag = 'Existing'
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

    FROM ba.customer_profile_rawdata cp
    LEFT JOIN model.tmp_eliam_risk_000004_strategy_run_log_v20261102 r
        ON cp.application_id = r.application_id
       AND r.app_order_desc = 1
    WHERE cp.user_tag = 'Existing'
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

    FROM ba.customer_profile_rawdata cp
    LEFT JOIN model.tmp_eliam_risk_000004_strategy_run_log_v20261102 r
        ON cp.application_id = r.application_id
       AND r.app_order_desc = 1
    WHERE cp.user_tag = 'Existing'
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


-- =====================================================================
-- 新客 3rdmodel 周度监控（RISK_000006）
-- 驱动表：ba.customer_profile_rawdata（1 行/申请，user_tag = 'New'）
-- 分数/表现源：model.tmp_eliam_risk_000006_vintage_monitor（源表存在一行多记录，见下方去重口径）
--   * 分数与标签通过 application_id LEFT JOIN 补入
--   * 如线上枚举不是 'New'，只需统一修改下面 5 处 user_tag 条件
--   * 上线前可先确认：SELECT user_tag, COUNT(*) FROM ba.customer_profile_rawdata GROUP BY user_tag;
-- 周口径（周字段优先取驱动表 cp，缺失时回退到分数源）：
--   AUC / 分箱坏账率 = 放款周 dispersal_week，未放款归入 UNFUNDED
--   漏斗 / 分数分布 / 分箱转化 = 申请周 application_week
-- 标签：FPD7 + 首期 5+/30+、2 期 30+、3 期 30+
-- 分数：aus_new_risk_bid_3rdmodel_v1_0_20251201
--   * 源字段可能是字符串，且 -1 / '-1.0 表示无效分，统一清洗为 NULL
-- 分箱：按模型分固定阈值划分
--   <=0.062086 -> 1；<=0.091284 -> 2；<=0.128392 -> 3；<=0.188973 -> 4；>0.188973 -> 5
-- 去重：源表并非严格 1 行/申请（2026 年放款申请约 1.3 行/申请），
--       统一按 application_id 取 inserttime 最新一行（与老客 000004 口径一致）
-- =====================================================================


-- =====================================================================
-- 1) 周度 AUC
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000006_weekly_auc;

CREATE TABLE model.tmp_eliam_risk_000006_weekly_auc AS
WITH v AS (
    SELECT
        application_id,
        application_week,
        dispersal_week,
        aus_new_risk_bid_3rdmodel_v1_0_20251201,
        fpd7_flag,
        duedate_1m_5,
        duedate_1m_30,
        duedate_2m_30,
        duedate_3m_30
    FROM (
        SELECT
            application_id,
            application_week,
            dispersal_week,
            aus_new_risk_bid_3rdmodel_v1_0_20251201,
            fpd7_flag,
            duedate_1m_5,
            duedate_1m_30,
            duedate_2m_30,
            duedate_3m_30,
            ROW_NUMBER() OVER (
                PARTITION BY application_id
                ORDER BY inserttime DESC, sample_datetime DESC
            ) AS rn
        FROM model.tmp_eliam_risk_000006_vintage_monitor
        WHERE application_id IS NOT NULL
    ) dedup
    WHERE rn = 1
),
base AS (
    SELECT
        cp.application_id,
        COALESCE(CAST(cp.dispersal_week AS STRING), CAST(v.dispersal_week AS STRING), 'UNFUNDED') AS time_key,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            ELSE CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE)
        END AS score_value,

        CAST(v.fpd7_flag AS INT) AS fpd7_flag,
        CAST(v.duedate_1m_5 AS INT) AS duedate_1m_5,
        CAST(v.duedate_1m_30 AS INT) AS duedate_1m_30,
        CAST(v.duedate_2m_30 AS INT) AS duedate_2m_30,
        CAST(v.duedate_3m_30 AS INT) AS duedate_3m_30
    FROM ba.customer_profile_rawdata cp
    LEFT JOIN v
        ON cp.application_id = v.application_id
    WHERE cp.user_tag = 'New'
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
        5,

        'fpd7_flag','aus_new_risk_bid_3rdmodel_v1_0_20251201',score_value,fpd7_flag,
        'duedate_1m_5','aus_new_risk_bid_3rdmodel_v1_0_20251201',score_value,duedate_1m_5,
        'duedate_1m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',score_value,duedate_1m_30,
        'duedate_2m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',score_value,duedate_2m_30,
        'duedate_3m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',score_value,duedate_3m_30
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
-- 2) 转化漏斗（按申请周，仅 user_tag = New）
-- 完成率 = 完成 / 申请；通过率 = 通过 / 完成；成交率 = 成交 / 通过
-- 成交口径：status ∈ Active_Account / Closed / Blocked
-- 自动/人工通过：assessment_status 含 Auto Approved / Manual Approved
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000006_weekly_funnel;

CREATE TABLE model.tmp_eliam_risk_000006_weekly_funnel AS
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

    FROM ba.customer_profile_rawdata cp
    WHERE cp.user_tag = 'New'
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
-- 3) 分箱坏账率（按放款周）
-- 箱 1-5 按模型分固定阈值划分（0.062086 / 0.091284 / 0.128392 / 0.188973）
-- 标签：FPD7、首期 30+
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000006_weekly_bin;

CREATE TABLE model.tmp_eliam_risk_000006_weekly_bin AS
WITH v AS (
    SELECT
        application_id,
        application_week,
        dispersal_week,
        aus_new_risk_bid_3rdmodel_v1_0_20251201,
        fpd7_flag,
        duedate_1m_5,
        duedate_1m_30,
        duedate_2m_30,
        duedate_3m_30
    FROM (
        SELECT
            application_id,
            application_week,
            dispersal_week,
            aus_new_risk_bid_3rdmodel_v1_0_20251201,
            fpd7_flag,
            duedate_1m_5,
            duedate_1m_30,
            duedate_2m_30,
            duedate_3m_30,
            ROW_NUMBER() OVER (
                PARTITION BY application_id
                ORDER BY inserttime DESC, sample_datetime DESC
            ) AS rn
        FROM model.tmp_eliam_risk_000006_vintage_monitor
        WHERE application_id IS NOT NULL
    ) dedup
    WHERE rn = 1
),
base AS (
    SELECT
        COALESCE(CAST(cp.dispersal_week AS STRING), CAST(v.dispersal_week AS STRING), 'UNFUNDED') AS time_key,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            ELSE CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE)
        END AS score_value,

        CAST(v.fpd7_flag AS INT) AS fpd7_flag,
        CAST(v.duedate_1m_30 AS INT) AS duedate_1m_30
    FROM ba.customer_profile_rawdata cp
    LEFT JOIN v
        ON cp.application_id = v.application_id
    WHERE cp.user_tag = 'New'
),

scored AS (
    SELECT
        time_key,
        CASE
            WHEN score_value IS NULL THEN NULL
            WHEN score_value <= 0.062086 THEN 1
            WHEN score_value <= 0.091284 THEN 2
            WHEN score_value <= 0.128392 THEN 3
            WHEN score_value <= 0.188973 THEN 4
            ELSE 5
        END AS score_bin,
        fpd7_flag,
        duedate_1m_30
    FROM base
),

long AS (
    SELECT
        time_key,
        label_name,
        model_name,
        model_bin,
        label_value
    FROM scored
    LATERAL VIEW STACK (
        2,

        'fpd7_flag','aus_new_risk_bid_3rdmodel_v1_0_20251201',score_bin,fpd7_flag,
        'duedate_1m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',score_bin,duedate_1m_30
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
-- 4) 模型分分布（按申请周 · 申请样本）
-- 各分箱的申请量占比，用于观察模型分人群分布漂移；与放款/表现无关
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000006_weekly_score_dist;

CREATE TABLE model.tmp_eliam_risk_000006_weekly_score_dist AS
WITH v AS (
    SELECT
        application_id,
        application_week,
        dispersal_week,
        aus_new_risk_bid_3rdmodel_v1_0_20251201,
        fpd7_flag,
        duedate_1m_5,
        duedate_1m_30,
        duedate_2m_30,
        duedate_3m_30
    FROM (
        SELECT
            application_id,
            application_week,
            dispersal_week,
            aus_new_risk_bid_3rdmodel_v1_0_20251201,
            fpd7_flag,
            duedate_1m_5,
            duedate_1m_30,
            duedate_2m_30,
            duedate_3m_30,
            ROW_NUMBER() OVER (
                PARTITION BY application_id
                ORDER BY inserttime DESC, sample_datetime DESC
            ) AS rn
        FROM model.tmp_eliam_risk_000006_vintage_monitor
        WHERE application_id IS NOT NULL
    ) dedup
    WHERE rn = 1
),
base AS (
    SELECT
        COALESCE(CAST(cp.application_week AS STRING), CAST(v.application_week AS STRING)) AS time_key,
        'aus_new_risk_bid_3rdmodel_v1_0_20251201' AS model_name,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            ELSE CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE)
        END AS score_value
    FROM ba.customer_profile_rawdata cp
    LEFT JOIN v
        ON cp.application_id = v.application_id
    WHERE cp.user_tag = 'New'
),

binned AS (
    SELECT
        time_key,
        model_name,
        CASE
            WHEN score_value IS NULL THEN NULL
            WHEN score_value <= 0.062086 THEN 1
            WHEN score_value <= 0.091284 THEN 2
            WHEN score_value <= 0.128392 THEN 3
            WHEN score_value <= 0.188973 THEN 4
            ELSE 5
        END AS model_bin
    FROM base
)
SELECT
    time_key,
    model_name,
    model_bin,
    COUNT(*) AS application_cnt
FROM binned
WHERE model_bin IS NOT NULL
  AND time_key IS NOT NULL
GROUP BY time_key, model_name, model_bin
;


-- =====================================================================
-- 5) 分箱转化率（按申请周）
-- 通过率 = approved / completed；成交率 = deal / approved
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000006_weekly_bin_funnel;

CREATE TABLE model.tmp_eliam_risk_000006_weekly_bin_funnel AS
WITH v AS (
    SELECT
        application_id,
        application_week,
        dispersal_week,
        aus_new_risk_bid_3rdmodel_v1_0_20251201,
        fpd7_flag,
        duedate_1m_5,
        duedate_1m_30,
        duedate_2m_30,
        duedate_3m_30
    FROM (
        SELECT
            application_id,
            application_week,
            dispersal_week,
            aus_new_risk_bid_3rdmodel_v1_0_20251201,
            fpd7_flag,
            duedate_1m_5,
            duedate_1m_30,
            duedate_2m_30,
            duedate_3m_30,
            ROW_NUMBER() OVER (
                PARTITION BY application_id
                ORDER BY inserttime DESC, sample_datetime DESC
            ) AS rn
        FROM model.tmp_eliam_risk_000006_vintage_monitor
        WHERE application_id IS NOT NULL
    ) dedup
    WHERE rn = 1
),
base AS (
    SELECT
        COALESCE(CAST(cp.application_week AS STRING), CAST(v.application_week AS STRING)) AS time_key,
        'aus_new_risk_bid_3rdmodel_v1_0_20251201' AS model_name,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            ELSE CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE)
        END AS score_value,

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
    FROM ba.customer_profile_rawdata cp
    LEFT JOIN v
        ON cp.application_id = v.application_id
    WHERE cp.user_tag = 'New'
),

binned AS (
    SELECT
        time_key,
        model_name,
        CASE
            WHEN score_value IS NULL THEN NULL
            WHEN score_value <= 0.062086 THEN 1
            WHEN score_value <= 0.091284 THEN 2
            WHEN score_value <= 0.128392 THEN 3
            WHEN score_value <= 0.188973 THEN 4
            ELSE 5
        END AS model_bin,
        completed_flag,
        approved_flag,
        auto_approved_flag,
        manual_approved_flag,
        deal_flag
    FROM base
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
FROM binned
WHERE model_bin IS NOT NULL
  AND time_key IS NOT NULL
GROUP BY time_key, model_name, model_bin
;
