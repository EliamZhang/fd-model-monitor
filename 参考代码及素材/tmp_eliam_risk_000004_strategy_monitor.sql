DROP TABLE IF EXISTS model.tmp_eliam_risk_000004_strategy_monitor;

-- 2) Create monitoring table
CREATE TABLE model.tmp_eliam_risk_000004_strategy_monitor AS

SELECT
    sr.*,

    ----------------------------------------------------------------------
    -- ===== 新增 AI Base Model 分箱字段 =====
    ----------------------------------------------------------------------
    CASE
        WHEN cp.base_probability IS NULL THEN NULL
        WHEN 1 - cp.base_probability < 0.111014 THEN 20
        WHEN 1 - cp.base_probability < 0.175004 THEN 40
        WHEN 1 - cp.base_probability < 0.270748 THEN 60
        WHEN 1 - cp.base_probability < 0.426544 THEN 80
        ELSE 100
    END AS ai_base_bin,

    ----------------------------------------------------------------------
    -- ===== 原 3 个模型分箱字段 =====
    ----------------------------------------------------------------------
    CASE
        WHEN sr.old_risk_bid_submodel_250909_txn <= 0.052011 THEN '1.[0, 0.052011]'
        WHEN sr.old_risk_bid_submodel_250909_txn <= 0.07337 THEN '2.(0.052011, 0.07337]'
        WHEN sr.old_risk_bid_submodel_250909_txn <= 0.099983 THEN '3.(0.07337, 0.099983]'
        WHEN sr.old_risk_bid_submodel_250909_txn <= 0.14444 THEN '4.(0.099983, 0.14444]'
        ELSE '5.(0.14444, 1]'
    END AS old_risk_bid_submodel_250909_txn_bin,

    CASE
        WHEN sr.old_risk_bid_mltmodel_v1_1_20251021 <= 0.039873 THEN '1.[0, 0.039873]'
        WHEN sr.old_risk_bid_mltmodel_v1_1_20251021 <= 0.057702 THEN '2.(0.039873, 0.057702]'
        WHEN sr.old_risk_bid_mltmodel_v1_1_20251021 <= 0.089551 THEN '3.(0.057702, 0.089551]'
        WHEN sr.old_risk_bid_mltmodel_v1_1_20251021 <= 0.149927 THEN '4.(0.089551, 0.149927]'
        ELSE '5.(0.149927, 1]'
    END AS old_risk_bid_mltmodel_v1_1_20251021_bin,

    CASE
        WHEN sr.old_risk_bid_appmodel_v1_1_20250911 <= 0.051164 THEN '1.[0, 0.051164]'
        WHEN sr.old_risk_bid_appmodel_v1_1_20250911 <= 0.071347 THEN '2.(0.051164, 0.071347]'
        WHEN sr.old_risk_bid_appmodel_v1_1_20250911 <= 0.095801 THEN '3.(0.071347, 0.095801]'
        WHEN sr.old_risk_bid_appmodel_v1_1_20250911 <= 0.138524 THEN '4.(0.095801, 0.138524]'
        ELSE '5.(0.138524, 1]'
    END AS old_risk_bid_appmodel_v1_1_20250911_bin,

    ----------------------------------------------------------------------
    -- ===== Application 状态 Flag =====
    ----------------------------------------------------------------------
    CASE
        WHEN cp.application_status IS NULL THEN NULL
        WHEN cp.application_status NOT IN ('0.Incomplete', '1.In Progress') THEN 1
        ELSE 0
    END AS completed_application_flag,

    CASE
        WHEN cp.application_status IS NULL THEN NULL
        WHEN LEFT(cp.application_status, 1) IN ('3', '4') THEN 1
        ELSE 0
    END AS approved_application_flag,

    CASE
        WHEN cp.application_status IS NULL OR cp.assessment_status IS NULL THEN NULL
        WHEN LEFT(cp.application_status, 1) IN ('3', '4')
             AND cp.assessment_status LIKE '%Auto Approved%' THEN 1
        ELSE 0
    END AS auto_approved_application_flag,

    CASE
        WHEN cp.application_status IS NULL OR cp.assessment_status IS NULL THEN NULL
        WHEN LEFT(cp.application_status, 1) IN ('3', '4')
             AND cp.assessment_status LIKE '%Manual Approved%' THEN 1
        ELSE 0
    END AS manual_approved_application_flag,

    CASE
        WHEN cp.application_status IS NULL THEN NULL
        WHEN cp.application_status = '2.3.Risk Declined' THEN 1
        ELSE 0
    END AS declined_application_flag,

    CASE
        WHEN cp.application_status IS NULL OR cp.assessment_status IS NULL THEN NULL
        WHEN cp.application_status = '2.3.Risk Declined'
             AND cp.assessment_status LIKE '%Auto Declined%' THEN 1
        ELSE 0
    END AS auto_declined_application_flag,

    CASE
        WHEN cp.application_status IS NULL OR cp.assessment_status IS NULL THEN NULL
        WHEN cp.application_status = '2.3.Risk Declined'
             AND cp.assessment_status LIKE '%Manual Declined%' THEN 1
        ELSE 0
    END AS manual_declined_application_flag,

    CASE
        WHEN cp.application_status IS NULL THEN NULL
        WHEN cp.application_status = '2.1.Submitted Withdrawn' THEN 1
        ELSE 0
    END AS withdrawn_application_flag,

    CASE
        WHEN cp.application_status IS NULL OR cp.assessment_status IS NULL THEN NULL
        WHEN cp.application_status = '2.1.Submitted Withdrawn'
             AND cp.assessment_status LIKE '%Auto Withdrawn%' THEN 1
        ELSE 0
    END AS auto_withdrawn_application_flag,

    CASE
        WHEN cp.application_status IS NULL OR cp.assessment_status IS NULL THEN NULL
        WHEN cp.application_status = '2.1.Submitted Withdrawn'
             AND cp.assessment_status LIKE '%Manual Withdrawn%' THEN 1
        ELSE 0
    END AS manual_withdrawn_application_flag,

    CASE
        WHEN cp.application_status IS NULL THEN NULL
        WHEN cp.application_status = '4.Funded' THEN 1
        ELSE 0
    END AS funded_application_flag,

    ----------------------------------------------------------------------
    -- ===== 新增：FPD7 首逾标记 =====
    -- 本质等价于首期 7+ DPD 标签
    ----------------------------------------------------------------------
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

----------------------------------------------------------------------
    -- ===== 原有字段（完全保留）=====
    ----------------------------------------------------------------------
    cp.application_time,
    cp.application_date,
    cp.application_week,
    cp.application_month,
    cp.dispersal_date,
    cp.dispersal_week,
    cp.dispersal_month,
    cp.payout_date,
    cp.payout_amount,
    cp.requested_loan_amount,
    cp.requested_loan_tag,
    cp.total_amount,
    cp.loan_tag,
    cp.init_fee,
    cp.total_loan_amount,
    cp.first_payment_date,
    cp.last_payment_date,
    cp.repayment_frequency,
    cp.repayments,
    cp.repayment_amount,
    cp.original_term_length,
    cp.original_term_avg,
    cp.actual_term_length,
    cp.actual_term_avg,
    cp.reschedule_tag,
    cp.term_change_tag,
    cp.repayment_days,
    cp.user_tag,
    cp.application_tag,
    cp.age,
    cp.state,
    cp.suburb,
    cp.zip_code,
    cp.dependents,
    cp.family_type,
    cp.default_income,
    cp.default_expenses,
    cp.default_gross_surplus,
    cp.total_income,
    cp.total_expenses,
    cp.gross_surplus,
    cp.net_surplus,
    cp.lti,
    cp.nsti,
    cp.pti,
    cp.status,
    cp.application_status,
    cp.assessment_status,
    cp.completed_step,
    cp.completed_step_time,
    cp.last_step,
    cp.status_transition,
    cp.risk_approved_agent,
    cp.risk_approved_time,
    cp.risk_declined_agent,
    cp.risk_declined_time,
    cp.conversion_check_agent,
    cp.conversion_check_time,
    cp.conversion_declined_agent,
    cp.conversion_declined_time,
    cp.converted_agent,
    cp.converted_time,
    cp.withdrawn_agent,
    cp.withdrawn_time,
    cp.last_status,
    cp.last_status_agent,
    cp.last_status_time,
    cp.hardship_status,
    cp.scheduled_cleared_date,
    cp.approval_rules_decision,
    cp.combined_ml_models_decision,
    cp.is_auto_approved,
    cp.is_bad_loan,
    cp.approval_rules,
    cp.combined_reasons,
    cp.first_payment_scheduled_date,
    cp.first_payment_days_past_due_ever,
    cp.first_payment_scheduled_amount,
    cp.first_payment_scheduled_principal,
    cp.traffic_source,
    cp.app_platform,
    cp.app_start_type,
    cp.app_side_completed,
    cp.app_side_complete_type,
    cp.attributed_category,
    cp.attributed_utm,
    cp.attributed_medium,
    cp.attributed_campaign,

    lv.duedate_1m_5, lv.duedate_2m_5, lv.duedate_3m_5, lv.duedate_4m_5, lv.duedate_5m_5,
    lv.duedate_6m_5, lv.duedate_7m_5, lv.duedate_8m_5, lv.duedate_9m_5, lv.duedate_10m_5,
    lv.duedate_11m_5, lv.duedate_12m_5,

    lv.duedate_1m_30, lv.duedate_2m_30, lv.duedate_3m_30, lv.duedate_4m_30, lv.duedate_5m_30,
    lv.duedate_6m_30, lv.duedate_7m_30, lv.duedate_8m_30, lv.duedate_9m_30, lv.duedate_10m_30,
    lv.duedate_11m_30, lv.duedate_12m_30,

    lv.duedate_1m_60, lv.duedate_2m_60, lv.duedate_3m_60, lv.duedate_4m_60, lv.duedate_5m_60,
    lv.duedate_6m_60, lv.duedate_7m_60, lv.duedate_8m_60, lv.duedate_9m_60, lv.duedate_10m_60,
    lv.duedate_11m_60, lv.duedate_12m_60,

    sv.principal,
    sv.closed_flag,
    sv.estimate_principal_remaining_mob0, sv.dpd_days_mob0,
    sv.estimate_principal_remaining_mob1, sv.dpd_days_mob1,
    sv.estimate_principal_remaining_mob2, sv.dpd_days_mob2,
    sv.estimate_principal_remaining_mob3, sv.dpd_days_mob3,
    sv.estimate_principal_remaining_mob4, sv.dpd_days_mob4,
    sv.estimate_principal_remaining_mob5, sv.dpd_days_mob5,
    sv.estimate_principal_remaining_mob6, sv.dpd_days_mob6,
    sv.estimate_principal_remaining_mob7, sv.dpd_days_mob7,
    sv.estimate_principal_remaining_mob8, sv.dpd_days_mob8,
    sv.estimate_principal_remaining_mob9, sv.dpd_days_mob9,
    sv.estimate_principal_remaining_mob10, sv.dpd_days_mob10,
    sv.estimate_principal_remaining_mob11, sv.dpd_days_mob11,
    sv.estimate_principal_remaining_mob12, sv.dpd_days_mob12

FROM model.tmp_eliam_risk_000004_strategy_run_log sr
LEFT JOIN ba.customer_profile_rawdata cp
    ON sr.application_id = cp.application_id
LEFT JOIN model.tmp_eliam_listing_vintage lv
    ON sr.application_id = lv.application_id
LEFT JOIN model.tmp_eliam_aus_segment_vintage sv
    ON sr.application_id = sv.application_id;