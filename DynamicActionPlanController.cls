/**
 * DynamicActionPlanController.cls
 * Main controller for guest user action plan creation
 */
public without sharing class DynamicActionPlanController {
    
    // Constants
    private static final Integer MAX_TASKS_PER_PLAN = 20;
    private static final Integer RATE_LIMIT_PER_HOUR = 5;
    private static final String GUEST_USER_PROFILE = 'Guest User Profile Name';
    
    /**
     * Get available task templates for guest users
     */
    @AuraEnabled(cacheable=true)
    public static List<Task_Template__c> getTaskTemplates() {
        try {
            return [
                SELECT Id, Name, Description__c, Category__c, 
                       Default_Duration_Days__c, Display_Order__c,
                       Task_Type__c, Default_Priority__c, Instructions__c
                FROM Task_Template__c
                WHERE Is_Active__c = true
                AND Is_Public__c = true
                ORDER BY Display_Order__c NULLS LAST, Name
                LIMIT 50
            ];
        } catch (Exception e) {
            logError('getTaskTemplates', e);
            throw new AuraHandledException('Error loading templates: ' + e.getMessage());
        }
    }
    
    /**
     * Save action plan from guest user
     */
    @AuraEnabled
    public static Map<String, Object> saveActionPlan(String actionPlanJson) {
        Savepoint sp = Database.setSavepoint();
        
        try {
            // Parse and validate input
            ActionPlanWrapper wrapper = (ActionPlanWrapper) JSON.deserialize(
                actionPlanJson, 
                ActionPlanWrapper.class
            );
            
            // Security validations
            validateGuestUserAccess(wrapper);
            validateRateLimit(wrapper.submittedByEmail);
            validateInputSecurity(wrapper);
            
            // Create custom action plan
            Custom_Action_Plan__c actionPlan = createCustomActionPlan(wrapper);
            insert actionPlan;
            
            // Create custom tasks
            List<Custom_Task__c> customTasks = createCustomTasks(actionPlan.Id, wrapper.tasks);
            if (!customTasks.isEmpty()) {
                insert customTasks;
            }
            
            // Log submission
            logSubmission(actionPlan, 'Created');
            
            // Publish platform event for async processing
            publishActionPlanEvent(actionPlan, wrapper);
            
            // Return success response
            return buildSuccessResponse(actionPlan);
            
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            logError('saveActionPlan', e);
            throw new AuraHandledException('An error occurred while saving the action plan. Please try again.');
        }
    }
    
    /**
     * Get action plan status for tracking
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getActionPlanStatus(String referenceId) {
        try {
            validateReferenceId(referenceId);
            
            List<Custom_Action_Plan__c> plans = [
                SELECT Id, Status__c, External_Reference_Id__c,
                       Submission_Date__c, Sync_Status__c,
                       Native_Action_Plan_Id__c, Error_Message__c,
                       (SELECT Id, Name, Status__c, Due_Date__c, Priority__c
                        FROM Custom_Tasks__r
                        ORDER BY Task_Order__c)
                FROM Custom_Action_Plan__c
                WHERE External_Reference_Id__c = :referenceId
                AND Is_Public__c = true
                LIMIT 1
            ];
            
            if (plans.isEmpty()) {
                throw new AuraHandledException('Action plan not found');
            }
            
            return buildStatusResponse(plans[0]);
            
        } catch (Exception e) {
            logError('getActionPlanStatus', e);
            throw new AuraHandledException('Error retrieving action plan status');
        }
    }
    
    // ========== HELPER METHODS ==========
    
    private static void validateGuestUserAccess(ActionPlanWrapper wrapper) {
        // Email validation
        if (String.isBlank(wrapper.submittedByEmail)) {
            throw new AuraHandledException('Email address is required');
        }
        
        if (!isValidEmail(wrapper.submittedByEmail)) {
            throw new AuraHandledException('Please provide a valid email address');
        }
        
        // Task validation
        if (wrapper.tasks == null || wrapper.tasks.isEmpty()) {
            throw new AuraHandledException('At least one task is required');
        }
        
        if (wrapper.tasks.size() > MAX_TASKS_PER_PLAN) {
            throw new AuraHandledException('Maximum ' + MAX_TASKS_PER_PLAN + ' tasks allowed per action plan');
        }
        
        // Validate each task
        for (TaskWrapper task : wrapper.tasks) {
            if (String.isBlank(task.name)) {
                throw new AuraHandledException('All tasks must have a name');
            }
            if (task.name.length() > 255) {
                throw new AuraHandledException('Task name must be less than 255 characters');
            }
        }
    }
    
    private static void validateRateLimit(String email) {
        DateTime oneHourAgo = System.now().addHours(-1);
        
        Integer recentSubmissions = [
            SELECT COUNT()
            FROM Custom_Action_Plan__c
            WHERE Submitted_By_Email__c = :email
            AND Submission_Date__c >= :oneHourAgo
        ];
        
        if (recentSubmissions >= RATE_LIMIT_PER_HOUR) {
            throw new AuraHandledException('Rate limit exceeded. Please try again in an hour.');
        }
    }
    
    private static void validateInputSecurity(ActionPlanWrapper wrapper) {
        // XSS prevention
        wrapper.submittedByEmail = sanitizeInput(wrapper.submittedByEmail);
        wrapper.submittedByName = sanitizeInput(wrapper.submittedByName);
        
        for (TaskWrapper task : wrapper.tasks) {
            task.name = sanitizeInput(task.name);
            task.description = sanitizeInput(task.description);
            task.assignedToEmail = sanitizeInput(task.assignedToEmail);
        }
    }
    
    private static Boolean isValidEmail(String email) {
        String emailRegex = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$';
        Pattern pattern = Pattern.compile(emailRegex);
        Matcher matcher = pattern.matcher(email);
        return matcher.matches();
    }
    
    private static void validateReferenceId(String referenceId) {
        if (String.isBlank(referenceId)) {
            throw new AuraHandledException('Reference ID is required');
        }
        
        // Ensure reference ID matches expected pattern
        if (!Pattern.matches('^EXT-[0-9]+-[a-z0-9]{9}$', referenceId)) {
            throw new AuraHandledException('Invalid reference ID format');
        }
    }
    
    private static String sanitizeInput(String input) {
        if (String.isBlank(input)) return input;
        
        return input
            .escapeHtml4()
            .stripHtmlTags()
            .trim();
    }
    
    private static Custom_Action_Plan__c createCustomActionPlan(ActionPlanWrapper wrapper) {
        return new Custom_Action_Plan__c(
            External_Reference_Id__c = wrapper.referenceId,
            Status__c = 'Pending',
            Submitted_By_Email__c = wrapper.submittedByEmail,
            Submitted_By_Name__c = wrapper.submittedByName,
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started',
            Related_Record_Id__c = wrapper.relatedRecordId,
            Related_Object_Type__c = wrapper.relatedObjectType,
            IP_Address__c = wrapper.ipAddress,
            User_Agent__c = wrapper.userAgent,
            Session_Id__c = wrapper.sessionId
        );
    }
    
    private static List<Custom_Task__c> createCustomTasks(Id actionPlanId, List<TaskWrapper> taskWrappers) {
        List<Custom_Task__c> tasks = new List<Custom_Task__c>();
        Integer orderNum = 10;
        
        for (TaskWrapper taskData : taskWrappers) {
            tasks.add(new Custom_Task__c(
                Name = taskData.name,
                Description__c = taskData.description,
                Action_Plan__c = actionPlanId,
                Due_Date__c = taskData.dueDate,
                Priority__c = taskData.priority,
                Status__c = 'Not Started',
                Task_Order__c = orderNum,
                Category__c = taskData.category,
                Assigned_To_Email__c = taskData.assignedToEmail,
                External_Id__c = actionPlanId + '-' + orderNum,
                Days_After_Start__c = taskData.daysAfterStart,
                Is_Required__c = taskData.isRequired != null ? taskData.isRequired : true,
                Reminder_Days_Before__c = taskData.reminderDaysBefore
            ));
            orderNum += 10;
        }
        
        return tasks;
    }
    
    private static void publishActionPlanEvent(Custom_Action_Plan__c actionPlan, ActionPlanWrapper wrapper) {
        List<Action_Plan_Event__e> events = new List<Action_Plan_Event__e>();
        
        events.add(new Action_Plan_Event__e(
            Action_Plan_Id__c = actionPlan.Id,
            Reference_Id__c = wrapper.referenceId,
            Submitted_By__c = wrapper.submittedByEmail,
            Task_Count__c = wrapper.tasks.size(),
            Priority__c = 'Normal',
            Event_Type__c = 'New_Submission'
        ));
        
        List<Database.SaveResult> results = EventBus.publish(events);
        
        for (Database.SaveResult result : results) {
            if (!result.isSuccess()) {
                System.debug('Failed to publish event: ' + result.getErrors()[0].getMessage());
            }
        }
    }
    
    private static void logSubmission(Custom_Action_Plan__c actionPlan, String eventType) {
        insert new Action_Plan_Submission_Log__c(
            Custom_Action_Plan__c = actionPlan.Id,
            Event_Type__c = eventType,
            Event_Date__c = System.now(),
            User_Email__c = actionPlan.Submitted_By_Email__c,
            IP_Address__c = actionPlan.IP_Address__c,
            Details__c = 'Action plan created with ' + eventType + ' status'
        );
    }
    
    private static void logError(String methodName, Exception e) {
        System.debug('Error in ' + methodName + ': ' + e.getMessage());
        System.debug('Stack trace: ' + e.getStackTraceString());
    }
    
    private static Map<String, Object> buildSuccessResponse(Custom_Action_Plan__c actionPlan) {
        return new Map<String, Object>{
            'success' => true,
            'actionPlanId' => actionPlan.Id,
            'referenceId' => actionPlan.External_Reference_Id__c,
            'trackingUrl' => generateTrackingUrl(actionPlan.External_Reference_Id__c),
            'message' => 'Your action plan has been submitted successfully'
        };
    }
    
    private static Map<String, Object> buildStatusResponse(Custom_Action_Plan__c actionPlan) {
        List<Map<String, Object>> taskList = new List<Map<String, Object>>();
        
        for (Custom_Task__c task : actionPlan.Custom_Tasks__r) {
            taskList.add(new Map<String, Object>{
                'name' => task.Name,
                'status' => task.Status__c,
                'dueDate' => task.Due_Date__c,
                'priority' => task.Priority__c
            });
        }
        
        return new Map<String, Object>{
            'referenceId' => actionPlan.External_Reference_Id__c,
            'status' => actionPlan.Status__c,
            'syncStatus' => actionPlan.Sync_Status__c,
            'submissionDate' => actionPlan.Submission_Date__c,
            'tasks' => taskList,
            'nativeActionPlanId' => actionPlan.Native_Action_Plan_Id__c
        };
    }
    
    private static String generateTrackingUrl(String referenceId) {
        // Get the Experience Cloud site URL
        String baseUrl = Network.getLoginUrl(Network.getNetworkId());
        return baseUrl + '/action-plan-status?ref=' + referenceId;
    }
    
    // ========== WRAPPER CLASSES ==========
    
    public class ActionPlanWrapper {
        public String referenceId;
        public String submittedByEmail;
        public String submittedByName;
        public String relatedRecordId;
        public String relatedObjectType;
        public String ipAddress;
        public String userAgent;
        public String sessionId;
        public List<TaskWrapper> tasks;
    }
    
    public class TaskWrapper {
        public String name;
        public String description;
        public Date dueDate;
        public String priority;
        public String category;
        public String assignedToEmail;
        public Integer daysAfterStart;
        public Boolean isRequired;
        public Integer reminderDaysBefore;
    }
}