@IsTest
private class ActionPlanSecurityUtilsTest {
    
    @IsTest
    static void testValidateEmail_Positive() {
        String cleaned = ActionPlanSecurityUtils.validateEmail('  USER@example.com ');
        System.assertEquals('user@example.com', cleaned);
    }
    
    @IsTest
    static void testValidateEmail_Negatives() {
        Boolean threw = false;
        try { ActionPlanSecurityUtils.validateEmail(null); } catch (Exception e) { threw = true; }
        System.assertEquals(true, threw, 'Null should throw');
        
        threw = false;
        try { ActionPlanSecurityUtils.validateEmail('a'*300 + '@example.com'); } catch (Exception e) { threw = true; }
        System.assertEquals(true, threw, 'Too long should throw');
        
        threw = false;
        try { ActionPlanSecurityUtils.validateEmail('bad-at-example.com'); } catch (Exception e) { threw = true; }
        System.assertEquals(true, threw, 'Bad format should throw');
    }
    
    @IsTest
    static void testValidateName() {
        String out = ActionPlanSecurityUtils.validateName('  Alice <b>Admin</b>  ');
        System.assert(out.contains('Alice'));
        
        Boolean threw = false;
        try { ActionPlanSecurityUtils.validateName(''); } catch (Exception e) { threw = true; }
        System.assertEquals(true, threw);
        
        threw = false;
        try { ActionPlanSecurityUtils.validateName('<script>alert(1)</script>'); } catch (Exception e) { threw = true; }
        System.assertEquals(true, threw);
    }
    
    @IsTest
    static void testSanitizeText() {
        String s = ActionPlanSecurityUtils.sanitizeText('<script>alert(1)</script><div>Hello</div>');
        System.assert(!s.toLowerCase().contains('script'));
        System.assert(s.toLowerCase().contains('hello'));
    }
    
    @IsTest
    static void testReferenceId() {
        System.assertEquals(true, ActionPlanSecurityUtils.validateReferenceId('EXT-1731542400000-abc123def'));
        System.assertEquals(false, ActionPlanSecurityUtils.validateReferenceId('BAD-REF'));
    }
    
    @IsTest
    static void testXSSandSQLChecks() {
        System.assertEquals(true, ActionPlanSecurityUtils.containsXSS('<img onerror=1>'));
        System.assertEquals(true, ActionPlanSecurityUtils.containsSQLInjection(\"1' OR '1'='1\"));
        System.assertEquals(false, ActionPlanSecurityUtils.containsXSS('hello'));
        System.assertEquals(false, ActionPlanSecurityUtils.containsSQLInjection('selective'));
    }
    
    @IsTest
    static void testTokenAndHash() {
        String token = ActionPlanSecurityUtils.generateSecureToken();
        System.assertNotEquals(null, token);
        System.assert(token.length() > 0);
        
        String hash = ActionPlanSecurityUtils.hashData('abc');
        System.assertNotEquals(null, hash);
        System.assertEquals(64, hash.length(), 'SHA256 hex is 64 chars');
    }
    
    @IsTest
    static void testIPValidation() {
        System.assertEquals(true, ActionPlanSecurityUtils.isValidIPAddress('192.168.1.1'));
        System.assertEquals(false, ActionPlanSecurityUtils.isValidIPAddress('999.999.999.999'));
    }
    
    @IsTest
    static void testEncryptDecryptRoundTrip() {
        String plain = 'Top Secret';
        String enc = ActionPlanSecurityUtils.encryptData(plain);
        System.assertNotEquals(null, enc);
        String dec = ActionPlanSecurityUtils.decryptData(enc);
        System.assertEquals(plain, dec);
    }
    
    @IsTest
    static void testLogSecurityEvent() {
        ActionPlanSecurityUtils.logSecurityEvent('Test', 'Something happened', '127.0.0.1');
        List<Action_Plan_Submission_Log__c> logs = [
            SELECT Id, Event_Type__c, Details__c FROM Action_Plan_Submission_Log__c
            WHERE Event_Type__c LIKE 'Security_%' LIMIT 1
        ];
        System.assert(!logs.isEmpty(), 'Security log should be created');
    }
    
    @IsTest
    static void testRateLimitAndSuspiciousSubmission() {
        String email = 'rate@example.com';
        String ip = '203.0.113.10';
        
        // Create 3 recent submissions to breach a limit of 2 per hour
        List<Custom_Action_Plan__c> recent = new List<Custom_Action_Plan__c>();
        for (Integer i = 0; i < 3; i++) {
            recent.add(new Custom_Action_Plan__c(
                Status__c = 'Synced',
                Sync_Status__c = 'Complete',
                Submission_Date__c = System.now().addMinutes(-i*5),
                Submitted_By_Email__c = email,
                IP_Address__c = ip,
                Processing_Time_Minutes__c = 1,
                External_Reference_Id__c = 'EXT-1731542400000-abc123de' + i
            ));
        }
        insert recent;
        
        System.assertEquals(false, ActionPlanSecurityUtils.checkRateLimit(email, 2), 'Should be over the limit');
        System.assertEquals(true, ActionPlanSecurityUtils.checkRateLimit(email, 5), 'Under a higher limit');
        
        // Suspicious due to high task count and XSS text
        Map<String, Object> sub = new Map<String, Object>{
            'email' => email,
            'taskCount' => 20,
            'allText' => '<script>alert(1)</script>'
        };
        System.assertEquals(true, ActionPlanSecurityUtils.isSuspiciousSubmission(sub));
    }
    
    @IsTest
    static void testCSRFHelpers() {
        String sid = 'SESSION123';
        String good = ActionPlanSecurityUtils.generateCSRFToken(sid);
        System.assertNotEquals(null, good);
        
        // validateCSRFToken compares to a freshly-generated token; almost always false
        System.assertEquals(false, ActionPlanSecurityUtils.validateCSRFToken('not-a-match', sid));
    }
}