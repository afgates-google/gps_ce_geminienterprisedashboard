# Google Cloud Gemini Enterprise Telemetry & Adoption Pipeline

[![GCP](https://img.shields.io/badge/GCP-Cloud_Logging-blue.svg)](https://cloud.google.com/logging)
[![BigQuery](https://img.shields.io/badge/Storage-BigQuery-669DF6.svg)](https://cloud.google.com/bigquery)
[![Looker](https://img.shields.io/badge/BI-Looker_Enterprise-4285F4.svg)](https://cloud.google.com/looker)
[![Looker Studio](https://img.shields.io/badge/BI-Looker_Studio-EA4335.svg)](https://lookerstudio.google.com/)

An end-to-end monitoring, telemetry, and adoption analytics pipeline for **Google Cloud Gemini Enterprise** (Discovery Engine / AgentSpace). 

This solution captures live user interactions from Cloud Logging, normalizes multi-turn conversations and feedback in BigQuery, correlates activity against enterprise identity directories (Okta, Microsoft Entra ID, LDAP), and powers executive adoption dashboards in both **Looker Enterprise** and **Looker Studio (Google Data Studio)**.

---

## Architecture Overview

```mermaid
graph TD
    A["Gemini Enterprise / AgentSpace"] -->|Runtime RPCs: Search, WriteUserEvent| B["Cloud Logging Sink"]
    B -->|Filtered by logName & serviceLabel| C[("BigQuery Raw Sink Table")]
    
    D[("IdP Directory: Okta / Entra / LDAP")] -->|Sync / Export| E["vw_canonical_users"]
    
    subgraph BigQuery Transformation Layer
        E -->|LEFT JOIN on normalized UPN| F["vw_user_adoption / vw_ds_executive_adoption"]
        C --> F
        C --> G["vw_events_flattened / vw_ds_feedback_metrics"]
        C --> H["vw_feedback_detailed / vw_ds_feedback_details"]
    end
    
    subgraph Visualization Layer
        F --> I["Looker Enterprise Dashboard (Deprecated)"]
        G --> I
        H --> I
        
        F --> J["Looker Studio: Executive View"]
        G --> K["Looker Studio: Feedback View"]
        H --> K
    end
```

---

## The Core Problem: The "Never Logged In" Adoption Gap

Standard Gemini Enterprise analytics report aggregate license counts, but fail to answer the primary operational question: **"Which specific users have been granted access but have never logged in?"**

1. **Log Analysis Alone is Insufficient**: Querying log tables only reports *active* users. It cannot report on users who are missing from the logs entirely.
2. **Directory Grounding**: By left-joining an authoritative identity directory (Okta, Microsoft Entra ID, or LDAP) against telemetry logs, this pipeline computes exact adoption percentages and flags non-adopters (`needs_follow_up = TRUE`) for targeted organizational enablement.
3. **Contextual Root-Cause Feedback**: When users submit thumbs-down feedback, the pipeline reconstructs the preceding 10 minutes of queries so developers can see what prompt triggered the issue.

---

## Designing a Plug-and-Play Identity Translation Layer (Canonical Identity Schema)

Designing a plug-and-play **Identity Translation Layer (Canonical Identity Schema)** makes this template portable across Okta, Microsoft Entra ID (Azure AD), Google Workspace, Ping Identity, or on-prem LDAP.

Here are the specific edge cases, real-world mismatches, and structural issues often overlooked when joining IdP directories with Google Cloud IAM audit records:

### 1. Case Sensitivity & Casing Discrepancies (The #1 Silent Failure)
* **The Issue**:
  * `userIamPrincipal` from Google Cloud logs is usually lowercase (e.g., `admin@example.gov` or `spenser.garrison@example.gov`).
  * Okta, Entra ID, and LDAP exports frequently preserve directory case or mixed case (e.g., `Spenser.Garrison@example.gov` or `AGates@example.gov`).
  * BigQuery string joins (`ON a.id = b.id`) are **case-sensitive by default**. If casing differs, an active user will silently join as `NULL` and falsely appear as **Never Logged In**.
* **Mitigation**: Your canonical schema must enforce `LOWER(TRIM(user_principal_name))` on both sides of the join.

### 2. Identifier Mismatch: UPN vs. Primary Email vs. SAML NameID
* **The Issue**:
  * In federated setups (Workforce Identity Federation / Cloud Identity), Google logs record whatever attribute was mapped as the principal.
  * In Entra ID and Okta, `userPrincipalName` (UPN) is often different from `mail` (primary email). For example, a user's login UPN might be `u123456@corp.internal.net` while their email is `first.last@example.gov`.
  * If the organization sends UPN in SAML/OIDC assertions, Google logs `u123456@...`, but an HR report or IdP export might list their friendly email.
* **Mitigation**: The canonical schema should accept both a primary identifier and an optional alias or email array, with a clear instruction: *"Map the field that matches what the user types to authenticate into Google Cloud/Gemini."*

### 3. Account Lifecycle & License Timing (The "Zombie" & "Ghost" User Problem)
* **The Issue**:
  * **Deprovisioned/Deactivated users**: When someone leaves, an IdP export might still list them with `status = 'SUSPENDED'` or `DEPROVISIONED`. If you don't filter them out, your "Never Logged In" list will be contaminated with ex-employees who *can't* log in.
  * **Created Date vs. First Seen**: If an employee was added to Okta yesterday, marking them as an "adoption failure" today is misleading.
* **Mitigation**: Your canonical IdP table must include `account_status` (Active, Suspended, Staged) and `assigned_date` / `created_date`. Looker should default to filtering `account_status = 'ACTIVE'`.

### 4. Group & Team Flattening (1:Many Relationships)
* **The Issue**:
  * In Okta (`user.profile.department`, `groups`) or Entra ID, a user often belongs to multiple groups or teams.
  * If someone exports an IdP table where a user has multiple rows (one for each group), joining this directly to `usage_audit` will **duplicate the user's event counts, search counts, and prompt metrics**.
* **Mitigation**:
  * Keep the user record strictly **1 row per user** (with a primary department/cost center).
  * If multi-group reporting is needed, groups should be an `ARRAY<STRING>` column, or split into a dedicated `bridge_user_teams` table to preserve accurate metric aggregation.

### 5. Service Accounts, Bots, and Admin Impersonation
* **The Issue**:
  * Google logs will capture background tasks, automated evaluators, and service accounts (e.g., `sa-gemini-evaluator@...gserviceaccount.com`).
  * These accounts will never exist in the Okta user list. If you do an inner join or fail to categorize them, your total activity counts won't reconcile.
* **Mitigation**:
  * Add a classifier or filter: `WHERE userIamPrincipal NOT LIKE '%gserviceaccount.com'`.
  * Support a `FULL OUTER JOIN` mode for diagnostics:
    * **Adopted Users**: In IdP + In Logs.
    * **Never Logged In**: In IdP + NOT In Logs (The target gap).
    * **Unmapped Shadow Users**: In Logs + NOT In IdP (Contractors, temp accounts, or misconfigured domains).

---

### The Canonical Schema Contract (`canonical_user_directory`)

Customers map their source IdP (Okta, Entra ID, Workday, LDAP) into this uniform format:

| Column Name | Type | Description | Okta Mapping | Entra ID Mapping |
| :--- | :--- | :--- | :--- | :--- |
| **`idp_user_id`** | STRING | Immutable IdP unique ID | `id` (e.g., `00u123...`) | `id` (object GUID) |
| **`user_principal_name`** | STRING | **The Join Key (Lowercased)** | `profile.login` | `userPrincipalName` |
| **`email`** | STRING | Primary email address | `profile.email` | `mail` |
| **`display_name`** | STRING | Full Name | `profile.displayName` | `displayName` |
| **`department`** | STRING | Department / Agency | `profile.department` | `department` |
| **`team_name`** | STRING | Primary Team or Cost Center | `profile.costCenter` | `officeLocation` |
| **`account_status`** | STRING | Active, Suspended, Deprovisioned | `status` | `accountEnabled` (ACTIVE/INACTIVE) |
| **`license_assigned_at`** | TIMESTAMP | When access was granted | `created` / assignment timestamp | license assignment time |

---

## Step-by-Step Implementation Guide & Design Rationale

### Step 1: Cloud Logging Ingestion & Filter Design
In Google Cloud Console, navigate to **Logging** $\rightarrow$ **Log Router** and create a sink targeting your BigQuery dataset:

```text
logName =~ "discoveryengine\.googleapis\.com%2Fgemini_enterprise_user_activity$"
AND jsonPayload.logMetadata.serviceLabel = "GEMINI_ENTERPRISE"
AND jsonPayload.logMetadata:*
```

#### Why We Did It:
* **Generic Project Portability (`=~ "...$"` regex)**: Hardcoding `projects/state-of-texas-agentspace-demo/...` breaks if templates or Terraform modules are deployed to development, staging, or other client environments. Matching the string ending keeps the filter completely reusable.
* **Dual Indexing (`logName` + `serviceLabel`)**: Filtering solely on `serviceLabel` forces Cloud Logging to scan and parse unindexed JSON payloads across every log generated in the GCP project (VPC flow logs, GKE, Compute Engine). Including `logName` allows the logging daemon to leverage indexed partition keys, dramatically speeding up evaluations and avoiding sink processing backlogs.
* **Strict Service Isolation**: Discovery Engine serves multiple workloads (Vertex AI Search, custom search engines). Explicitly checking `serviceLabel = "GEMINI_ENTERPRISE"` guarantees that other APIs sharing the logging stream are not accidentally ingested into the BigQuery audit dataset.

---

### Step 2: Designing the Canonical Identity Adapter (`vw_canonical_users`)
Instead of joining raw event logs directly to an Okta table, we inserted an abstraction view that standardizes any incoming directory schema (Okta, Entra ID, Ping Identity, LDAP) into a canonical identity contract:

```sql
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_canonical_users` AS
SELECT
  LOWER(TRIM(userPrincipalName)) AS user_principal_name,
  displayName AS display_name,
  COALESCE(department, 'Unassigned') AS department,
  COALESCE(teamName, 'General') AS team_name,
  COALESCE(accountStatus, 'ACTIVE') AS account_status,
  created_at AS license_assigned_at
FROM
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.okta_user_principals`
WHERE
  COALESCE(accountStatus, 'ACTIVE') = 'ACTIVE';
```

#### Why We Did It:
* **Eliminating Case-Sensitivity Discrepancies**: BigQuery string joins (`ON a.id = b.id`) are binary case-sensitive. GCP IAM logs output lowercase principals (e.g., `alex.chen@example.gov`), whereas IdPs frequently store mixed-case strings (`Alex.Chen@example.gov`). Without `LOWER(TRIM())`, active users silently fail to join, falsely appearing as "Never Logged In".
* **Deprovisioned/Deactivated Account Filtering**: Employees leave or change roles, remaining in IdP exports with status `SUSPENDED` or `DEPROVISIONED`. If counted in adoption metrics, ex-employees pollute the "follow-up" list with un-activatable users.
* **Plug-and-Play Portability**: When migrating from Okta to Entra ID or Google Workspace, administrators only have to modify this single adapter view. All downstream views, LookML models, and dashboard tiles remain untouched.

---

### Step 3: Resolving the "Never Logged In" Gap (`vw_user_adoption`)
We constructed a view that performs a `LEFT OUTER JOIN` starting from the directory registry (`vw_canonical_users`) against aggregated log events:

```sql
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
  dir.department,
  dir.team_name,
  dir.license_assigned_at,
  act.first_seen,
  act.last_seen,
  COALESCE(act.total_searches, 0) AS total_searches,
  COALESCE(act.total_feedbacks, 0) AS total_feedbacks,
  COALESCE(act.total_events, 0) AS total_events,
  
  -- Adoption Classification
  CASE 
    WHEN act.user_principal_name IS NOT NULL THEN 'Active (Logged In)' 
    ELSE 'Inactive (Never Logged In)' 
  END AS adoption_status,
  
  -- Target Follow-up Flag
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
```

#### Why We Did It:
* **The Direction of the Join**: Querying the log table alone only answers: *"Who is using the system?"* It cannot answer: *"Who has a license but isn't using it?"* By making the IdP directory the **left (base) table**, every licensed user is accounted for.
* **Service Account Exclusion**: Background test scripts and Google internal daemons emit records with principals ending in `.gserviceaccount.com`. Excluding them prevents non-human actors from skewing adoption figures.
* **Direct Actionability (`needs_follow_up`)**: Surfacing a simple boolean flag enables Casework/Business Operations leads to filter a Looker table with a single click to pull the exact list of non-adopters for enablement outreach.

---

### Step 4: Context-Aware Feedback Analysis (`vw_feedback_detailed`)
We created an analytical view that unnests feedback reasons while attaching a chronological window of previous interactions:

```sql
CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_feedback_detailed` AS
WITH UnpackedFeedback AS (
  SELECT
    t.timestamp AS feedback_time,
    t.jsonPayload.useriamprincipal AS userIamPrincipal,
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
  
  -- Preceding 10-Minute Context Window
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
  f.userIamPrincipal = logs.jsonPayload.useriamprincipal
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
```

#### Why We Did It:
* **1:Many Unnesting (`CROSS JOIN UNNEST`)**: A user can check multiple feedback boxes at once (e.g., both `BAD_CITATION` and `INACCURATE_RESPONSE`). Unnesting reasons enables categorical aggregations (e.g., pie and bar charts) without regex hacks or string matching.
* **The "Black Box" Problem Solved via `ARRAY_AGG`**: When a user leaves a dislike comment like *"Wrong handbook cited"*, knowing that fact in isolation is unhelpful. The engineering or content team needs to know: *What question did the user ask right before leaving that feedback?* Joining the preceding 10-minute window bundles the prompt and answer into the feedback record for immediate root-cause diagnosis.

---

### Step 5: [DEPRECATED] Looker Enterprise Modeling & Dashboard Construction
*Note: This approach is deprecated in favor of the Looker Studio implementation detailed in Steps 6-9.*

#### What We Did:
1. Configured the Looker Connection: Pointed Looker's BigQuery connection (`default_bigquery_connection`) to the `state-of-texas-agentspace-demo` project, granting the Looker Service Agent `roles/bigquery.dataViewer` and `roles/bigquery.jobUser`.
2. Built the LookML Model & Explore (`looker/models/agentspace_monitoring.model.lkml`):
   * Set `user_adoption` (the Okta directory) as the base explore.
   * Left-joined `events_flattened` and `feedback_detailed`.
3. Structured Dashboard Elements (`looker/dashboards/aes_knowledge_assistant.dashboard.lookml`):
   * KPI Tiles: Total Users (5,800), Active Users, Never Logged In (The Gap), % Adoption Rate.
   * Charts: Dislike Reasons (Pie Chart), Top Feedback Comments, Searches in Last 30 Days.
   * Master Detail Grid: User journeys and feedback context.

#### Key Syntax Lessons & Rationale:
* **YAML Extension Rule**: Looker strictly parses YAML dashboards only when the file ends with `.dashboard.lookml`. If named `.lkml`, Looker defaults to its curly-brace parser, triggering `- dashboard:` syntax errors.
* **`fields:` vs `field_list:`**: Looker standardizes on `fields: [...]` for multi-dimension visualizations (grids, pie charts). Using `field_list` causes Looker to drop the fields from the query payload, raising the error: *"Must query at least one dimension or measure"*.
* **URL Routing**: LookML dashboards are accessed via instance URL paths formatted as:
  `https://<instance_id>.looker.app/dashboards/<model_name>::<dashboard_name>`

---

### Step 6: Powering Executive Adoption & Regional Breakdowns (`vw_ds_executive_adoption`)

#### What We Did:
We created an executive-level adoption view that joins every active directory user with their aggregate Gemini Enterprise activity, computing explicit categorical labels and numerical indicator flags for instant aggregation in Looker Studio:

```sql
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
  -- Directory Hierarchy
  o.userPrincipalName AS user_email,
  o.displayName AS user_name,
  o.region,
  o.businessUnit AS business_unit,
  o.supervisorName AS supervisor_name,
  
  -- Activity Timestamps & Counts
  ua.first_login,
  ua.last_activity,
  COALESCE(ua.total_searches, 0) AS total_searches,
  COALESCE(ua.total_events, 0) AS total_events,
  
  -- Exact Categorical Label for Stacked Bar Visualizations
  CASE 
    WHEN ua.user_principal_name IS NOT NULL THEN 'Logged In At Least Once'
    ELSE 'Never Logged In'
  END AS login_status,
  
  -- Numerical Additive Flags for Single-Value Scorecard Cards
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
```

#### Why We Did It:
* **Zero-Calculation UI Integration**: Unlike Looker Enterprise (which uses LookML to compute measures at runtime), Looker Studio / Data Studio performs best when categorical dimensions are pre-computed in SQL. Emitting `'Logged In At Least Once'` and `'Never Logged In'` directly as values in a single `login_status` column allows authors to drag `login_status` directly into the **Breakdown Dimension** slot of a Stacked Bar chart without writing complex `CASE` statements inside the BI tool.
* **Pre-Baked Numerical Flags (`is_active`, `is_never_logged_in`)**: Looker Studio scorecards require simple metric aggregations. By defining `is_active` and `is_never_logged_in` as binary integers (`1` or `0`), scorecard metrics can simply be configured as `SUM(is_active)` or `SUM(is_never_logged_in)`, completely avoiding client-side calculation errors.
* **Hierarchy for Pivot Grids**: Including `region`, `business_unit`, and `supervisor_name` alongside the `login_status` metric allows Looker Studio to construct the multi-level organizational drill-down matrix (`Region` $\rightarrow$ `Business Unit` $\rightarrow$ `Supervisor`) in a single pivot table without joining secondary tables.

---

### Step 7: Normalized Feedback & Sentiment Aggregation (`vw_ds_feedback_metrics`)

#### What We Did:
We isolated feedback events into a normalized tabular stream, unnesting multi-value reason arrays and standardizing null comments:

```sql
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
```

#### Why We Did It:
* **Unnesting for Native BI Visualizations**: Cloud Logging records feedback reasons as an array (e.g., `["BAD_CITATION", "INACCURATE_RESPONSE"]`). Looker Studio cannot slice a pie chart or bar chart by an unflattened array. By using `CROSS JOIN UNNEST(...)`, each individual reason becomes an independent row, enabling native slice-and-dice charting for dislike distribution.
* **Handling Optional User Comments**: Users frequently click a thumbs-down button and pick a reason without typing a text comment. If comments are left as SQL `NULL`, Looker Studio visual tables will drop the row or display an unsightly blank cell. Coalescing nulls to `'[No Comment Provided]'` ensures clean, readable leaderboards in the **Feedback Comment Count** table.
* **Lightweight Granularity**: Separating feedback metrics from the heavy surrounding search context keeps query costs and latency low when users interact with the top-level pie charts and reason breakdown widgets.

---

### Step 8: Pre-Flattener for Contextual Journey Tables (`vw_ds_feedback_details`)

#### What We Did:
We built a specialized view that reconstructs the user's preceding 10-minute interaction trail, converting complex nested arrays into pre-formatted, newline-delimited strings compatible with Looker Studio table cells:

```sql
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
    -- Pre-aggregate previous 10-min queries into a multiline string for BI rendering
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
```

#### Why We Did It:
* **Circumventing Looker Studio's Nested Schema Limitation**: While BigQuery natively supports `ARRAY<STRUCT<...>>`, Looker Studio / Data Studio throws an error or disables visualization for tables containing nested structures. By transforming the historical array into a single `STRING_AGG(..., '\n')`, we package the multi-turn conversation history into a clean, multi-line text field that renders inside standard table cells.
* **Exact Replication of the Tableau Journey View**: The Tableau prototype displays all user questions that led to a thumbs-down stacked within a single cell under the column header: `userQuery (feedback reasons detailed working)`. This view replicates that exact visual behavior without requiring custom JavaScript or third-party Looker plugins.
* **Chronological Relevance**: Ordering by `logs.timestamp DESC` within the `STRING_AGG` ensures that the immediate prompt that triggered the dissatisfaction appears at the very top of the cell, followed by earlier questions in that session.

---

### Step 9: Assembling the Multi-Page Dashboard in Looker Studio (Data Studio)

#### What We Did:
With our semantic and aggregation logic pushed upstream into BigQuery views, building the dashboard in Looker Studio (formerly Google Data Studio) becomes a purely visual, drag-and-drop workflow across two dedicated pages: **Executive View** and **Feedback Metrics**.

```
[Looker Studio Multi-Page Report]
│
├── Page 1: "AES Knowledge Assistant - Executive View"
│   ├── Data Source: vw_ds_executive_adoption
│   ├── 3x3 Header KPI Matrix (Adoption, Prompts, Licenses)
│   ├── User Login by Region (Stacked Horizontal Bar)
│   ├── User Login by Business Unit (Stacked Horizontal Bar)
│   └── User Adoption Pivot Matrix (Region ➔ BU ➔ Supervisor)
│
└── Page 2: "AES Knowledge Assistant - Feedback Metrics"
    ├── Data Sources: vw_ds_feedback_metrics & vw_ds_feedback_details
    ├── Dislike Reasons (Pie Chart) & Sentiment Split (Donut Chart)
    ├── Feedback Reason & Comment Leaderboards (Ranked Tables)
    └── Master User & Feedback Details (Full-Width Journey Grid)
```

#### Part 1: Connecting BigQuery Data Sources
1. Open **[Looker Studio](https://lookerstudio.google.com/)** and click **Create** $\rightarrow$ **Report**.
2. When prompted for your data source, choose the **BigQuery** connector:
   * **Project**: `state-of-texas-agentspace-demo`
   * **Dataset**: `summit_2026_bw_ge_logs_demo`
   * **Table**: Select `vw_ds_executive_adoption`.
3. In the report editor, navigate to **Resource** $\rightarrow$ **Manage added data sources** $\rightarrow$ **Add a Data Source**.
4. Repeat the connection steps to add the remaining two views:
   * `vw_ds_feedback_metrics`
   * `vw_ds_feedback_details`

#### Part 2: Building Page 1 — "Executive View"
*(Ensure canvas data source is set to `vw_ds_executive_adoption`)*

##### A. Configure the Header 3x3 KPI Scorecard Matrix:

| KPI Title | Metric Selection | Aggregation | Display Format |
| :--- | :--- | :--- | :--- |
| **Total Users** | `user_email` | Count Distinct | Compact Number (`5,800`) |
| **Active Users** | `is_active` | SUM | Compact Number (`5,071`) |
| **Never Logged In** | `is_never_logged_in` | SUM | Compact Number (`2,147`) |
| **Total Prompts** | `total_events` | SUM | Number (`2,367,101`) |
| **Monthly Active Users** | `is_active` | SUM (apply 30-day filter) | Compact Number (`2,745`) |
| **Total Searches in Last 30 Days** | `total_searches` | SUM | Compact Number (`25,926`) |
| **Total Licenses Procured** | `total_licenses_procured`| SUM | Compact Number (`5,800`) |
| **Feedback Count** | Switch to `vw_ds_feedback_metrics` $\rightarrow$ `Record Count` | SUM | Compact Number (`36,601`) |
| **% Adoption Rate** | Create Calculated Field: `SUM(is_active) / COUNT_DISTINCT(user_email)` | Auto | Percentage (`80.35%`) |

##### B. Visual 1: User Login by Region (Left Stacked Bar)
1. Add chart: **Stacked Bar Chart** (Horizontal).
2. **Dimension**: `region`.
3. **Breakdown Dimension**: `login_status`.
4. **Metric**: `Record Count`.
5. **Sort**: By `Record Count`, Descending.
6. **Style**:
   * Set color for `Logged In At Least Once` $\rightarrow$ **Orange** (`#E67E22`).
   * Set color for `Never Logged In` $\rightarrow$ **Navy Blue** (`#2E4053`).
   * Enable **Show Data Labels**.

##### C. Visual 2: User Login by Business Unit (Center Stacked Bar)
1. Add chart: **Stacked Bar Chart** (Horizontal).
2. **Dimension**: `business_unit`.
3. **Breakdown Dimension**: `login_status`.
4. **Metric**: `Record Count`.
5. **Sort**: By `Record Count`, Descending.
6. **Style**: Inherit the exact same orange and blue categorical palette for visual consistency.

##### D. Visual 3: User Adoption by Business Unit & Regions (Right Pivot Table)
1. Add chart: **Pivot Table**.
2. **Row Dimensions**: Add in order:
   * `region`
   * `business_unit`
   * `supervisor_name`
3. **Column Dimension**: `login_status`.
4. **Metric**: `Record Count`.
5. **Style**: Enable column headers, row totals, and optional drill-down hierarchy if desired.

#### Part 3: Building Page 2 — "Feedback Metrics"
Click **Add page** in the top menu and rename the tab to **"Feedback Metrics"**.

##### A. Dislike Reasons Breakdown (Top Right Pie Chart)
1. Add chart: **Pie Chart**.
2. **Data Source**: `vw_ds_feedback_metrics`.
3. **Dimension**: `feedback_reason`.
4. **Metric**: `Record Count`.
5. **Filter**: Click **Add a filter** $\rightarrow$ Create: `Include feedback_type = 'DISLIKE'`.
6. **Style**: Set legend to the right and enable slice labels as value counts.

##### B. Like vs. Dislike Distribution (Donut Chart)
1. Add chart: **Donut Chart**.
2. **Data Source**: `vw_ds_feedback_metrics`.
3. **Dimension**: `feedback_type`.
4. **Metric**: `Record Count`.
5. **Style**: Label colors (Blue for Dislike/Null, Orange for Like).

##### C. Reason & Comment Leaderboards (Middle Horizontal Tables)
1. **Feedback Reason Count (Left Table)**:
   * **Dimension**: `feedback_reason`.
   * **Metric**: `Record Count`.
   * **Style**: In Metric column formatting, set format to **Bar / Heatmap** with dark blue shading.
2. **Feedback Comment Count (Center Table)**:
   * **Dimension**: `feedback_comment`.
   * **Metric**: `Record Count`.
   * **Sort**: By `Record Count` descending to surface recurring user complaints at the top.
3. **Feedback Count by Username (Right Table)**:
   * **Dimension**: `user_principal_name`.
   * **Metric**: `Record Count`.

##### D. Master User & Feedback Details (Bottom Journey Table)
1. Add chart: **Table**.
2. **Data Source**: `vw_ds_feedback_details`.
3. **Dimensions** (Add strictly in this column sequence):
   1. `feedback_date_formatted` (Renamed: `Feedback Time`)
   2. `feedback_type` (Renamed: `Feedback Type`)
   3. `user_principal_name` (Renamed: `User Principal`)
   4. `feedback_comment` (Renamed: `Feedback Comment`)
   5. `feedback_reason` (Renamed: `Feedback Reason`)
   6. `user_query_context` (Renamed: `userQuery (feedback reasons detailed working)`)
4. **Metric**: Leave empty (Table displays raw qualitative events).
5. **Style**:
   * Check **Wrap Text** for table cells (essential so the multiline user queries display stacked cleanly).
   * Enable row striping and pagination (25 or 50 rows per page).

#### Why We Did It (The Architectural Value of this Design):
* **Decoupled Architecture**: By doing 100% of the JSON unnesting, casing normalization, and window aggregations inside BigQuery views, Looker Studio runs zero client-side transformations. Dashboard pages load in under 2 seconds even against hundreds of thousands of raw log records.
* **True Self-Service for Stakeholders**: Because the identity and metric dimensions are clean strings and integers, business leads can apply interactive canvas filters (such as clicking on `Region 11` or a specific `Business Unit`) and watch all KPI scorecards and feedback tables instantly cross-filter without breaking complex calculated metrics.

---

## Deliverables Summary

| Deliverable | Location / Name | Purpose |
| :--- | :--- | :--- |
| **Log Filter** | Cloud Logging | Filters Gemini Enterprise logs across any GCP project. |
| **Synthetic Directory** | `sql/01_synthetic_directory.sql` | Generates 5,800 sanitized sample users across 12 regions & 12 BUs. |
| **Adapter View** | `vw_canonical_users` | Normalizes UPN case, trims whitespace, filters active accounts. |
| **Adoption View** | `vw_user_adoption` | Surfaces the "Never Logged In" gap and adoption %. |
| **Flattened Events** | `vw_events_flattened` | Standardizes search and prompt event counts. |
| **Feedback View** | `vw_feedback_detailed` | Unpacks reasons and links 10-minute preceding query context. |
| **Looker Studio Executive**| `vw_ds_executive_adoption` | Powers Page 1: Regional/BU stacked bars and pivot matrix. |
| **Looker Studio Feedback** | `vw_ds_feedback_metrics` | Powers Page 2: Dislike reasons pie, donut, reason counts. |
| **Looker Studio Details**  | `vw_ds_feedback_details` | Powers Page 2: Multiline user journey table via `STRING_AGG`. |
| **LookML Model (Dep.)**   | `looker/models/agentspace_monitoring.model.lkml` | Joins directory to activity events. |
| **LookML Dashboard (Dep.)**| `looker/dashboards/aes_knowledge_assistant.dashboard.lookml` | Visual layout for Looker Enterprise. |
| **Architecture Diagram**   | `diagrams/code_flow.dot` | Top-to-bottom Graphviz DOT architecture flow. |

---

## Security & Privacy Guidelines
* All synthetic identifiers use RFC 2606 reserved domains (`example.gov`).
* Production deployments should enforce BigQuery column-level security or row-level access policies (RLS) if individual departments should only view their respective regional adoption metrics.
