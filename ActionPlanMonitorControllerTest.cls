@IsTest
private class ActionPlanMonitorControllerTest {
    
    @testSetup
    static void setupData() {
        // Insert a variety of Action Plans across statuses and dates
        List<Custom_Action_Plan__c> plans = new List<Custom_Action_Plan__c>();
        DateTime now = System.now();
        
        for (Integer i = 0; i < 5; i++) {
            plans.add(new Custom_Action_Plan__c(
                Status__c = 'Pending',
                Sync_Status__c = 'Not Started',
                Submission_Date__c = now.addDays(-i),
                Processing_Time_Minutes__c = 0,
                External_Reference_Id__c = 'EXT-1731542400000-abcdef123'
            ));
        }
        for (Integer i = 0; i < 3; i++) {
            plans.add(new Custom_Action_Plan__c(
                Status__c = 'Processing',
                Sync_Status__c = 'In Progress',
                Submission_Date__c = now.addDays(-i-1),
                Processing_Time_Minutes__c = 5 + i,
                External_Reference_Id__c = 'EXT-1731542400001-abcdef124'
            ));
        }
        for (Integer i = 0; i < 4; i++) {
            plans.add(new Custom_Action_Plan__c(
                Status__c = 'Synced',
                Sync_Status__c = 'Complete',
                Submission_Date__c = now.addDays(-i-2),
                Processing_Time_Minutes__c = 10 + i,
                External_Reference_Id__c = 'EXT-1731542400002-abcdef125'
            ));
        }
        for (Integer i = 0; i < 2; i++) {
            plans.add(new Custom_Action_Plan__c(
                Status__c = 'Failed',
                Sync_Status__c = 'Error',
                Submission_Date__c = now.addDays(-i-3),
                Processing_Time_Minutes__c = 1,
                External_Reference_Id__c = 'EXT-1731542400003-abcdef126'
            ));
        }
        insert plans;
    }
    
    @IsTest
    static void testGetMonitoringData_All() {
        Test.startTest();
        Map<String, Object> data = ActionPlanMonitorController.getMonitoringData(30, 'all');
        Test.stopTest();
        
        System.assertNotEquals(null, data, 'Should return a result map');
        System.assert(data.containsKey('metrics'), 'Has metrics');
        System.assert(data.containsKey('charts'), 'Has charts');
        System.assert(data.containsKey('recentSubmissions'), 'Has recent submissions');
        System.assert(data.containsKey('failedSubmissions'), 'Has failed submissions');
    }
    
    @IsTest
    static void testGetMonitoringData_Filtered() {
        Test.startTest();
        Map<String, Object> data = ActionPlanMonitorController.getMonitoringData(7, 'Synced');
        Test.stopTest();
        System.assertNotEquals(null, data);
    }
    
    @IsTest
    static void testProcessPendingPlans_NoPending() {
        // Remove pending to hit "no pending" branch
        List<Custom_Action_Plan__c> pend = [SELECT Id FROM Custom_Action_Plan__c WHERE Status__c = 'Pending'];
        if (!pend.isEmpty()) {
            for (Custom_Action_Plan__c p : pend) p.Status__c = 'Processing';
            update pend;
        }
        
        Test.startTest();
        Map<String, Object> resp = ActionPlanMonitorController.processPendingPlans();
        Test.stopTest();
        
        System.assertEquals(true, (Boolean)resp.get('success'));
        System.assertEquals(0, (Integer)resp.get('count'));
    }
    
    @IsTest
    static void testProcessPendingPlans_WithPending() {
        // Ensure at least one pending exists
        insert new Custom_Action_Plan__c(
            Status__c = 'Pending',
            Sync_Status__c = 'Not Started',
            Submission_Date__c = System.now(),
            Processing_Time_Minutes__c = 0,
            External_Reference_Id__c = 'EXT-1731542400004-abcdef127'
        );
        
        Test.startTest();
        Map<String, Object> resp = ActionPlanMonitorController.processPendingPlans();
        Test.stopTest();
        
        System.assertEquals(true, (Boolean)resp.get('success'));
        System.assert(((Integer)resp.get('count')) >= 1, 'Should queue at least one');
    }
    
    @IsTest
    static void testRetryFailedPlans_BothBranches() {
        // First ensure there are failed plans
        insert new Custom_Action_Plan__c(
            Status__c = 'Failed',
            Sync_Status__c = 'Error',
            Submission_Date__c = System.now(),
            Processing_Time_Minutes__c = 1,
            External_Reference_Id__c = 'EXT-1731542400005-abcdef128'
        );
        
        Test.startTest();
        Map<String, Object> resp = ActionPlanMonitorController.retryFailedPlans();
        Test.stopTest();
        System.assertEquals(true, (Boolean)resp.get('success'));
        
        // Update all to non-failed to hit "none" branch
        List<Custom_Action_Plan__c> failed = [SELECT Id, Status__c, Sync_Status__c FROM Custom_Action_Plan__c WHERE Status__c = 'Failed' OR Sync_Status__c = 'Error'];
        if (!failed.isEmpty()) {
            for (Custom_Action_Plan__c p : failed) { p.Status__c = 'Synced'; p.Sync_Status__c = 'Complete'; }
            update failed;
        }
        
        Test.startTest();
        Map<String, Object> respNone = ActionPlanMonitorController.retryFailedPlans();
        Test.stopTest();
        System.assertEquals(true, (Boolean)respNone.get('success'));
        System.assertEquals(0, (Integer)respNone.get('count'));
    }
    
    @IsTest
    static void testGetSystemHealth() {
        Test.startTest();
        Map<String, Object> health = ActionPlanMonitorController.getSystemHealth();
        Test.stopTest();
        System.assertNotEquals(null, health);
        System.assert(health.containsKey('overallHealthScore'), 'Health has score');
        System.assert(health.containsKey('status'), 'Health has status');
    }
}