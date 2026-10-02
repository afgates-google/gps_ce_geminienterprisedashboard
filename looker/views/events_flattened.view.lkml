# =============================================================================
# events_flattened.view.lkml
# Purpose: Maps telemetry events, search counts, and prompt activity.
# =============================================================================

view: events_flattened {
  sql_table_name: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_events_flattened` ;;

  dimension_group: event {
    type: time
    timeframes: [raw, time, date, week, month, quarter, year]
    sql: ${TABLE}.timestamp ;;
  }

  dimension: user_iam_principal {
    type: string
    sql: ${TABLE}.userIamPrincipal ;;
  }

  dimension: method_name {
    type: string
    sql: ${TABLE}.method_name ;;
  }

  dimension: event_type {
    type: string
    sql: ${TABLE}.event_type ;;
  }

  dimension: user_query {
    type: string
    sql: ${TABLE}.userQuery ;;
  }

  dimension: is_search_or_prompt {
    type: yesno
    sql: ${TABLE}.is_search_or_prompt = 1 ;;
  }

  dimension: is_last_30_days {
    type: yesno
    sql: ${TABLE}.is_last_30_days = 1 ;;
  }

  measure: total_events {
    type: count
    description: "Total RPC calls and logged interactions"
  }

  measure: total_prompts {
    type: count
    filters: [is_search_or_prompt: "yes"]
    description: "Searches and prompt events executed by caseworkers"
  }

  measure: searches_last_30_days {
    type: count
    filters: [is_last_30_days: "yes", is_search_or_prompt: "yes"]
    description: "Searches executed within rolling 30-day window"
  }
}
