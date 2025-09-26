/**
 * ActionPlanEventHandler.cls
 * Handles async processing of Action Plan events
 */
public with sharing class ActionPlanEventHandler {
    
    /**
     * Future method for async processing
     */
    @future
    public static void processFuture(List<Id> actionPlanIds) {
        try {
            ActionPlanIntegrationService.syncToNativeActionPlans(actionPlanIds);
        } catch (Exception e) {
            System.debug('Error in processFuture: ' + e.getMessage());
            handleAsyncError(actionPlanIds, e);
        }
    }
    
    /**
     * Queueable implementation for chain processing
     */
    public class ActionPlanQueueable implements Queueable, Database.AllowsCallouts {
        private List<Id> actionPlanIds;
        private Integer retryCount;
        private static final Integer MAX_RETRIES = 3;
        
        public ActionPlanQueueable(List<Id> actionPlanIds) {
            this(actionPlanIds, 0);
        }
        
        public ActionPlanQueueable(List<Id> actionPlanIds, Integer retryCount) {
            this.actionPlanIds = actionPlanIds;
            this.retryCount = retryCount;
        }
        
        public void execute(QueueableContext context) {
            try {
                ActionPlanIntegrationService.syncToNativeActionPlans(actionPlanIds);
            } catch (Exception e) {
                if (retryCount < MAX_RETRIES) {
                    // Retry with exponential backoff
                    System.enqueueJob(new ActionPlanQueueable(actionPlanIds, retryCount + 1));
                } else {
                    handleAsyncError(actionPlanIds, e);
                }
            }
        }
    }
    
    /**
     * Batch class for bulk processing
     */
    public class ActionPlanBatch implements Database.Batchable<SObject>, Database.Stateful {
        private String query;
        private Integer successCount = 0;
        private Integer errorCount = 0;
        
        public ActionPlanBatch() {
            // Process pending action plans
            this.query = 'SELECT Id FROM Custom_Action_Plan__c ' +
                        'WHERE Sync_Status__c IN (\'Not Started\', \'Error\') ' +
                        'AND Status__c = \'Pending\' ' +
                        'ORDER BY Submission_Date__c';
        }
        
        public Database.QueryLocator start(Database.BatchableContext bc) {
            return Database.getQueryLocator(query);
        }
        
        public void execute(Database.BatchableContext bc, List<Custom_Action_Plan__c> scope) {
            List<Id> actionPlanIds = new List<Id>();
            
            for (Custom_Action_Plan__c plan : scope) {
                actionPlanIds.add(plan.Id);
            }
            
            try {
                ActionPlanIntegrationService.syncToNativeActionPlans(actionPlanIds);
                successCount += actionPlanIds.size();
            } catch (Exception e) {
                errorCount += actionPlanIds.size();
                System.debug('Batch processing error: ' + e.getMessage());
            }
        }
        
        public void finish(Database.BatchableContext bc) {
            // Get job info
            AsyncApexJob job = [
                SELECT Id, Status, NumberOfErrors, JobItemsProcessed,
                       TotalJobItems, CreatedBy.Email
                FROM AsyncApexJob
                WHERE Id = :bc.getJobId()
            ];
            
            sendBatchSummaryEmail(job, successCount, errorCount);
        }
    }
    
    /**
     * Scheduled class for regular processing
     */
    public class ActionPlanScheduler implements Schedulable {
        public void execute(SchedulableContext sc) {
            // Run batch job
            Database.executeBatch(new ActionPlanBatch(), 50);
            
            // Clean up old submissions
            cleanupOldSubmissions();
        }
        
        private void cleanupOldSubmissions() {
            // Delete logs older than 90 days
            Date cutoffDate = Date.today().addDays(-90);
            
            List<Action_Plan_Submission_Log__c> oldLogs = [
                SELECT Id
                FROM Action_Plan_Submission_Log__c
                WHERE Event_Date__c < :cutoffDate
                LIMIT 10000
            ];
            
            if (!oldLogs.isEmpty()) {
                delete oldLogs;
            }
        }
    }
    
    private static void handleAsyncError(List<Id> actionPlanIds, Exception e) {
        // Update action plans with error status
        List<Custom_Action_Plan__c> plans = [
            SELECT Id
            FROM Custom_Action_Plan__c
            WHERE Id IN :actionPlanIds
        ];
        
        for (Custom_Action_Plan__c plan : plans) {
            plan.Status__c = 'Failed';
            plan.Sync_Status__c = 'Error';
            plan.Error_Message__c = 'Async processing failed: ' + e.getMessage();
        }
        
        update plans;
        
        // Log errors
        List<Action_Plan_Submission_Log__c> logs = new List<Action_Plan_Submission_Log__c>();
        for (Id planId : actionPlanIds) {
            logs.add(new Action_Plan_Submission_Log__c(
                Custom_Action_Plan__c = planId,
                Event_Type__c = 'Failed',
                Event_Date__c = System.now(),
                Details__c = 'Async error: ' + e.getMessage()
            ));
        }
        
        insert logs;
    }
    
    private static void sendBatchSummaryEmail(AsyncApexJob job, Integer success, Integer errors) {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        
        email.setToAddresses(new String[] { job.CreatedBy.Email });
        email.setSubject('Action Plan Batch Processing Complete');
        
        String body = 'Action Plan batch processing has completed.\n\n' +
                     'Job Status: ' + job.Status + '\n' +
                     'Records Processed: ' + job.JobItemsProcessed + '\n' +
                     'Successful: ' + success + '\n' +
                     'Errors: ' + errors + '\n\n' +
                     'Job ID: ' + job.Id;
        
        email.setPlainTextBody(body);
        
        Messaging.sendEmail(new Messaging.SingleEmailMessage[] { email });
    }
}