/**
 * ActionPlanIntegrationService.cls
 * Handles integration between custom objects and native Salesforce Action Plans
 */
public with sharing class ActionPlanIntegrationService {
    
    /**
     * Process custom action plans and create native Action Plans
     * Called by Platform Event trigger or batch job
     */
    public static void syncToNativeActionPlans(List<Id> customActionPlanIds) {
        try {
            // Query custom action plans with tasks
            List<Custom_Action_Plan__c> customPlans = queryCustomActionPlans(customActionPlanIds);
            
            if (customPlans.isEmpty()) {
                return;
            }
            
            // Process each action plan
            for (Custom_Action_Plan__c customPlan : customPlans) {
                try {
                    processActionPlan(customPlan);
                } catch (Exception e) {
                    handleSyncError(customPlan, e);
                }
            }
            
        } catch (Exception e) {
            System.debug('Error in syncToNativeActionPlans: ' + e.getMessage());
            throw e;
        }
    }
    
    private static List<Custom_Action_Plan__c> queryCustomActionPlans(List<Id> planIds) {
        return [
            SELECT Id, External_Reference_Id__c, Status__c, 
                   Submitted_By_Email__c, Submitted_By_Name__c,
                   Related_Record_Id__c, Related_Object_Type__c,
                   Native_Action_Plan_Id__c,
                   (SELECT Id, Name, Description__c, Due_Date__c,
                           Priority__c, Category__c, Assigned_To_Email__c,
                           Days_After_Start__c, Is_Required__c,
                           Task_Order__c
                    FROM Custom_Tasks__r
                    ORDER BY Task_Order__c)
            FROM Custom_Action_Plan__c
            WHERE Id IN :planIds
            AND Sync_Status__c != 'Completed'
        ];
    }
    
    private static void processActionPlan(Custom_Action_Plan__c customPlan) {
        Savepoint sp = Database.setSavepoint();
        
        try {
            // Update sync status
            customPlan.Sync_Status__c = 'In Progress';
            update customPlan;
            
            // Find or create related record
            Id targetRecordId = findOrCreateTargetRecord(customPlan);
            
            // Get action plan template (if exists)
            Id templateId = findBestMatchingTemplate(customPlan);
            
            // Create native Action Plan
            ActionPlan nativeActionPlan = createNativeActionPlan(
                customPlan, 
                targetRecordId, 
                templateId
            );
            insert nativeActionPlan;
            
            // Create native Action Plan Tasks
            List<ActionPlanTask> nativeTasks = createNativeActionPlanTasks(
                nativeActionPlan.Id,
                customPlan.Custom_Tasks__r
            );
            
            if (!nativeTasks.isEmpty()) {
                insert nativeTasks;
            }
            
            // Update custom action plan with reference
            customPlan.Native_Action_Plan_Id__c = nativeActionPlan.Id;
            customPlan.Status__c = 'Synced';
            customPlan.Sync_Status__c = 'Completed';
            update customPlan;
            
            // Log success
            logSyncSuccess(customPlan, nativeActionPlan);
            
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }
    
    private static Id findOrCreateTargetRecord(Custom_Action_Plan__c customPlan) {
        // If we have a related record ID, validate and return it
        if (String.isNotBlank(customPlan.Related_Record_Id__c)) {
            return validateAndGetRecordId(
                customPlan.Related_Record_Id__c, 
                customPlan.Related_Object_Type__c
            );
        }
        
        // Otherwise, find or create a Lead/Contact based on email
        return findOrCreateLeadFromEmail(
            customPlan.Submitted_By_Email__c,
            customPlan.Submitted_By_Name__c
        );
    }
    
    private static Id validateAndGetRecordId(String recordId, String objectType) {
        // Validate the record exists and is of correct type
        try {
            String query = 'SELECT Id FROM ' + String.escapeSingleQuotes(objectType) + 
                          ' WHERE Id = :recordId LIMIT 1';
            List<SObject> records = Database.query(query);
            
            if (!records.isEmpty()) {
                return records[0].Id;
            }
        } catch (Exception e) {
            System.debug('Invalid record reference: ' + e.getMessage());
        }
        
        return null;
    }
    
    private static Id findOrCreateLeadFromEmail(String email, String name) {
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
        Lead newLead = new Lead(
            Email = email,
            LastName = String.isNotBlank(name) ? name : 'Guest User',
            Company = 'Guest Submission',
            LeadSource = 'Web',
            Status = 'New'
        );
        
        // Parse name if provided
        if (String.isNotBlank(name) && name.contains(' ')) {
            List<String> nameParts = name.split(' ', 2);
            newLead.FirstName = nameParts[0];
            newLead.LastName = nameParts[1];
        }
        
        insert newLead;
        return newLead.Id;
    }
    
    private static Id findBestMatchingTemplate(Custom_Action_Plan__c customPlan) {
        // Query available Action Plan Templates
        List<ActionPlanTemplate> templates = [
            SELECT Id, Name, Description
            FROM ActionPlanTemplate
            WHERE IsActive = true
            LIMIT 100
        ];
        
        // Simple matching logic - can be enhanced
        for (ActionPlanTemplate template : templates) {
            if (template.Name.containsIgnoreCase('Guest') || 
                template.Name.containsIgnoreCase('External')) {
                return template.Id;
            }
        }
        
        // Return first template if no match
        return !templates.isEmpty() ? templates[0].Id : null;
    }
    
    private static ActionPlan createNativeActionPlan(
        Custom_Action_Plan__c customPlan, 
        Id targetRecordId,
        Id templateId
    ) {
        ActionPlan ap = new ActionPlan();
        ap.Name = 'Guest Plan: ' + customPlan.External_Reference_Id__c;
        ap.StartDate = Date.today();
        ap.TargetId = targetRecordId;
        
        if (templateId != null) {
            ap.ActionPlanTemplateId = templateId;
        }
        
        // Set other fields as available in your org
        // ap.Description = 'Created from guest submission';
        
        return ap;
    }
    
    private static List<ActionPlanTask> createNativeActionPlanTasks(
        Id actionPlanId,
        List<Custom_Task__c> customTasks
    ) {
        List<ActionPlanTask> tasks = new List<ActionPlanTask>();
        
        for (Custom_Task__c customTask : customTasks) {
            ActionPlanTask apt = new ActionPlanTask();
            apt.ActionPlanId = actionPlanId;
            apt.Subject = customTask.Name;
            apt.Description = customTask.Description__c;
            apt.Priority = mapPriority(customTask.Priority__c);
            apt.IsRequired = customTask.Is_Required__c;
            
            // Calculate due date based on days after start
            if (customTask.Days_After_Start__c != null) {
                apt.DaysFromStart = Integer.valueOf(customTask.Days_After_Start__c);
            } else if (customTask.Due_Date__c != null) {
                Integer daysDiff = Date.today().daysBetween(customTask.Due_Date__c);
                apt.DaysFromStart = daysDiff > 0 ? daysDiff : 0;
            }
            
            // Map assigned user if internal
            apt.AssignedToId = findInternalUser(customTask.Assigned_To_Email__c);
            
            tasks.add(apt);
        }
        
        return tasks;
    }
    
    private static String mapPriority(String customPriority) {
        Map<String, String> priorityMap = new Map<String, String>{
            'High' => 'High',
            'Medium' => 'Normal',
            'Low' => 'Low'
        };
        
        return priorityMap.containsKey(customPriority) ? 
               priorityMap.get(customPriority) : 'Normal';
    }
    
    private static Id findInternalUser(String email) {
        if (String.isBlank(email)) {
            return UserInfo.getUserId(); // Default to current user
        }
        
        List<User> users = [
            SELECT Id 
            FROM User 
            WHERE Email = :email 
            AND IsActive = true
            LIMIT 1
        ];
        
        return !users.isEmpty() ? users[0].Id : UserInfo.getUserId();
    }
    
    private static void handleSyncError(Custom_Action_Plan__c customPlan, Exception e) {
        customPlan.Status__c = 'Failed';
        customPlan.Sync_Status__c = 'Error';
        customPlan.Error_Message__c = 'Sync failed: ' + e.getMessage();
        
        update customPlan;
        
        // Log error
        insert new Action_Plan_Submission_Log__c(
            Custom_Action_Plan__c = customPlan.Id,
            Event_Type__c = 'Failed',
            Event_Date__c = System.now(),
            Details__c = 'Error: ' + e.getMessage() + '\n' + e.getStackTraceString()
        );
    }
    
    private static void logSyncSuccess(Custom_Action_Plan__c customPlan, ActionPlan nativeAP) {
        insert new Action_Plan_Submission_Log__c(
            Custom_Action_Plan__c = customPlan.Id,
            Event_Type__c = 'Synced',
            Event_Date__c = System.now(),
            Details__c = 'Successfully synced to native Action Plan: ' + nativeAP.Id
        );
    }
}