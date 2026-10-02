# =============================================================================
# feedback_detailed.view.lkml
# Purpose: Maps unnested user feedback reasons, comments, and sentiment.
# =============================================================================

view: feedback_detailed {
  sql_table_name: `state-of-texas-agentspace-demo.summit_2026_bw_ge_logs_demo.vw_feedback_detailed` ;;

  dimension: user_iam_principal {
    type: string
    sql: ${TABLE}.userIamPrincipal ;;
  }

  dimension: feedback_reason {
    type: string
    sql: ${TABLE}.feedback_reason ;;
  }

  dimension: feedback_comment {
    type: string
    sql: ${TABLE}.feedback_comment ;;
  }

  dimension: feedback_type {
    type: string
    sql: ${TABLE}.feedback_type ;;
  }

  dimension: session_id {
    type: string
    sql: ${TABLE}.session_id ;;
  }

  dimension_group: feedback {
    type: time
    timeframes: [raw, time, date, week, month, year]
    sql: ${TABLE}.feedback_time ;;
  }

  measure: feedback_count {
    type: count
    description: "Total individual feedback citations submitted"
  }

  measure: dislike_count {
    type: count
    filters: [feedback_type: "DISLIKE"]
    description: "Negative feedback count"
  }

  measure: like_count {
    type: count
    filters: [feedback_type: "LIKE"]
    description: "Positive feedback count"
  }
}
