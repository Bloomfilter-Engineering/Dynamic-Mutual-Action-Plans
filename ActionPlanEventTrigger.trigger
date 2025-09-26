/**
 * ActionPlanEventTrigger.trigger
 * Processes Action Plan Platform Events
 */
trigger ActionPlanEventTrigger on Action_Plan_Event__e (after insert) {
    
    // Collect action plan IDs to process
    Set<Id> actionPlanIds = new Set<Id>();
    
    for (Action_Plan_Event__e event : Trigger.new) {
        if (String.isNotBlank(event.Action_Plan_Id__c)) {
            actionPlanIds.add(event.Action_Plan_Id__c);
        }
    }
    
    if (!actionPlanIds.isEmpty()) {
        // Process asynchronously to avoid governor limits
        if (!System.isFuture() && !System.isBatch() && !System.isQueueable()) {
            ActionPlanEventHandler.processFuture(new List<Id>(actionPlanIds));
        } else {
            // If already in async context, process directly
            ActionPlanIntegrationService.syncToNativeActionPlans(new List<Id>(actionPlanIds));
        }
    }
    
    // Set replay ID for event recovery
    EventBus.TriggerContext tc = EventBus.TriggerContext.currentContext();
    for (Action_Plan_Event__e event : Trigger.new) {
        System.debug('Processing event with replay ID: ' + tc.getReplayId(event));
    }
}