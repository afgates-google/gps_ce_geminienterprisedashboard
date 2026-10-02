# =============================================================================
# agentspace_monitoring.model.lkml
# Purpose: Looker Enterprise model and explore definitions.
# =============================================================================

connection: "default_bigquery_connection"

# Include all view files in the views directory
include: "/views/*.view.lkml"

# Include dashboard definitions
include: "/dashboards/*.dashboard.lookml"

explore: user_adoption {
  label: "AgentSpace Usage & Adoption"
  description: "Identity-grounded adoption analytics joining canonical directory with Gemini Enterprise telemetry."
  
  # Join to events: preserves inactive users from Okta while attaching event history
  join: events_flattened {
    type: left_outer
    relationship: one_to_many
    sql_on: ${user_adoption.user_principal_name} = ${events_flattened.user_iam_principal} ;;
  }

  # Join to feedback: one user can submit multiple feedback items
  join: feedback_detailed {
    type: left_outer
    relationship: one_to_many
    sql_on: ${user_adoption.user_principal_name} = ${feedback_detailed.user_iam_principal} ;;
  }
}
