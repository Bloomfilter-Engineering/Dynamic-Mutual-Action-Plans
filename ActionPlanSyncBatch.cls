/**
 * ActionPlanSyncBatch.cls
 * Batch processor for synchronizing custom action plans to native Salesforce Action Plans
 */
public class ActionPlanSyncBatch implements 
    Database.Batchable<SObject>, 
    Database.Stateful, 
    Database.AllowsCallouts {
    
    // Tracking variables
    private Integer recordsProcessed = 0;
    private Integer recordsSuccessful = 0;
    private Integer recordsFailed = 0;
    private List<String> errorMessages = new List<String>();
    private DateTime batchStartTime;
    private String notificationEmail;
    
    // Configuration
    private static final Integer DEFAULT_BATCH_SIZE = 50;
    private static final String DEFAULT_STATUS = 'Pending';
    
    /**
     * Constructor
     */
    public ActionPlanSyncBatch() {
        this(UserInfo.getUserEmail());
    }
    
    public ActionPlanSyncBatch(String notificationEmail) {
        this.notificationEmail = notificationEmail;
        this.batchStartTime = System.now();
    }
    
    /**
     * Start method - queries records to process
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Log batch start
        logBatchEvent('Started', 'Batch job started at ' + batchStartTime);
        
        // Query for pending action plans
        String query = 'SELECT Id, External_Reference_Id__c, Status__c, ' +
                      'Submitted_By_Email__c, Submitted_By_Name__c, ' +
                      'Related_Record_Id__c, Related_Object_Type__c, ' +
                      'Native_Action_Plan_Id__c, Sync_Status__c, ' +
                      'Submission_Date__c, ' +
                      '(SELECT Id, Name, Description__c, Due_Date__c, ' +
                      'Priority__c, Category__c, Assigned_To_Email__c, ' +
                      'Days_After_Start__c, Is_Required__c, Task_Order__c ' +
                      'FROM Custom_Tasks__r ORDER BY Task_Order__c) ' +
                      'FROM Custom_Action_Plan__c ' +
                      'WHERE Sync_Status__c IN (\'Not Started\', \'Error\') ' +
                      'AND Status__c = \'' + DEFAULT_STATUS + '\' ' +
                      'ORDER BY Submission_Date__c ASC';
        
        return Database.getQueryLocator(query);
    }
    
    /**
     * Execute method - processes each batch
     */
    public void execute(Database.BatchableContext bc, List<Custom_Action_Plan__c> scope) {
        System.debug('Processing batch of ' + scope.size() + ' records');
        
        for (Custom_Action_Plan__c customPlan : scope) {
            recordsProcessed++;
            
            try {
                processSingleActionPlan(customPlan);
                recordsSuccessful++;
            } catch (Exception e) {
                recordsFailed++;
                handleProcessingError(customPlan, e);
            }
        }
    }
    
    /**
     * Finish method - sends summary email and logs completion
     */
    public void finish(Database.BatchableContext bc) {
        // Get job info
        AsyncApexJob job = [
            SELECT Id, Status, NumberOfErrors, JobItemsProcessed,
                   TotalJobItems, CompletedDate, ExtendedStatus
            FROM AsyncApexJob
            WHERE Id = :bc.getJobId()
        ];
        
        // Log completion
        logBatchEvent('Completed', buildCompletionMessage(job));
        
        // Send notification email
        if (String.isNotBlank(notificationEmail)) {
            sendCompletionEmail(job);
        }
        
        // Schedule next batch if configured
        scheduleNextBatch();
    }
    
    /**
     * Process a single action plan
     */
    private void processSingleActionPlan(Custom_Action_Plan__c customPlan) {
        Savepoint sp = Database.setSavepoint();
        
        try {
            // Mark as in progress
            customPlan.Sync_Status__c = 'In Progress';
            update customPlan;
            
            // Find or create target record
            Id targetRecordId = resolveTargetRecord(customPlan);
            
            if (targetRecordId == null) {
                throw new SyncException('Unable to resolve target record for action plan');
            }
            
            // Create native action plan
            ActionPlan nativeAP = createNativeActionPlan(customPlan, targetRecordId);
            insert nativeAP;
            
            // Create action plan tasks
            if (!customPlan.Custom_Tasks__r.isEmpty()) {
                List<ActionPlanTask> nativeTasks = createNativeTasks(
                    nativeAP.Id, 
                    customPlan.Custom_Tasks__r
                );
                insert nativeTasks;
            }
            
            // Update custom action plan with success
            customPlan.Native_Action_Plan_Id__c = nativeAP.Id;
            customPlan.Status__c = 'Synced';
            customPlan.Sync_Status__c = 'Completed';
            customPlan.Error_Message__c = null;
            update customPlan;
            
            // Log success
            createLog(customPlan.Id, 'Synced', 'Successfully synced to native action plan: ' + nativeAP.Id);
            
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }
    
    /**
     * Resolve target record for action plan
     */
    private Id resolveTargetRecord(Custom_Action_Plan__c customPlan) {
        // If already has a related record, validate and return
        if (String.isNotBlank(customPlan.Related_Record_Id__c)) {
            if (validateRecordExists(customPlan.Related_Record_Id__c, customPlan.Related_Object_Type__c)) {
                return customPlan.Related_Record_Id__c;
            }
        }
        
        // Otherwise, find or create based on email
        String email = customPlan.Submitted_By_Email__c;
        String name = customPlan.Submitted_By_Name__c;
        
        // Check for existing Contact
        List<Contact> contacts = [
            SELECT Id 
            FROM Contact 
            WHERE Email = :email 
            LIMIT 1
        ];
        
        if (!contacts.isEmpty()) {
            return contacts[0].Id;
        }
        
        // Check for existing Lead
        List<Lead> leads = [
            SELECT Id 
            FROM Lead 
            WHERE Email = :email 
            AND IsConverted = false
            LIMIT 1
        ];
        
        if (!leads.isEmpty()) {
            return leads[0].Id;
        }
        
        // Create new Lead
        return createLead(email, name);
    }
    
    /**
     * Validate if a record exists
     */
    private Boolean validateRecordExists(String recordId, String objectType) {
        try {
            if (String.isBlank(objectType)) {
                objectType = 'Lead'; // Default
            }
            
            String query = 'SELECT Id FROM ' + 
                          String.escapeSingleQuotes(objectType) + 
                          ' WHERE Id = :recordId LIMIT 1';
                          
            List<SObject> records = Database.query(query);
            return !records.isEmpty();
            
        } catch (Exception e) {
            System.debug('Error validating record: ' + e.getMessage());
            return false;
        }
    }
    
    /**
     * Create a new Lead record
     */
    private Id createLead(String email, String name) {
        Lead newLead = new Lead();
        newLead.Email = email;
        newLead.LeadSource = 'Web';
        newLead.Status = 'New';
        newLead.Company = 'Guest Submission';
        
        // Parse name
        if (String.isNotBlank(name)) {
            List<String> nameParts = name.trim().split(' ', 2);
            if (nameParts.size() > 1) {
                newLead.FirstName = nameParts[0];
                newLead.LastName = nameParts[1];
            } else {
                newLead.LastName = name;
            }
        } else {
            newLead.LastName = 'Guest User';
        }
        
        insert newLead;
        return newLead.Id;
    }
    
    /**
     * Create native Action Plan
     */
    private ActionPlan createNativeActionPlan(Custom_Action_Plan__c customPlan, Id targetId) {
        ActionPlan ap = new ActionPlan();
        ap.Name = 'Web Submission: ' + customPlan.External_Reference_Id__c;
        ap.StartDate = Date.today();
        ap.TargetId = targetId;
        
        // Try to find a matching template
        List<ActionPlanTemplate> templates = [
            SELECT Id 
            FROM ActionPlanTemplate 
            WHERE IsActive = true 
            AND (Name LIKE '%Guest%' OR Name LIKE '%Web%')
            LIMIT 1
        ];
        
        if (!templates.isEmpty()) {
            ap.ActionPlanTemplateId = templates[0].Id;
        }
        
        return ap;
    }
    
    /**
     * Create native Action Plan Tasks
     */
    private List<ActionPlanTask> createNativeTasks(Id actionPlanId, List<Custom_Task__c> customTasks) {
        List<ActionPlanTask> tasks = new List<ActionPlanTask>();
        
        for (Custom_Task__c customTask : customTasks) {
            ActionPlanTask apt = new ActionPlanTask();
            apt.ActionPlanId = actionPlanId;
            apt.Subject = customTask.Name;
            apt.Description = customTask.Description__c;
            apt.Priority = mapPriority(customTask.Priority__c);
            apt.IsRequired = customTask.Is_Required__c;
            
            // Set days from start
            if (customTask.Days_After_Start__c != null) {
                apt.DaysFromStart = Integer.valueOf(customTask.Days_After_Start__c);
            } else {
                apt.DaysFromStart = 1;
            }
            
            // Find assigned user
            if (String.isNotBlank(customTask.Assigned_To_Email__c)) {
                List<User> users = [
                    SELECT Id 
                    FROM User 
                    WHERE Email = :customTask.Assigned_To_Email__c 
                    AND IsActive = true
                    LIMIT 1
                ];
                
                if (!users.isEmpty()) {
                    apt.AssignedToId = users[0].Id;
                } else {
                    apt.AssignedToId = UserInfo.getUserId();
                }
            } else {
                apt.AssignedToId = UserInfo.getUserId();
            }
            
            tasks.add(apt);
        }
        
        return tasks;
    }
    
    /**
     * Map priority values
     */
    private String mapPriority(String customPriority) {
        if (customPriority == 'High') return 'High';
        if (customPriority == 'Low') return 'Low';
        return 'Normal';
    }
    
    /**
     * Handle processing errors
     */
    private void handleProcessingError(Custom_Action_Plan__c customPlan, Exception e) {
        String errorMessage = 'Error processing action plan ' + 
                            customPlan.External_Reference_Id__c + ': ' + 
                            e.getMessage();
        
        errorMessages.add(errorMessage);
        System.debug(LoggingLevel.ERROR, errorMessage);
        
        // Update the action plan record
        customPlan.Status__c = 'Failed';
        customPlan.Sync_Status__c = 'Error';
        customPlan.Error_Message__c = e.getMessage().left(2000);
        
        try {
            update customPlan;
            createLog(customPlan.Id, 'Failed', e.getMessage() + '\n' + e.getStackTraceString());
        } catch (Exception updateEx) {
            System.debug('Failed to update error status: ' + updateEx.getMessage());
        }
    }
    
    /**
     * Create submission log
     */
    private void createLog(Id actionPlanId, String eventType, String details) {
        try {
            insert new Action_Plan_Submission_Log__c(
                Custom_Action_Plan__c = actionPlanId,
                Event_Type__c = eventType,
                Event_Date__c = System.now(),
                Details__c = details.left(32768)
            );
        } catch (Exception e) {
            System.debug('Failed to create log: ' + e.getMessage());
        }
    }
    
    /**
     * Log batch-level events
     */
    private void logBatchEvent(String status, String message) {
        try {
            insert new Action_Plan_Submission_Log__c(
                Event_Type__c = 'Batch_' + status,
                Event_Date__c = System.now(),
                Details__c = message
            );
        } catch (Exception e) {
            System.debug('Failed to log batch event: ' + e.getMessage());
        }
    }
    
    /**
     * Build completion message
     */
    private String buildCompletionMessage(AsyncApexJob job) {
        DateTime endTime = System.now();
        Long duration = (endTime.getTime() - batchStartTime.getTime()) / 1000;
        
        return String.format(
            'Batch completed in {0} seconds\n' +
            'Records Processed: {1}\n' +
            'Successful: {2}\n' +
            'Failed: {3}\n' +
            'Job Status: {4}\n' +
            'Job Errors: {5}',
            new List<Object>{
                duration,
                recordsProcessed,
                recordsSuccessful,
                recordsFailed,
                job.Status,
                job.NumberOfErrors
            }
        );
    }
    
    /**
     * Send completion email
     */
    private void sendCompletionEmail(AsyncApexJob job) {
        try {
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            
            email.setToAddresses(new String[] { notificationEmail });
            email.setSubject('Action Plan Sync Batch - ' + job.Status);
            
            String body = 'Action Plan Sync Batch Processing Results\n' +
                         '=========================================\n\n' +
                         buildCompletionMessage(job) + '\n\n';
            
            if (!errorMessages.isEmpty()) {
                body += 'Errors:\n';
                for (String error : errorMessages) {
                    body += '- ' + error + '\n';
                }
            }
            
            email.setPlainTextBody(body);
            Messaging.sendEmail(new Messaging.SingleEmailMessage[] { email });
            
        } catch (Exception e) {
            System.debug('Failed to send email: ' + e.getMessage());
        }
    }
    
    /**
     * Schedule next batch run if configured
     */
    private void scheduleNextBatch() {
        try {
            // Check if auto-schedule is enabled (could be from Custom Settings)
            // For now, we'll check if there are still pending records
            Integer pendingCount = [
                SELECT COUNT() 
                FROM Custom_Action_Plan__c 
                WHERE Sync_Status__c = 'Not Started'
                AND Status__c = :DEFAULT_STATUS
            ];
            
            if (pendingCount > 0) {
                // Schedule next batch in 5 minutes
                Datetime nextRun = System.now().addMinutes(5);
                String cronExp = nextRun.format('ss mm HH dd MM ? yyyy');
                String jobName = 'ActionPlanSync_' + System.now().getTime();
                
                System.schedule(jobName, cronExp, new ActionPlanBatchScheduler());
            }
            
        } catch (Exception e) {
            System.debug('Failed to schedule next batch: ' + e.getMessage());
        }
    }
    
    /**
     * Custom exception class
     */
    public class SyncException extends Exception {}
    
    /**
     * Scheduler class for batch
     */
    public class ActionPlanBatchScheduler implements Schedulable {
        public void execute(SchedulableContext sc) {
            Database.executeBatch(new ActionPlanSyncBatch(), DEFAULT_BATCH_SIZE);
        }
    }
}