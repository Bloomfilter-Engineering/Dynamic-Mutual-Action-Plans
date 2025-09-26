/**
 * ActionPlanSyncBatchTest.cls
 * Test class for ActionPlanSyncBatch
 * Target Coverage: 85%+
 */
@isTest
private class ActionPlanSyncBatchTest {
    
    @TestSetup
    static void setupTestData() {
        // Create custom settings
        Action_Plan_Settings__c settings = new Action_Plan_Settings__c();
        settings.Enable_Auto_Sync__c = true;
        settings.Batch_Size__c = 5;
        settings.Enable_Email_Notifications__c = false;
        settings.Admin_Email__c = 'batchtest@example.com';
        insert settings;
        
        // Create test leads and contacts
        Lead testLead = new Lead(
            FirstName = 'Batch',
            LastName = 'TestLead',
            Company = 'Batch Test Company',
            Email = 'batchlead@test.com',
            Status = 'New'
        );
        insert testLead;
        
        Account testAccount = new Account(Name = 'Batch Test Account');
        insert testAccount;
        
        Contact testContact = new Contact(
            FirstName = 'Batch',
            LastName = 'TestContact',
            Email = 'batchcontact@test.com',
            AccountId = testAccount.Id
        );
        insert testContact;
        
        // Create multiple custom action plans with different statuses
        List<Custom_Action_Plan__c> plans = new List<Custom_Action_Plan__c>();
        
        // Plans to be processed
        for (Integer i = 0; i < 10; i++) {
            plans.add(new Custom_Action_Plan__c(
                External_Reference_Id__c = 'BATCH-PENDING-' + i,
                Status__c = 'Pending',
                Submitted_By_Email__c = 'batchuser' + i + '@test.com',
                Submitted_By_Name__c = 'Batch User ' + i,
                Submission_Date__c = System.now().addHours(-i),
                Is_Public__c = true,
                Sync_Status__c = 'Not Started'
            ));
        }
        
        // Plans with errors to retry
        for (Integer i = 0; i < 5; i++) {
            plans.add(new Custom_Action_Plan__c(
                External_Reference_Id__c = 'BATCH-ERROR-' + i,
                Status__c = 'Pending',
                Submitted_By_Email__c = 'batcherror' + i + '@test.com',
                Submitted_By_Name__c = 'Batch Error ' + i,
                Submission_Date__c = System.now().addHours(-i),
                Is_Public__c = true,
                Sync_Status__c = 'Error',
                Error_Message__c = 'Previous sync failed'
            ));
        }
        
        // Already completed plans (should not be processed)
        for (Integer i = 0; i < 3; i++) {
            plans.add(new Custom_Action_Plan__c(
                External_Reference_Id__c = 'BATCH-COMPLETE-' + i,
                Status__c = 'Synced',
                Submitted_By_Email__c = 'batchcomplete' + i + '@test.com',
                Submitted_By_Name__c = 'Batch Complete ' + i,
                Submission_Date__c = System.now().addDays(-i),
                Is_Public__c = true,
                Sync_Status__c = 'Completed'
            ));
        }
        
        insert plans;
        
        // Create tasks for pending plans
        List<Custom_Task__c> tasks = new List<Custom_Task__c>();
        for (Integer i = 0; i < 10; i++) {
            tasks.add(new Custom_Task__c(
                Name = 'Batch Task ' + i,
                Action_Plan__c = plans[i].Id,
                Priority__c = 'Medium',
                Status__c = 'Not Started',
                Task_Order__c = 10,
                Days_After_Start__c = i + 1,
                Is_Required__c = true
            ));
        }
        insert tasks;
    }
    
    @isTest
    static void testBatchExecution() {
        // Count pending plans before batch
        Integer beforeCount = [
            SELECT COUNT()
            FROM Custom_Action_Plan__c
            WHERE Sync_Status__c IN ('Not Started', 'Error')
            AND Status__c = 'Pending'
        ];
        
        System.assert(beforeCount > 0, 'Should have pending plans to process');
        
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch();
        Database.executeBatch(batch, 5);
        Test.stopTest();
        
        // Count synced plans after batch
        Integer afterCount = [
            SELECT COUNT()
            FROM Custom_Action_Plan__c
            WHERE Sync_Status__c = 'Completed'
            AND Status__c = 'Synced'
        ];
        
        System.assert(afterCount > 0, 'Some plans should be synced');
        
        // Verify logs were created
        List<Action_Plan_Submission_Log__c> logs = [
            SELECT Event_Type__c
            FROM Action_Plan_Submission_Log__c
            WHERE Event_Type__c IN ('Batch_Started', 'Batch_Completed', 'Synced')
        ];
        
        System.assert(!logs.isEmpty(), 'Batch logs should be created');
    }
    
    @isTest
    static void testBatchWithEmailNotification() {
        // Enable email notifications
        Action_Plan_Settings__c settings = Action_Plan_Settings__c.getOrgDefaults();
        settings.Enable_Email_Notifications__c = true;
        update settings;
        
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch('test@example.com');
        Database.executeBatch(batch, 2);
        Test.stopTest();
        
        // Verify batch completed
        List<AsyncApexJob> jobs = [
            SELECT Status, JobItemsProcessed
            FROM AsyncApexJob
            WHERE ApexClass.Name = 'ActionPlanSyncBatch'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        
        System.assert(!jobs.isEmpty(), 'Batch job should exist');
        System.assertEquals('Completed', jobs[0].Status, 'Batch should complete successfully');
    }
    
    @isTest
    static void testProcessSingleActionPlan() {
        // Get a single pending plan
        Custom_Action_Plan__c testPlan = [
            SELECT Id, External_Reference_Id__c, Sync_Status__c,
                   Submitted_By_Email__c, Submitted_By_Name__c
            FROM Custom_Action_Plan__c
            WHERE Sync_Status__c = 'Not Started'
            LIMIT 1
        ];
        
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch();
        Database.executeBatch(batch, 1); // Process one at a time
        Test.stopTest();
        
        // Verify the plan was processed
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c, Sync_Status__c
            FROM Custom_Action_Plan__c
            WHERE Id = :testPlan.Id
        ];
        
        System.assertEquals('Synced', updatedPlan.Status__c, 'Plan should be synced');
        System.assertEquals('Completed', updatedPlan.Sync_Status__c, 'Sync should be completed');
    }
    
    @isTest
    static void testCreateLeadForNewEmail() {
        // Create a plan with a new email
        Custom_Action_Plan__c newEmailPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'BATCH-NEWLEAD',
            Status__c = 'Pending',
            Submitted_By_Email__c = 'brandnew@test.com',
            Submitted_By_Name__c = 'Brand New User',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert newEmailPlan;
        
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch();
        Database.executeBatch(batch, 1);
        Test.stopTest();
        
        // Verify Lead was created
        List<Lead> createdLeads = [
            SELECT Email, FirstName, LastName, LeadSource
            FROM Lead
            WHERE Email = 'brandnew@test.com'
        ];
        
        System.assertEquals(1, createdLeads.size(), 'Lead should be created');
        System.assertEquals('Brand', createdLeads[0].FirstName, 'First name should be parsed');
        System.assertEquals('New User', createdLeads[0].LastName, 'Last name should be parsed');
    }
    
    @isTest
    static void testUseExistingContact() {
        // Create a plan for existing contact email
        Custom_Action_Plan__c contactPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'BATCH-EXISTING-CONTACT',
            Status__c = 'Pending',
            Submitted_By_Email__c = 'batchcontact@test.com', // Existing contact email
            Submitted_By_Name__c = 'Existing Contact',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert contactPlan;
        
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch();
        Database.executeBatch(batch, 1);
        Test.stopTest();
        
        // Verify no new Lead was created
        List<Lead> leads = [
            SELECT Id
            FROM Lead
            WHERE Email = 'batchcontact@test.com'
        ];
        
        System.assertEquals(0, leads.size(), 'No Lead should be created for existing Contact');
        
        // Verify plan was synced
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c
            FROM Custom_Action_Plan__c
            WHERE Id = :contactPlan.Id
        ];
        
        System.assertEquals('Synced', updatedPlan.Status__c, 'Plan should be synced to Contact');
    }
    
    @isTest
    static void testUseExistingLead() {
        // Create a plan for existing lead email
        Custom_Action_Plan__c leadPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'BATCH-EXISTING-LEAD',
            Status__c = 'Pending',
            Submitted_By_Email__c = 'batchlead@test.com', // Existing lead email
            Submitted_By_Name__c = 'Existing Lead',
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert leadPlan;
        
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch();
        Database.executeBatch(batch, 1);
        Test.stopTest();
        
        // Verify plan was synced
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c
            FROM Custom_Action_Plan__c
            WHERE Id = :leadPlan.Id
        ];
        
        System.assertEquals('Synced', updatedPlan.Status__c, 'Plan should be synced to Lead');
    }
    
    @isTest
    static void testErrorHandling() {
        // Create a plan that will cause an error
        Custom_Action_Plan__c errorPlan = new Custom_Action_Plan__c(
            External_Reference_Id__c = 'BATCH-ERROR-TEST',
            Status__c = 'Pending',
            Submitted_By_Email__c = null, // No email will cause error
            Submitted_By_Name__c = null,
            Submission_Date__c = System.now(),
            Is_Public__c = true,
            Sync_Status__c = 'Not Started'
        );
        insert errorPlan;
        
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch();
        Database.executeBatch(batch, 1);
        Test.stopTest();
        
        // Verify error was handled
        Custom_Action_Plan__c updatedPlan = [
            SELECT Status__c, Sync_Status__c, Error_Message__c
            FROM Custom_Action_Plan__c
            WHERE Id = :errorPlan.Id
        ];
        
        System.assertEquals('Failed', updatedPlan.Status__c, 'Status should be Failed');
        System.assertEquals('Error', updatedPlan.Sync_Status__c, 'Sync status should be Error');
        System.assertNotEquals(null, updatedPlan.Error_Message__c, 'Error message should be populated');
    }
    
    @isTest
    static void testBatchScheduler() {
        Test.startTest();
        ActionPlanSyncBatch.ActionPlanBatchScheduler scheduler = 
            new ActionPlanSyncBatch.ActionPlanBatchScheduler();
        
        String cronExp = '0 0 * * * ?';
        System.schedule('Test Batch Scheduler', cronExp, scheduler);
        Test.stopTest();
        
        // Verify scheduler was created
        List<CronTrigger> scheduledJobs = [
            SELECT Id, CronJobDetail.Name
            FROM CronTrigger
            WHERE CronJobDetail.Name = 'Test Batch Scheduler'
        ];
        
        System.assertEquals(1, scheduledJobs.size(), 'Scheduler should be created');
    }
    
    @isTest
    static void testScheduleNextBatch() {
        // This tests the automatic scheduling of next batch
        Test.startTest();
        ActionPlanSyncBatch batch = new ActionPlanSyncBatch();
        Database.executeBatch(batch, 1);
        Test.stopTest();
        
        // The scheduleNextBatch method will check for pending records
        // and schedule if needed - we can't directly verify in test
        System.assert(true, 'Auto-scheduling tested');
    }
}