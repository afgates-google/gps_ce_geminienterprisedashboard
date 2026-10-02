# =============================================================================
# user_adoption.view.lkml
# Purpose: Maps canonical identity data and adoption metrics.
# =============================================================================

view: user_adoption {
  sql_table_name: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_user_adoption` ;;

  dimension: user_principal_name {
    primary_key: yes
    type: string
    sql: ${TABLE}.user_principal_name ;;
  }

  dimension: display_name {
    type: string
    sql: ${TABLE}.display_name ;;
  }

  dimension: region {
    type: string
    sql: ${TABLE}.region ;;
  }

  dimension: business_unit {
    type: string
    sql: ${TABLE}.business_unit ;;
  }

  dimension: supervisor_name {
    type: string
    sql: ${TABLE}.supervisor_name ;;
  }

  dimension: adoption_status {
    type: string
    sql: ${TABLE}.adoption_status ;;
  }

  dimension: needs_follow_up {
    type: yesno
    sql: ${TABLE}.needs_follow_up ;;
  }

  dimension_group: license_assigned {
    type: time
    timeframes: [raw, date, week, month, year]
    sql: ${TABLE}.license_assigned_at ;;
  }

  measure: total_potential_users {
    type: count
    description: "Total licensed users in directory"
  }

  measure: active_logged_in_users {
    type: count
    filters: [adoption_status: "Active (Logged In)"]
    description: "Users who have executed at least one interaction"
  }

  measure: never_logged_in_users {
    type: count
    filters: [needs_follow_up: "yes"]
    description: "Users granted access who have never logged in"
  }

  measure: adoption_percentage {
    type: number
    sql: 1.0 * ${active_logged_in_users} / NULLIF(${total_potential_users}, 0) ;;
    value_format_name: percent_2
  }
}
