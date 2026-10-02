-- =============================================================================
-- Tier 1: Canonical Identity Adapter Layer
-- File: sql/02_tier1_identity_adapter.sql
--
-- Purpose: Implements the Canonical Identity Contract (vw_canonical_users).
--          Normalizes casing, trims whitespace, standardizes organizational
--          attributes, and filters out deactivated accounts.
--
--          PORTABILITY NOTE:
--          When connecting to Microsoft Entra ID (Azure AD), Google Workspace,
--          Ping, or on-prem LDAP, this is the ONLY view that needs modification.
--          All downstream presentation marts and dashboards consume this view.
--
-- Target Dataset: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo`
-- =============================================================================

CREATE OR REPLACE VIEW `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_canonical_users` AS
SELECT
  -- Canonical Primary Join Key: Enforce lowercase & trim to eliminate case-sensitivity mismatches
  LOWER(TRIM(userPrincipalName)) AS user_principal_name,
  
  -- Core Profile Attributes
  displayName AS display_name,
  COALESCE(region, 'Unknown') AS region,
  COALESCE(businessUnit, 'Unassigned') AS business_unit,
  COALESCE(supervisorName, 'Unassigned') AS supervisor_name,
  
  -- Lifecycle & Licensing Status
  COALESCE(accountStatus, 'ACTIVE') AS account_status,
  created_at AS license_assigned_at

FROM
  -- Replace with your raw directory export (e.g. entra_users, ldap_directory)
  `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.okta_user_principals`
WHERE
  -- Exclude deprovisioned or suspended staff from adoption target pool
  COALESCE(accountStatus, 'ACTIVE') = 'ACTIVE';
