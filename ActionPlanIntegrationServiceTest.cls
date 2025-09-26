/**
 * ActionPlanIntegrationServiceTest.cls
 * Test class for ActionPlanIntegrationService
 * Target Coverage: 85%+
 */
@isTest
private class ActionPlanIntegrationServiceTest {
    
    @TestSetup
    static void setupTestData() {
        // Create custom settings
        Action_Plan_Settings__c settings = new Action_Plan_Settings__c();
        settings.Enable_Auto_Sync__c = true;
        settings.Rate_Limit_Per_Hour__c = 5;
        settings.Max_Tasks_Per_Plan__c = 20;
        settings.Batch_Size__c = 50;
        settings.Enable_Email_Notifications__c = true;
        settings.Admin_Email__c = 'test@example.com';
        insert settings;
        
        // Create test Lead
        Lead testLead = new Lead(
            FirstName = 'Test',
            LastName = 'Lead',
            Company = 'Test Company',
            Email = 'testlead@example.com',
            Status = 'New',
            LeadSource = 'Web'
        );
        insert testLead;
        
        // Create test Contact
        Account testAccount = new Account(Name = 'Test Account');
        insert testAccount;
        
        Contact testContact = new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            Email = 'testcontact@example.com',
            AccountId = testAccount.Id
        );
        insert testContact;
        
        // Create Action Plan Template (if available in org)
        try {
            // This will only work if Action Plans are enabled
            ActionPlanTemplate template = new ActionPlanTemplate(
                Name = 'Guest Submission Template',
                IsActive = true
            );
            insert template;
        } catch (Exception e) {
            // Action Plans not enabled, skip template creation
            System.debug('Action Plan Templates not available: ' + e.getMessage());
        }
    }
    
    @isTest
    static void testSyncToNativeActionPlansSuccess() {
        // Create custom action plan
        Custom_Action_Plan__c customPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'EXT-TEST-001',
            Status__c = 'Pending',
            Submitted_By_Email__c = 'newuser@example.com',
            Submitted_By_Name__c = 'New User',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert customPlan;
        
        // Create custom tasks
        List<Custom_Task__c> customTasks = new List<Custom_Task__c>{
            new Custom_Task__c(
                Name = 'Test Task 1',
                Description__c = 'Description 1',
                Action_Plan__c = customPlan.Id,
                Due_Date__c = Date.today().addDays(7),
                Priority__c = 'High',
                Status__c = 'Not Started',
                Task_Order__c = 10,
                Category__c = 'Follow-up',
                Days_After_Start__c = 7,
                Is_Required__c = true
            ),
            new Custom_Task__c(
                Name = 'Test Task 2',
                Description__c = 'Description 2',
                Action_Plan__c = customPlan.Id,
                Due_Date__c = Date.today().addDays(14),
                Priority__c = 'Medium',
                Status__c = 'Not Started',
                Task_Order__c = 20,
                Category__c = 'Documentation',
                Days_After_Start__c = 14,
                Is_Required__c = false
            )
        };
        insert customTasks;
        
        Test.startTest();
        ActionPlanIntegrationService.syncToNativeActionPlans(new List<Id>{customPlan.Id});
        Test.stopTest();
        
        // Verify sync completed
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c, Sync_Status__c, Native_Action_Plan_Id__c
            FROM Custom_Action_Plan__c
            WHERE Id = :customPlan.Id
        ];
        
        System.assertEquals('Synced', updatedPlan.Status__c, 'Status should be Synced');
        System.assertEquals('Completed', updatedPlan.Sync_Status__c, 'Sync status should be Completed');
        
        // Verify Lead was created for new email
        List<Lead> createdLeads = [
            SELECT Id, Email, LastName
            FROM Lead
            WHERE Email = 'newuser@example.com'
        ];
        System.assertEquals(1, createdLeads.size(), 'Lead should be created for new email');
        
        // Verify logs were created
        List<Action_Plan_Submission_Log__c> logs = [
            SELECT Event_Type__c
            FROM Action_Plan_Submission_Log__c
            WHERE Custom_Action_Plan__c = :customPlan.Id
        ];
        System.assert(!logs.isEmpty(), 'Logs should be created');
    }
    
    @isTest
    static void testSyncWithExistingContact() {
        // Get test contact
        Contact testContact = [SELECT Id, Email FROM Contact WHERE Email = 'testcontact@example.com' LIMIT 1];
        
        // Create custom action plan for existing contact
        Custom_Action_Plan__c customPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'EXT-TEST-002',
            Status__c = 'Pending',
            Submitted_By_Email__c = testContact.Email,
            Submitted_By_Name__c = 'Test Contact',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started',
            Related_Record_Id__c = testContact.Id,
            Related_Object_Type__c = 'Contact'
        );
        insert customPlan;
        
        // Create task
        Custom_Task__c customTask = new Custom_Task__c(
            Name = 'Contact Task',
            Action_Plan__c = customPlan.Id,
            Priority__c = 'Low',
            Status__c = 'Not Started',
            Task_Order__c = 10,
            Days_After_Start__c = 1,
            Is_Required__c = true
        );
        insert customTask;
        
        Test.startTest();
        ActionPlanIntegrationService.syncToNativeActionPlans(new List<Id>{customPlan.Id});
        Test.stopTest();
        
        // Verify sync completed
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c, Sync_Status__c
            FROM Custom_Action_Plan__c
            WHERE Id = :customPlan.Id
        ];
        
        System.assertEquals('Synced', updatedPlan.Status__c, 'Status should be Synced');
        
        // Verify no new Lead was created
        List<Lead> leads = [
            SELECT Id
            FROM Lead
            WHERE Email = :testContact.Email
        ];
        System.assertEquals(0, leads.size(), 'No Lead should be created for existing Contact');
    }
    
    @isTest
    static void testSyncWithExistingLead() {
        // Get test lead
        Lead testLead = [SELECT Id, Email FROM Lead WHERE Email = 'testlead@example.com' LIMIT 1];
        
        // Create custom action plan for existing lead
        Custom_Action_Plan__c customPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'EXT-TEST-003',
            Status__c = 'Pending',
            Submitted_By_Email__c = testLead.Email,
            Submitted_By_Name__c = 'Test Lead',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert customPlan;
        
        Test.startTest();
        ActionPlanIntegrationService.syncToNativeActionPlans(new List<Id>{customPlan.Id});
        Test.stopTest();
        
        // Verify sync completed
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c, Sync_Status__c
            FROM Custom_Action_Plan__c
            WHERE Id = :customPlan.Id
        ];
        
        System.assertEquals('Synced', updatedPlan.Status__c, 'Status should be Synced');
    }
    
    @isTest
    static void testSyncFailureHandling() {
        // Create custom action plan with invalid data
        Custom_Action_Plan__c customPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'EXT-TEST-FAIL',
            Status__c = 'Pending',
            Submitted_By_Email__c = null, // Invalid - no email
            Submitted_By_Name__c = null,
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert customPlan;
        
        Test.startTest();
        try {
            ActionPlanIntegrationService.syncToNativeActionPlans(new List<Id>{customPlan.Id});
        } catch (Exception e) {
            // Expected exception
            System.debug('Expected exception: ' + e.getMessage());
        }
        Test.stopTest();
        
        // Verify error was logged
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c, Sync_Status__c, Error_Message__c
            FROM Custom_Action_Plan__c
            WHERE Id = :customPlan.Id
        ];
        
        System.assertEquals('Failed', updatedPlan.Status__c, 'Status should be Failed');
        System.assertEquals('Error', updatedPlan.Sync_Status__c, 'Sync status should be Error');
        System.assertNotEquals(null, updatedPlan.Error_Message__c, 'Error message should be populated');
    }
    
    @isTest
    static void testMultiplePlansSync() {
        // Create multiple custom action plans
        List<Custom_Action_Plan__c> plans = new List<Custom_Action_Plan__c>();
        for (Integer i = 0; i < 5; i++) {
            plans.add(new Custom_Action_Plan__c(
                External_Reference_Id__c = 'EXT-BULK-' + i,
                Status__c = 'Pending',
                Submitted_By_Email__c = 'bulk' + i + '@example.com',
                Submitted_By_Name__c = 'Bulk User ' + i,
                Submission_Date__c = System.now(),
                Is_Public__c = true,
                Sync_Status__c = 'Not Started'
            ));
        }
        insert plans;
        
        // Get IDs
        List<Id> planIds = new List<Id>();
        for (Custom_Action_Plan__c plan : plans) {
            planIds.add(plan.Id);
        }
        
        Test.startTest();
        ActionPlanIntegrationService.syncToNativeActionPlans(planIds);
        Test.stopTest();
        
        // Verify all plans were processed
        List<Custom_Action_Plan__c> updatedPlans = [
            SELECT Status__c, Sync_Status__c
            FROM Custom_Action_Plan__c
            WHERE Id IN :planIds
        ];
        
        for (Custom_Action_Plan__c plan : updatedPlans) {
            System.assertEquals('Synced', plan.Status__c, 'All plans should be synced');
        }
    }
    
    @isTest
    static void testEmptyPlansList() {
        // Test with empty list
        Test.startTest();
        ActionPlanIntegrationService.syncToNativeActionPlans(new List<Id>());
        Test.stopTest();
        
        // Should not throw exception
        System.assert(true, 'Empty list should be handled gracefully');
    }
    
    @isTest
    static void testPlanWithManyTasks() {
        // Create custom action plan
        Custom_Action_Plan__c customPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'EXT-MANY-TASKS',
            Status__c = 'Pending',
            Submitted_By_Email__c = 'manytasks@example.com',
            Submitted_By_Name__c = 'Many Tasks User',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert customPlan;
        
        // Create 20 tasks (maximum allowed)
        List<Custom_Task__c> tasks = new List<Custom_Task__c>();
        for (Integer i = 1; i <= 20; i++) {
            tasks.add(new Custom_Task__c(
                Name = 'Task ' + i,
                Action_Plan__c = customPlan.Id,
                Priority__c = 'Medium',
                Status__c = 'Not Started',
                Task_Order__c = i * 10,
                Days_After_Start__c = i,
                Is_Required__c = Math.mod(i, 2) == 0
            ));
        }
        insert tasks;
        
        Test.startTest();
        ActionPlanIntegrationService.syncToNativeActionPlans(new List<Id>{customPlan.Id});
        Test.stopTest();
        
        // Verify sync completed
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c, Sync_Status__c
            FROM Custom_Action_Plan__c
            WHERE Id = :customPlan.Id
        ];
        
        System.assertEquals('Synced', updatedPlan.Status__c, 'Plan with many tasks should sync');
    }
}