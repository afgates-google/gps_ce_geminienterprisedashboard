-- =============================================================================
-- Tier 3: Analytics & Presentation Marts
-- File: sql/04_tier3_adoption_marts.sql
--
-- Purpose: Presentation-layer views designed for Looker Studio and Looker Enterprise.
--          Enforces architectural integrity by strictly querying Tier 1
--          (vw_canonical_users) and Tier 2 (vw_events_flattened, vw_feedback_detailed).
--
-- Views Created:
--   1. vw_ds_executive_adoption: Correlates canonical directory with activity.
--   2. vw_ds_feedback_metrics: Slices feedback reasons for pie and donut charts.
--   3. vw_ds_feedback_details: Pre-flattens query context into multiline strings.
--
-- Target Dataset: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo`
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Mart 1: Executive Adoption & Regional Breakdown (vw_ds_executive_adoption)
-- Powers: Page 1 Executive View (KPI cards, Regional/BU Stacked Bars, Pivot Grid)
-- Architecture: LEFT JOINs Tier 1 (vw_canonical_users) with Tier 2 (vw_events_flattened)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_ds_executive_adoption` AS
WITH UserActivity AS (
  SELECT
    userIamPrincipal AS user_principal_name,
    MIN(timestamp) AS first_login,
    MAX(timestamp) AS last_activity,
    COUNT(*) AS total_events,
    COUNTIF(is_search_or_prompt = 1) AS total_searches
  FROM
    `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_events_flattened`
  GROUP BY 1
)
SELECT
  -- Directory Hierarchy from Tier 1 Canonical Identity
  u.user_principal_name AS user_email,
  u.display_name AS user_name,
  u.region,
  u.business_unit,
  u.supervisor_name,
  
  -- Activity Metrics
  ua.first_login,
  ua.last_activity,
  COALESCE(ua.total_searches, 0) AS total_searches,
  COALESCE(ua.total_events, 0) AS total_events,
  
  -- Pre-baked categorical label for Stacked Bar charts
  CASE 
    WHEN ua.user_principal_name IS NOT NULL THEN 'Logged In At Least Once'
    ELSE 'Never Logged In'
  END AS login_status,
  
  -- Numerical Additive Flags for Single-Value Scorecard Cards
  IF(ua.user_principal_name IS NOT NULL, 1, 0) AS is_active,
  IF(ua.user_principal_name IS NULL, 1, 0) AS is_never_logged_in,
  1 AS total_licenses_procured

FROM
  -- Strictly queries Tier 1 canonical view (preserving the identity abstraction)
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_canonical_users` AS u
LEFT JOIN
  UserActivity AS ua
ON
  u.user_principal_name = ua.user_principal_name;

-- -----------------------------------------------------------------------------
-- Mart 2: Feedback Reasons & Sentiment (vw_ds_feedback_metrics)
-- Powers: Page 2 (Dislike Reasons Pie Chart, Sentiment Donut, Reason Leaderboards)
-- Architecture: Direct lightweight projection over Tier 2 feedback events
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_ds_feedback_metrics` AS
SELECT
  feedback_time AS feedback_timestamp,
  DATE(feedback_time) AS feedback_date,
  userIamPrincipal AS user_principal_name,
  feedback_type,
  COALESCE(feedback_comment, '[No Comment Provided]') AS feedback_comment,
  feedback_reason,
  session_id,
  feedback_attribution_token AS assist_token
FROM
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_feedback_detailed`;

-- -----------------------------------------------------------------------------
-- Mart 3: Feedback Context Flattener (vw_ds_feedback_details)
-- Powers: Page 2 (Master User & Feedback Details Table with stacked multiline query cells)
-- Architecture: Converts Tier 2 context array into a clean newline-separated string
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_ds_feedback_details` AS
SELECT
  FORMAT_TIMESTAMP('%m/%d/%y', feedback_time) AS feedback_date_formatted,
  feedback_time,
  feedback_type,
  userIamPrincipal AS user_principal_name,
  COALESCE(feedback_comment, 'Null') AS feedback_comment,
  feedback_reason,
  -- Flatten nested STRUCT array into a multiline string for standard table rendering
  COALESCE(
    (
      SELECT STRING_AGG(ctx.userQuery, '\n' ORDER BY ctx.event_timestamp DESC)
      FROM UNNEST(related_events_context) AS ctx
      WHERE ctx.userQuery IS NOT NULL
    ),
    '[No queries in 10m window]'
  ) AS user_query_context
FROM
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_feedback_detailed`;
