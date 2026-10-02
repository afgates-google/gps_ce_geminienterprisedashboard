-- =============================================================================
-- 03_views_looker_studio.sql
-- Purpose: Dedicated BigQuery views engineered specifically for Looker Studio
--          (Google Data Studio). Pre-flattens arrays, bakes in breakdown
--          dimensions, and converts complex structs into multiline strings.
--
-- Target Dataset: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo`
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View 1: Executive Adoption & Regional Breakdown
-- Powers: Page 1 Executive View (KPI cards, Stacked Regional/BU Bars, Pivot Grid)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_ds_executive_adoption` AS
WITH UserActivity AS (
  SELECT
    LOWER(TRIM(jsonPayload.useriamprincipal)) AS user_principal_name,
    MIN(timestamp) AS first_login,
    MAX(timestamp) AS last_activity,
    COUNT(*) AS total_events,
    COUNTIF(
      jsonPayload.logmetadata.methodname = 'Search' 
      OR jsonPayload.request.userevent.eventtype = 'search'
    ) AS total_searches
  FROM
    `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity`
  WHERE
    jsonPayload.useriamprincipal IS NOT NULL
    AND jsonPayload.useriamprincipal NOT LIKE '%gserviceaccount.com'
  GROUP BY 1
)
SELECT
  o.userPrincipalName AS user_email,
  o.displayName AS user_name,
  o.region,
  o.businessUnit AS business_unit,
  o.supervisorName AS supervisor_name,
  ua.first_login,
  ua.last_activity,
  COALESCE(ua.total_searches, 0) AS total_searches,
  COALESCE(ua.total_events, 0) AS total_events,
  
  -- Pre-baked categorical label for Stacked Bar charts
  CASE 
    WHEN ua.user_principal_name IS NOT NULL THEN 'Logged In At Least Once'
    ELSE 'Never Logged In'
  END AS login_status,
  
  -- Binary flags for single-value scorecards
  IF(ua.user_principal_name IS NOT NULL, 1, 0) AS is_active,
  IF(ua.user_principal_name IS NULL, 1, 0) AS is_never_logged_in,
  1 AS total_licenses_procured

FROM
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.okta_user_principals` AS o
LEFT JOIN
  UserActivity AS ua
ON
  LOWER(TRIM(o.userPrincipalName)) = ua.user_principal_name
WHERE
  o.accountStatus = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- View 2: Feedback Sentiment & Reason Metrics
-- Powers: Page 2 (Dislike Reasons Pie Chart, Sentiment Donut, Reason Leaderboards)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_ds_feedback_metrics` AS
SELECT
  t.timestamp AS feedback_timestamp,
  DATE(t.timestamp) AS feedback_date,
  LOWER(TRIM(t.jsonPayload.useriamprincipal)) AS user_principal_name,
  t.jsonPayload.request.userevent.feedback.feedbacktype AS feedback_type,
  COALESCE(t.jsonPayload.request.userevent.feedback.comment, '[No Comment Provided]') AS feedback_comment,
  reason AS feedback_reason,
  t.jsonPayload.request.userevent.feedback.conversationinfo.session AS session_id,
  t.jsonPayload.request.userevent.feedback.conversationinfo.assisttoken AS assist_token
FROM
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity` AS t
CROSS JOIN
  UNNEST(t.jsonPayload.request.userevent.feedback.reasons) AS reason
WHERE
  t.jsonPayload.request.userevent.eventtype = 'add-feedback';

-- -----------------------------------------------------------------------------
-- View 3: Feedback Details with Flattend Preceding Context
-- Powers: Page 2 (Master User & Feedback Details Table with stacked multiline query cells)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_ds_feedback_details` AS
WITH FeedbackEvents AS (
  SELECT
    t.timestamp AS feedback_time,
    LOWER(TRIM(t.jsonPayload.useriamprincipal)) AS user_principal_name,
    t.jsonPayload.request.userevent.feedback.feedbacktype AS feedback_type,
    COALESCE(t.jsonPayload.request.userevent.feedback.comment, 'Null') AS feedback_comment,
    reason AS feedback_reason
  FROM
    `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity` AS t
  CROSS JOIN
    UNNEST(t.jsonPayload.request.userevent.feedback.reasons) AS reason
  WHERE
    t.jsonPayload.request.userevent.eventtype = 'add-feedback'
),
ContextualQueries AS (
  SELECT
    f.feedback_time,
    f.user_principal_name,
    f.feedback_type,
    f.feedback_comment,
    f.feedback_reason,
    -- Pre-aggregate previous 10-minute queries into a newline-separated string
    STRING_AGG(
      COALESCE(
        logs.jsonPayload.request.query, 
        logs.jsonPayload.request.userevent.searchinfo.searchquery
      ),
      '\n' ORDER BY logs.timestamp DESC
    ) AS user_queries_context
  FROM
    FeedbackEvents AS f
  LEFT JOIN
    `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity` AS logs
  ON
    f.user_principal_name = LOWER(TRIM(logs.jsonPayload.useriamprincipal))
    AND logs.timestamp BETWEEN TIMESTAMP_SUB(f.feedback_time, INTERVAL 10 MINUTE) AND f.feedback_time
    AND (
      logs.jsonPayload.request.query IS NOT NULL 
      OR logs.jsonPayload.request.userevent.searchinfo.searchquery IS NOT NULL
    )
  GROUP BY
    1, 2, 3, 4, 5
)
SELECT
  FORMAT_TIMESTAMP('%m/%d/%y', feedback_time) AS feedback_date_formatted,
  feedback_time,
  feedback_type,
  user_principal_name,
  feedback_comment,
  feedback_reason,
  COALESCE(user_queries_context, '[No queries in 10m window]') AS user_query_context
FROM
  ContextualQueries;
