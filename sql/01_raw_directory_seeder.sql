-- =============================================================================
-- Tier 0: Raw Ingestion / Identity Seeder
-- File: sql/01_raw_directory_seeder.sql
--
-- Purpose: Seeds the raw directory table (okta_user_principals) representing
--          an IdP export (Okta, Entra ID, Ping, or LDAP) with 5,800 licensed
--          user accounts across 12 public-sector regions, business units,
--          and supervisors.
--
-- Target Dataset: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo`
-- =============================================================================

CREATE OR REPLACE TABLE `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.okta_user_principals` AS
WITH FirstNames AS (
  SELECT ['Alex', 'Jordan', 'Taylor', 'Morgan', 'Sam', 'Pat', 'Casey', 'Riley', 'Avery', 'Reese'] AS names
),
LastNames AS (
  SELECT ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis', 'Rodriguez', 'Martinez'] AS names
),
Supervisors AS (
  SELECT ['Abigail Escalera', 'Brad Carter', 'Brittney Scoggins', 'Colleen Chance', 'Debra Gault', 
          'Grizel Morales', 'Irma Almaguer', 'Jeannette Blakely', 'Martin Maldonado', 'Misha Owens', 
          'Rafaela Dixon', 'Raul Torres', 'Robin Lewis', 'Shanicca Cruse', 'Tanisha Monroe'] AS names
),
Regions AS (
  SELECT ['11', '06', '03', '08', '10', '07', '04', '01', '05', '02', '00', '09'] AS codes
),
BusinessUnits AS (
  SELECT ['TX Works Region 11', 'TX Works Region 03', 'TX Works Region 06', 'Virtual Interviewing Centers', 
          'Customer Care Centers', 'TX Works Region 08', 'Access & Eligibility Svcs', 'TX Works Region 07', 
          'TX Works Region 04', 'TX Works Region 1', 'TX Works Region 10', 'TX Works Region 02/09'] AS units
)
SELECT
  -- RFC 2606 compliant email/UPN
  LOWER(CONCAT('user.', LPAD(CAST(idx AS STRING), 4, '0'), '@example.gov')) AS userPrincipalName,
  CONCAT(fn, ' ', ln) AS displayName,
  Regions.codes[OFFSET(MOD(idx, ARRAY_LENGTH(Regions.codes)))] AS region,
  BusinessUnits.units[OFFSET(MOD(idx, ARRAY_LENGTH(BusinessUnits.units)))] AS businessUnit,
  Supervisors.names[OFFSET(MOD(idx, ARRAY_LENGTH(Supervisors.names)))] AS supervisorName,
  CASE WHEN idx > 5600 THEN 'SUSPENDED' ELSE 'ACTIVE' END AS accountStatus,
  TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL CAST(MOD(idx, 90) AS INT64) DAY) AS created_at
FROM
  UNNEST(GENERATE_ARRAY(1, 5800)) AS idx,
  FirstNames, LastNames, Supervisors, Regions, BusinessUnits,
  UNNEST([FirstNames.names[OFFSET(MOD(idx, 10))]]) AS fn,
  UNNEST([LastNames.names[OFFSET(MOD(CAST(idx / 10 AS INT64), 10))]]) AS ln;

-- Seed an active admin user for live end-to-end testing
INSERT INTO `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.okta_user_principals`
  (userPrincipalName, displayName, region, businessUnit, supervisorName, accountStatus, created_at)
VALUES (
  'admin@example.gov',
  'Admin User',
  '11',
  'TX Works Region 11',
  'Executive Leadership',
  'ACTIVE',
  CURRENT_TIMESTAMP()
);
