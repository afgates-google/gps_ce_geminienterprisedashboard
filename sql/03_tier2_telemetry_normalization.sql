-- =============================================================================
-- Tier 2: Telemetry Normalization Layer
-- File: sql/03_tier2_telemetry_normalization.sql
--
-- Purpose: Unpacks raw nested JSON payloads from Cloud Logging into normalized
--          relational event streams:
--          1. vw_events_flattened: Standardizes SearchService and UserEventService.
--          2. vw_feedback_detailed: Unnests multi-select reasons and links a
--             10-minute preceding contextual query window.
--
-- Target Dataset: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo`
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View 1: Unified Telemetry Events (vw_events_flattened)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_events_flattened` AS
SELECT
  -- Timestamp & Identity
  timestamp,
  LOWER(TRIM(jsonPayload.useriamprincipal)) AS userIamPrincipal,
  
  -- RPC & Service Metadata
  jsonPayload.logmetadata.methodname AS method_name,
  jsonPayload.logmetadata.servicelabel AS service_label,
  
  -- Unified Event Classification across SearchService and UserEventService
  COALESCE(
    jsonPayload.request.userevent.eventtype,
    LOWER(jsonPayload.logmetadata.methodname)
  ) AS event_type,
  
  -- User Query Extraction
  COALESCE(
    jsonPayload.request.query,
    jsonPayload.request.userevent.searchinfo.searchquery
  ) AS userQuery,
  
  -- Target Engine & Serving Config
  COALESCE(
    jsonPayload.request.servingconfig,
    jsonPayload.request.userevent.engine
  ) AS engine_or_config,
  
  -- Feedback Attributes (if row is a feedback event)
  jsonPayload.request.userevent.feedback.feedbacktype AS feedback_type,
  jsonPayload.request.userevent.feedback.comment AS feedback_comment,
  
  -- Attribution & Session Tracking
  COALESCE(
    jsonPayload.response.attributiontoken,
    jsonPayload.request.userevent.attributiontoken,
    jsonPayload.request.userevent.feedback.conversationinfo.assisttoken
  ) AS serviceAttributionToken,
  jsonPayload.request.userevent.feedback.conversationinfo.session AS session_id,
  
  -- Calendar Dimensions
  DATE(timestamp) AS event_date,
  EXTRACT(YEAR FROM timestamp) AS event_year,
  EXTRACT(MONTH FROM timestamp) AS event_month,
  FORMAT_TIMESTAMP('%Y-%m', timestamp) AS event_year_month,
  
  -- Interaction KPI Flags
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
-- View 2: Detailed Feedback with Preceding Context (vw_feedback_detailed)
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
  
  -- Preceding 10-Minute Context Window: user queries and attribution tokens
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
