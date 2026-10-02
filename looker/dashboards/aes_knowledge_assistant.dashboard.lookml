# =============================================================================
# aes_knowledge_assistant.dashboard.lookml
# Purpose: Declarative dashboard layout for Looker Enterprise.
# =============================================================================

- dashboard: aes_knowledge_assistant
  title: AES Knowledge Assistant - Feedback Metrics
  layout: newspaper
  preferred_viewer: dashboards-next
  
  elements:
    - name: total_users
      title: Total Users
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [user_adoption.total_potential_users]
      width: 4
      height: 3
    
    - name: active_users
      title: Active Users
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [user_adoption.active_logged_in_users]
      width: 4
      height: 3
    
    - name: never_logged_in
      title: Never Logged In
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [user_adoption.never_logged_in_users]
      width: 4
      height: 3

    - name: dislike_reasons_pie
      title: Dislike Reasons
      model: agentspace_monitoring
      explore: user_adoption
      type: looker_pie
      fields: [feedback_detailed.feedback_reason, feedback_detailed.feedback_count]
      filters:
        feedback_detailed.feedback_type: 'DISLIKE'
      width: 12
      height: 6

    - name: total_prompts
      title: Total Prompts
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [events_flattened.total_prompts]
      width: 4
      height: 3
      
    - name: monthly_active_users
      title: Monthly Active Users
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [user_adoption.active_logged_in_users]
      filters:
        events_flattened.event_month: 'this month'
      width: 4
      height: 3

    - name: searches_30_days
      title: Total Searches in last 30 days
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [events_flattened.searches_last_30_days]
      width: 4
      height: 3

    - name: licenses_procured
      title: Total Licenses Procured
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [user_adoption.total_potential_users]
      width: 4
      height: 3

    - name: feedback_count
      title: Feedback Count
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [feedback_detailed.feedback_count]
      width: 4
      height: 3

    - name: adoption_rate
      title: % Adoption
      model: agentspace_monitoring
      explore: user_adoption
      type: single_value
      fields: [user_adoption.adoption_percentage]
      width: 4
      height: 3

    - name: feedback_reason_count
      title: Feedback Reason Count
      model: agentspace_monitoring
      explore: user_adoption
      type: looker_grid
      fields: [feedback_detailed.feedback_reason, feedback_detailed.feedback_count]
      sorts: [feedback_detailed.feedback_count desc]
      width: 8
      height: 8

    - name: feedback_comment_count
      title: Feedback Comment Count
      model: agentspace_monitoring
      explore: user_adoption
      type: looker_grid
      fields: [feedback_detailed.feedback_comment, feedback_detailed.feedback_count]
      width: 8
      height: 8

    - name: user_feedback_ranking
      title: Feedback Count by Username
      model: agentspace_monitoring
      explore: user_adoption
      type: looker_grid
      fields: [user_adoption.display_name, feedback_detailed.feedback_count]
      width: 8
      height: 8

    - name: user_feedback_details
      title: User & Feedback Details
      model: agentspace_monitoring
      explore: user_adoption
      type: looker_grid
      fields: [events_flattened.event_date, feedback_detailed.feedback_type, user_adoption.user_principal_name, feedback_detailed.feedback_comment, feedback_detailed.feedback_reason]
      width: 24
      height: 12
