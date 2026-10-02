-- =============================================================================
-- 02_views_looker_enterprise.sql
-- Purpose: Core analytical BigQuery views for Looker Enterprise modeling.
--          Includes identity normalization, user adoption gap analysis,
--          interaction event flattening, and multi-turn feedback context.
--
-- Target Dataset: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo`
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View 1: Canonical Users Identity Adapter
-- Normalizes casing and trims whitespace to prevent silent join failures.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_canonical_users` AS
SELECT
  LOWER(TRIM(userPrincipalName)) AS user_principal_name,
  displayName AS display_name,
  COALESCE(region, 'Unknown') AS region,
  COALESCE(businessUnit, 'Unassigned') AS business_unit,
  COALESCE(supervisorName, 'Unassigned') AS supervisor_name,
  COALESCE(accountStatus, 'ACTIVE') AS account_status,
  created_at AS license_assigned_at
FROM
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.okta_user_principals`
WHERE
  COALESCE(accountStatus, 'ACTIVE') = 'ACTIVE';

-- -----------------------------------------------------------------------------
-- View 2: User Adoption & Gap Analysis
-- LEFT JOIN starting from canonical users to live logs. Surfaces non-adopters.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_user_adoption` AS
WITH UserLogActivity AS (
  SELECT
    LOWER(TRIM(jsonPayload.useriamprincipal)) AS user_principal_name,
    MIN(timestamp) AS first_seen,
    MAX(timestamp) AS last_seen,
    COUNT(*) AS total_events,
    COUNTIF(
      jsonPayload.logmetadata.methodname = 'Search' 
      OR jsonPayload.request.userevent.eventtype = 'search'
    ) AS total_searches,
    COUNTIF(jsonPayload.request.userevent.eventtype = 'add-feedback') AS total_feedbacks
  FROM
    `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity`
  WHERE
    jsonPayload.useriamprincipal IS NOT NULL
    AND jsonPayload.useriamprincipal NOT LIKE '%gserviceaccount.com'
  GROUP BY 1
),
DirectoryRegistry AS (
  SELECT * FROM `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_canonical_users`
)
SELECT
  dir.user_principal_name,
  dir.display_name,
  dir.region,
  dir.business_unit,
  dir.supervisor_name,
  dir.license_assigned_at,
  act.first_seen,
  act.last_seen,
  COALESCE(act.total_searches, 0) AS total_searches,
  COALESCE(act.total_feedbacks, 0) AS total_feedbacks,
  COALESCE(act.total_events, 0) AS total_events,
  
  -- Adoption classification
  CASE 
    WHEN act.user_principal_name IS NOT NULL THEN 'Active (Logged In)' 
    ELSE 'Inactive (Never Logged In)' 
  END AS adoption_status,
  
  -- Actionable follow-up flag for enablement teams
  CASE 
    WHEN act.user_principal_name IS NULL THEN TRUE 
    ELSE FALSE 
  END AS needs_follow_up,
  
  IF(act.user_principal_name IS NOT NULL, 1, 0) AS is_active_count
FROM
  DirectoryRegistry AS dir
LEFT JOIN
  UserLogActivity AS act 
ON 
  dir.user_principal_name = act.user_principal_name;

-- -----------------------------------------------------------------------------
-- View 3: Flattened Events Base
-- Extracts searches, RPC methods, client metadata, and dates for KPI tracking.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_events_flattened` AS
SELECT
  timestamp,
  LOWER(TRIM(jsonPayload.useriamprincipal)) AS userIamPrincipal,
  jsonPayload.logmetadata.methodname AS method_name,
  jsonPayload.logmetadata.servicelabel AS service_label,
  COALESCE(
    jsonPayload.request.userevent.eventtype,
    LOWER(jsonPayload.logmetadata.methodname)
  ) AS event_type,
  COALESCE(
    jsonPayload.request.query,
    jsonPayload.request.userevent.searchinfo.searchquery
  ) AS userQuery,
  COALESCE(
    jsonPayload.request.servingconfig,
    jsonPayload.request.userevent.engine
  ) AS engine_or_config,
  jsonPayload.request.userevent.feedback.feedbacktype AS feedback_type,
  jsonPayload.request.userevent.feedback.comment AS feedback_comment,
  COALESCE(
    jsonPayload.response.attributiontoken,
    jsonPayload.request.userevent.attributiontoken,
    jsonPayload.request.userevent.feedback.conversationinfo.assisttoken
  ) AS serviceAttributionToken,
  jsonPayload.request.userevent.feedback.conversationinfo.session AS session_id,
  DATE(timestamp) AS event_date,
  EXTRACT(YEAR FROM timestamp) AS event_year,
  EXTRACT(MONTH FROM timestamp) AS event_month,
  FORMAT_TIMESTAMP('%Y-%m', timestamp) AS event_year_month,
  
  -- Prompt & Search markers
  CASE 
    WHEN jsonPayload.logmetadata.methodname = 'Search' 
      OR jsonPayload.request.userevent.eventtype IN ('search', 'query') 
      OR jsonPayload.request.query IS NOT NULL 
    THEN 1 
    ELSE 0 
  END AS is_search_or_prompt,
  
  CASE 
    WHEN jsonPayload.request.userevent.eventtype = 'add-feedback' 
    THEN 1 
    ELSE 0 
  END AS is_feedback,
  
  CASE 
    WHEN timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) 
    THEN 1 
    ELSE 0 
  END AS is_last_30_days
FROM
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity`
WHERE
  jsonPayload.logmetadata.servicelabel = 'GEMINI_ENTERPRISE';

-- -----------------------------------------------------------------------------
-- View 4: Detailed Feedback with 10-Minute Context Window
-- Unnests feedback reasons and captures surrounding query history as STRUCT array.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_feedback_detailed` AS
WITH UnpackedFeedback AS (
  SELECT
    t.timestamp AS feedback_time,
    LOWER(TRIM(t.jsonPayload.useriamprincipal)) AS userIamPrincipal,
    t.jsonPayload.request.userevent.feedback.conversationinfo.assisttoken AS feedback_attribution_token,
    t.jsonPayload.request.userevent.feedback.conversationinfo.session AS session_id,
    t.jsonPayload.request.userevent.feedback.feedbacktype AS feedback_type,
    t.jsonPayload.request.userevent.feedback.comment AS feedback_comment,
    reason AS feedback_reason
  FROM
    `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity` AS t
  CROSS JOIN
    UNNEST(t.jsonPayload.request.userevent.feedback.reasons) AS reason
  WHERE
    t.jsonPayload.request.userevent.eventtype = 'add-feedback'
)
SELECT
  f.feedback_time,
  f.userIamPrincipal,
  f.session_id,
  f.feedback_attribution_token,
  f.feedback_type,
  f.feedback_reason,
  f.feedback_comment,
  ARRAY_AGG(
    STRUCT(
      logs.timestamp AS event_timestamp,
      logs.jsonPayload.logmetadata.methodname AS method_name,
      COALESCE(
        logs.jsonPayload.request.query,
        logs.jsonPayload.request.userevent.searchinfo.searchquery
      ) AS userQuery,
      COALESCE(
        logs.jsonPayload.response.attributiontoken,
        logs.jsonPayload.request.userevent.attributiontoken
      ) AS related_token
    )
    ORDER BY logs.timestamp DESC
  ) AS related_events_context
FROM
  UnpackedFeedback AS f
LEFT JOIN
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.discoveryengine_googleapis_com_gemini_enterprise_user_activity` AS logs
ON
  f.userIamPrincipal = LOWER(TRIM(logs.jsonPayload.useriamprincipal))
  AND logs.timestamp BETWEEN TIMESTAMP_SUB(f.feedback_time, INTERVAL 10 MINUTE) AND f.feedback_time
  AND (logs.jsonPayload.request.query IS NOT NULL OR logs.jsonPayload.request.userevent.searchinfo.searchquery IS NOT NULL)
GROUP BY
  f.feedback_time,
  f.userIamPrincipal,
  f.session_id,
  f.feedback_attribution_token,
  f.feedback_type,
  f.feedback_reason,
  f.feedback_comment;
