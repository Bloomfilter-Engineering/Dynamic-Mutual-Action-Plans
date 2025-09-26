/**
 * DynamicActionPlanControllerTest.cls
 * Test class for DynamicActionPlanController
 */
@isTest
private class DynamicActionPlanControllerTest {
    
    @TestSetup
    static void setupTestData() {
        // Create test task templates
        List<Task_Template__c> templates = new List<Task_Template__c>();
        
        templates.add(new Task_Template__c(
            Name = 'Follow-up Call',
            Description__c = 'Schedule a follow-up call with the customer',
            Category__c = 'Sales',
            Default_Duration_Days__c = 3,
            Is_Active__c = true,
            Is_Public__c = true,
            Display_Order__c = 10,
            Task_Type__c = 'Call',
            Default_Priority__c = 'High'
        ));
        
        templates.add(new Task_Template__c(
            Name = 'Send Documentation',
            Description__c = 'Send required documentation to customer',
            Category__c = 'Service',
            Default_Duration_Days__c = 1,
            Is_Active__c = true,
            Is_Public__c = true,
            Display_Order__c = 20,
            Task_Type__c = 'Email',
            Default_Priority__c = 'Medium'
        ));
        
        templates.add(new Task_Template__c(
            Name = 'Internal Review',
            Description__c = 'Internal review template - not public',
            Category__c = 'Operations',
            Default_Duration_Days__c = 5,
            Is_Active__c = true,
            Is_Public__c = false, // Not public
            Display_Order__c = 30,
            Task_Type__c = 'Review',
            Default_Priority__c = 'Low'
        ));
        
        insert templates;
    }
    
    @isTest
    static void testGetTaskTemplates() {
        Test.startTest();
        List<Task_Template__c> templates = DynamicActionPlanController.getTaskTemplates();
        Test.stopTest();
        
        // Should only return public templates
        System.assertEquals(2, templates.size(), 'Should return only public templates');
        
        // Verify sorting
        System.assertEquals('Follow-up Call', templates[0].Name, 'First template should be Follow-up Call');
        System.assertEquals('Send Documentation', templates[1].Name, 'Second template should be Send Documentation');
    }
    
    @isTest
    static void testSaveActionPlanSuccess() {
        // Prepare test data
        DynamicActionPlanController.ActionPlanWrapper wrapper = new DynamicActionPlanController.ActionPlanWrapper();
        wrapper.referenceId = 'EXT-123456789-abc123def';
        wrapper.submittedByEmail = 'test@example.com';
        wrapper.submittedByName = 'Test User';
        wrapper.relatedRecordId = null;
        wrapper.relatedObjectType = 'Lead';
        wrapper.ipAddress = '192.168.1.1';
        wrapper.userAgent = 'Mozilla/5.0';
        wrapper.sessionId = 'session-123';
        
        // Add tasks
        wrapper.tasks = new List<DynamicActionPlanController.TaskWrapper>();
        
        DynamicActionPlanController.TaskWrapper task1 = new DynamicActionPlanController.TaskWrapper();
        task1.name = 'Test Task 1';
        task1.description = 'Test Description 1';
        task1.dueDate = Date.today().addDays(7);
        task1.priority = 'High';
        task1.category = 'Follow-up';
        task1.assignedToEmail = 'assignee@example.com';
        task1.daysAfterStart = 7;
        task1.isRequired = true;
        task1.reminderDaysBefore = 1;
        wrapper.tasks.add(task1);
        
        DynamicActionPlanController.TaskWrapper task2 = new DynamicActionPlanController.TaskWrapper();
        task2.name = 'Test Task 2';
        task2.description = 'Test Description 2';
        task2.dueDate = Date.today().addDays(14);
        task2.priority = 'Medium';
        task2.category = 'Documentation';
        task2.assignedToEmail = null;
        task2.daysAfterStart = 14;
        task2.isRequired = false;
        task2.reminderDaysBefore = 2;
        wrapper.tasks.add(task2);
        
        Test.startTest();
        Map<String, Object> result = DynamicActionPlanController.saveActionPlan(
            JSON.serialize(wrapper)
        );
        Test.stopTest();
        
        // Verify result
        System.assertEquals(true, result.get('success'), 'Save should be successful');
        System.assertNotEquals(null, result.get('actionPlanId'), 'Should return action plan ID');
        System.assertEquals(wrapper.referenceId, result.get('referenceId'), 'Should return reference ID');
        System.assertNotEquals(null, result.get('trackingUrl'), 'Should return tracking URL');
        
        // Verify database records
        Custom_Action_Plan__c savedPlan = [
            SELECT Id, External_Reference_Id__c, Status__c, Submitted_By_Email__c,
                   (SELECT Id FROM Custom_Tasks__r)
            FROM Custom_Action_Plan__c
            WHERE External_Reference_Id__c = :wrapper.referenceId
        ];
        
        System.assertEquals('Pending', savedPlan.Status__c, 'Status should be Pending');
        System.assertEquals(2, savedPlan.Custom_Tasks__r.size(), 'Should have 2 tasks');
        
        // Verify platform event was published
        System.assertEquals(1, Limits.getPublishImmediateDML(), 'Platform event should be published');
    }
    
    @isTest
    static void testSaveActionPlanValidationErrors() {
        // Test missing email
        DynamicActionPlanController.ActionPlanWrapper wrapper1 = new DynamicActionPlanController.ActionPlanWrapper();
        wrapper1.referenceId = 'EXT-123456789-abc123def';
        wrapper1.submittedByEmail = ''; // Missing email
        wrapper1.submittedByName = 'Test User';
        wrapper1.tasks = new List<DynamicActionPlanController.TaskWrapper>();
        
        Boolean exceptionThrown = false;
        try {
            DynamicActionPlanController.saveActionPlan(JSON.serialize(wrapper1));
        } catch (AuraHandledException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Email'), 'Error should mention email');
        }
        System.assert(exceptionThrown, 'Exception should be thrown for missing email');
        
        // Test invalid email format
        DynamicActionPlanController.ActionPlanWrapper wrapper2 = new DynamicActionPlanController.ActionPlanWrapper();
        wrapper2.referenceId = 'EXT-123456789-abc123def';
        wrapper2.submittedByEmail = 'invalid-email'; // Invalid format
        wrapper2.submittedByName = 'Test User';
        wrapper2.tasks = new List<DynamicActionPlanController.TaskWrapper>();
        
        exceptionThrown = false;
        try {
            DynamicActionPlanController.saveActionPlan(JSON.serialize(wrapper2));
        } catch (AuraHandledException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('valid email'), 'Error should mention valid email');
        }
        System.assert(exceptionThrown, 'Exception should be thrown for invalid email');
        
        // Test no tasks
        DynamicActionPlanController.ActionPlanWrapper wrapper3 = new DynamicActionPlanController.ActionPlanWrapper();
        wrapper3.referenceId = 'EXT-123456789-abc123def';
        wrapper3.submittedByEmail = 'test@example.com';
        wrapper3.submittedByName = 'Test User';
        wrapper3.tasks = new List<DynamicActionPlanController.TaskWrapper>(); // Empty tasks
        
        exceptionThrown = false;
        try {
            DynamicActionPlanController.saveActionPlan(JSON.serialize(wrapper3));
        } catch (AuraHandledException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('task'), 'Error should mention task');
        }
        System.assert(exceptionThrown, 'Exception should be thrown for no tasks');
        
        // Test too many tasks
        DynamicActionPlanController.ActionPlanWrapper wrapper4 = new DynamicActionPlanController.ActionPlanWrapper();
        wrapper4.referenceId = 'EXT-123456789-abc123def';
        wrapper4.submittedByEmail = 'test@example.com';
        wrapper4.submittedByName = 'Test User';
        wrapper4.tasks = new List<DynamicActionPlanController.TaskWrapper>();
        
        // Add 21 tasks (exceeds limit of 20)
        for (Integer i = 0; i < 21; i++) {
            DynamicActionPlanController.TaskWrapper task = new DynamicActionPlanController.TaskWrapper();
            task.name = 'Task ' + i;
            task.priority = 'Medium';
            wrapper4.tasks.add(task);
        }
        
        exceptionThrown = false;
        try {
            DynamicActionPlanController.saveActionPlan(JSON.serialize(wrapper4));
        } catch (AuraHandledException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Maximum'), 'Error should mention maximum');
        }
        System.assert(exceptionThrown, 'Exception should be thrown for too many tasks');
    }
    
    @isTest
    static void testRateLimiting() {
        String testEmail = 'ratelimit@example.com';
        
        // Create 5 action plans (at the limit)
        for (Integer i = 0; i < 5; i++) {
            Custom_Action_Plan__c plan = new Custom_Action_Plan__c(
                External_Reference_Id__c = 'EXT-RATE-' + i,
                Status__c = 'Pending',
                Submitted_By_Email__c = testEmail,
                Submission_Date__c = System.now(),
                Is_Public__c = true
            );
            insert plan;
        }
        
        // Try to create one more
        DynamicActionPlanController.ActionPlanWrapper wrapper = new DynamicActionPlanController.ActionPlanWrapper();
        wrapper.referenceId = 'EXT-RATE-EXCEEDED';
        wrapper.submittedByEmail = testEmail;
        wrapper.submittedByName = 'Test User';
        wrapper.tasks = new List<DynamicActionPlanController.TaskWrapper>();
        
        DynamicActionPlanController.TaskWrapper task = new DynamicActionPlanController.TaskWrapper();
        task.name = 'Test Task';
        task.priority = 'Medium';
        wrapper.tasks.add(task);
        
        Boolean rateLimitHit = false;
        Test.startTest();
        try {
            DynamicActionPlanController.saveActionPlan(JSON.serialize(wrapper));
        } catch (AuraHandledException e) {
            rateLimitHit = true;
            System.assert(e.getMessage().contains('Rate limit'), 'Error should mention rate limit');
        }
        Test.stopTest();
        
        System.assert(rateLimitHit, 'Rate limit should be enforced');
    }
    
    @isTest
    static void testGetActionPlanStatus() {
        // Create test action plan with tasks
        Custom_Action_Plan__c plan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'EXT-STATUS-TEST',
            Status__c = 'Pending',
            Submitted_By_Email__c = 'status@example.com',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert plan;
        
        List<Custom_Task__c> tasks = new List<Custom_Task__c>();
        tasks.add(new Custom_Task__c(
            Name = 'Task 1',
            Action_Plan__c = plan.Id,
            Status__c = 'Not Started',
            Priority__c = 'High',
            Task_Order__c = 10
        ));
        tasks.add(new Custom_Task__c(
            Name = 'Task 2',
            Action_Plan__c = plan.Id,
            Status__c = 'In Progress',
            Priority__c = 'Medium',
            Task_Order__c = 20
        ));
        insert tasks;
        
        Test.startTest();
        Map<String, Object> result = DynamicActionPlanController.getActionPlanStatus('EXT-STATUS-TEST');
        Test.stopTest();
        
        System.assertEquals('EXT-STATUS-TEST', result.get('referenceId'), 'Should return correct reference ID');
        System.assertEquals('Pending', result.get('status'), 'Should return correct status');
        System.assertEquals('Not Started', result.get('syncStatus'), 'Should return correct sync status');
        
        List<Object> taskList = (List<Object>) result.get('tasks');
        System.assertEquals(2, taskList.size(), 'Should return 2 tasks');
    }
    
    @isTest
    static void testGetActionPlanStatusNotFound() {
        Boolean exceptionThrown = false;
        
        Test.startTest();
        try {
            DynamicActionPlanController.getActionPlanStatus('EXT-NONEXISTENT');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('not found'), 'Error should mention not found');
        }
        Test.stopTest();
        
        System.assert(exceptionThrown, 'Exception should be thrown for non-existent plan');
    }
    
    @isTest
    static void testInputSanitization() {
        // Test XSS prevention in input
        DynamicActionPlanController.ActionPlanWrapper wrapper = new DynamicActionPlanController.ActionPlanWrapper();
        wrapper.referenceId = 'EXT-XSS-TEST';
        wrapper.submittedByEmail = 'xss@example.com';
        wrapper.submittedByName = '<script>alert("XSS")</script>';
        wrapper.tasks = new List<DynamicActionPlanController.TaskWrapper>();
        
        DynamicActionPlanController.TaskWrapper task = new DynamicActionPlanController.TaskWrapper();
        task.name = '<img src=x onerror=alert("XSS")>';
        task.description = '<script>alert("XSS")</script>';
        task.priority = 'High';
        wrapper.tasks.add(task);
        
        Test.startTest();
        Map<String, Object> result = DynamicActionPlanController.saveActionPlan(
            JSON.serialize(wrapper)
        );
        Test.stopTest();
        
        // Verify sanitization
        Custom_Action_Plan__c savedPlan = [
            SELECT Submitted_By_Name__c
            FROM Custom_Action_Plan__c
            WHERE External_Reference_Id__c = 'EXT-XSS-TEST'
        ];
        
        System.assertNotEquals(wrapper.submittedByName, savedPlan.Submitted_By_Name__c, 
                              'Name should be sanitized');
        System.assert(!savedPlan.Submitted_By_Name__c.contains('<script>'), 
                     'Script tags should be removed');
        
        Custom_Task__c savedTask = [
            SELECT Name, Description__c
            FROM Custom_Task__c
            WHERE Action_Plan__c = :savedPlan.Id
            LIMIT 1
        ];
        
        System.assert(!savedTask.Name.contains('<img'), 'HTML tags should be removed from task name');
        System.assert(!savedTask.Description__c.contains('<script>'), 'Script tags should be removed from description');
    }
}