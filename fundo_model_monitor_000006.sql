-- =====================================================================
-- 新客 3rdmodel 周度监控（RISK_000006）
-- 数据源：model.tmp_eliam_risk_000006_vintage_monitor（1 行/application_id）
-- 新老客口径：ba.customer_profile_rawdata.user_tag = 'New'
--   * 如线上枚举不是 'New'，只需统一修改下面 5 处 user_tag 条件
--   * 上线前可先确认：SELECT user_tag, COUNT(*) FROM ba.customer_profile_rawdata GROUP BY user_tag;
-- 周口径：
--   AUC / 分箱坏账率 = 放款周 dispersal_week，未放款归入 UNFUNDED
--   漏斗 / 分数分布 / 分箱转化 = 申请周 application_week
-- 标签：FPD7 + 首期 5+/30+、2 期 30+、3 期 30+
-- 分数：aus_new_risk_bid_3rdmodel_v1_0_20251201
--   * 源字段可能是字符串，且 -1 / '-1.0 表示无效分，统一清洗为 NULL
-- 分箱：直接使用源表 _bin 字段（等频五档 20/40/60/80/100 -> 1-5）
-- =====================================================================


-- =====================================================================
-- 1) 周度 AUC
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000006_weekly_auc;

CREATE TABLE model.tmp_eliam_risk_000006_weekly_auc AS
WITH base AS (
    SELECT
        v.application_id,
        COALESCE(CAST(v.dispersal_week AS STRING), 'UNFUNDED') AS time_key,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            ELSE CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE)
        END AS model_score,

        CAST(v.fpd7_flag AS INT) AS fpd7_flag,
        CAST(v.duedate_1m_5 AS INT) AS duedate_1m_5,
        CAST(v.duedate_1m_30 AS INT) AS duedate_1m_30,
        CAST(v.duedate_2m_30 AS INT) AS duedate_2m_30,
        CAST(v.duedate_3m_30 AS INT) AS duedate_3m_30
    FROM model.tmp_eliam_risk_000006_vintage_monitor v
    LEFT JOIN ba.customer_profile_rawdata cp
        ON v.application_id = cp.application_id
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

        'fpd7_flag','aus_new_risk_bid_3rdmodel_v1_0_20251201',model_score,fpd7_flag,
        'duedate_1m_5','aus_new_risk_bid_3rdmodel_v1_0_20251201',model_score,duedate_1m_5,
        'duedate_1m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',model_score,duedate_1m_30,
        'duedate_2m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',model_score,duedate_2m_30,
        'duedate_3m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',model_score,duedate_3m_30
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

    FROM model.tmp_eliam_risk_000006_vintage_monitor v
    LEFT JOIN ba.customer_profile_rawdata cp
        ON v.application_id = cp.application_id
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
-- 箱 1-5 直接映射源表 _bin 的等频五档（20/40/60/80/100）
-- 标签：FPD7、首期 30+
-- =====================================================================

DROP TABLE IF EXISTS model.tmp_eliam_risk_000006_weekly_bin;

CREATE TABLE model.tmp_eliam_risk_000006_weekly_bin AS
WITH base AS (
    SELECT
        COALESCE(CAST(v.dispersal_week AS STRING), 'UNFUNDED') AS time_key,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 20  THEN 1
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 40  THEN 2
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 60  THEN 3
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 80  THEN 4
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 100 THEN 5
            ELSE NULL
        END AS model_bin,

        CAST(v.fpd7_flag AS INT) AS fpd7_flag,
        CAST(v.duedate_1m_30 AS INT) AS duedate_1m_30
    FROM model.tmp_eliam_risk_000006_vintage_monitor v
    LEFT JOIN ba.customer_profile_rawdata cp
        ON v.application_id = cp.application_id
    WHERE cp.user_tag = 'New'
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
        2,

        'fpd7_flag','aus_new_risk_bid_3rdmodel_v1_0_20251201',model_bin,fpd7_flag,
        'duedate_1m_30','aus_new_risk_bid_3rdmodel_v1_0_20251201',model_bin,duedate_1m_30
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
WITH base AS (
    SELECT
        CAST(v.application_week AS STRING) AS time_key,
        'aus_new_risk_bid_3rdmodel_v1_0_20251201' AS model_name,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 20  THEN 1
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 40  THEN 2
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 60  THEN 3
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 80  THEN 4
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 100 THEN 5
            ELSE NULL
        END AS model_bin
    FROM model.tmp_eliam_risk_000006_vintage_monitor v
    LEFT JOIN ba.customer_profile_rawdata cp
        ON v.application_id = cp.application_id
    WHERE cp.user_tag = 'New'
)
SELECT
    time_key,
    model_name,
    model_bin,
    COUNT(*) AS application_cnt
FROM base
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
WITH base AS (
    SELECT
        CAST(cp.application_week AS STRING) AS time_key,
        'aus_new_risk_bid_3rdmodel_v1_0_20251201' AS model_name,

        CASE
            WHEN v.aus_new_risk_bid_3rdmodel_v1_0_20251201 IS NULL THEN NULL
            WHEN REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') = '' THEN NULL
            WHEN CAST(REGEXP_REPLACE(CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201 AS STRING), '[^-0-9eE+.]', '') AS DOUBLE) < 0 THEN NULL
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 20  THEN 1
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 40  THEN 2
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 60  THEN 3
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 80  THEN 4
            WHEN CAST(v.aus_new_risk_bid_3rdmodel_v1_0_20251201_bin AS INT) = 100 THEN 5
            ELSE NULL
        END AS model_bin,

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
    FROM model.tmp_eliam_risk_000006_vintage_monitor v
    LEFT JOIN ba.customer_profile_rawdata cp
        ON v.application_id = cp.application_id
    WHERE cp.user_tag = 'New'
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
FROM base
WHERE model_bin IS NOT NULL
  AND time_key IS NOT NULL
GROUP BY time_key, model_name, model_bin
;
