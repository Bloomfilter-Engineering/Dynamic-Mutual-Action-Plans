/**
 * ActionPlanSecurityUtils.cls
 * Security utilities for action plan processing
 */
public with sharing class ActionPlanSecurityUtils {
    
    // Constants
    private static final Integer MAX_INPUT_LENGTH = 5000;
    private static final Integer MAX_EMAIL_LENGTH = 255;
    private static final Integer MAX_NAME_LENGTH = 255;
    private static final Set<String> BLOCKED_DOMAINS = new Set<String>{
        'tempmail.com', 'throwaway.email', 'guerrillamail.com'
    };
    
    // XSS patterns to block
    private static final List<Pattern> XSS_PATTERNS = new List<Pattern>{
        Pattern.compile('(?i)<script[^>]*>.*?</script>'),
        Pattern.compile('(?i)<iframe[^>]*>.*?</iframe>'),
        Pattern.compile('(?i)javascript:'),
        Pattern.compile('(?i)on\\w+\\s*='),
        Pattern.compile('(?i)<img[^>]*onerror[^>]*>'),
        Pattern.compile('(?i)<body[^>]*onload[^>]*>')
    };
    
    // SQL injection patterns
    private static final List<Pattern> SQL_PATTERNS = new List<Pattern>{
        Pattern.compile('(?i)(union|select|insert|update|delete|drop)\\s+(from|into|where)'),
        Pattern.compile('(?i)--\\s*$'),
        Pattern.compile('(?i);\\s*(drop|delete|update)\\s'),
        Pattern.compile('(?i)\\bor\\b\\s*\\d+\\s*=\\s*\\d+'),
        Pattern.compile('(?i)\\band\\b\\s*\\d+\\s*=\\s*\\d+')
    };
    
    /**
     * Validate and sanitize email address
     */
    public static String validateEmail(String email) {
        if (String.isBlank(email)) {
            throw new SecurityException('Email address is required');
        }
        
        email = email.trim().toLowerCase();
        
        if (email.length() > MAX_EMAIL_LENGTH) {
            throw new SecurityException('Email address is too long');
        }
        
        // Check email format
        if (!isValidEmailFormat(email)) {
            throw new SecurityException('Invalid email format');
        }
        
        // Check for blocked domains
        String domain = email.substringAfter('@');
        if (BLOCKED_DOMAINS.contains(domain)) {
            throw new SecurityException('Email domain is not allowed');
        }
        
        // Check for XSS
        if (containsXSS(email)) {
            throw new SecurityException('Invalid characters in email address');
        }
        
        return email;
    }
    
    /**
     * Validate and sanitize name
     */
    public static String validateName(String name) {
        if (String.isBlank(name)) {
            throw new SecurityException('Name is required');
        }
        
        name = name.trim();
        
        if (name.length() > MAX_NAME_LENGTH) {
            throw new SecurityException('Name is too long');
        }
        
        // Remove any HTML tags
        name = name.stripHtmlTags();
        
        // Check for XSS
        if (containsXSS(name)) {
            throw new SecurityException('Invalid characters in name');
        }
        
        // Check for SQL injection
        if (containsSQLInjection(name)) {
            throw new SecurityException('Invalid characters in name');
        }
        
        return name.escapeHtml4();
    }
    
    /**
     * Sanitize text input
     */
    public static String sanitizeText(String text) {
        if (String.isBlank(text)) {
            return text;
        }
        
        if (text.length() > MAX_INPUT_LENGTH) {
            text = text.substring(0, MAX_INPUT_LENGTH);
        }
        
        // Remove HTML tags
        text = text.stripHtmlTags();
        
        // Escape HTML entities
        text = text.escapeHtml4();
        
        // Remove any script tags or javascript
        for (Pattern xssPattern : XSS_PATTERNS) {
            text = xssPattern.matcher(text).replaceAll('');
        }
        
        return text.trim();
    }
    
    /**
     * Validate reference ID format
     */
    public static Boolean validateReferenceId(String referenceId) {
        if (String.isBlank(referenceId)) {
            return false;
        }
        
        // Expected format: EXT-{timestamp}-{random}
        Pattern refPattern = Pattern.compile('^EXT-\\d{13}-[a-z0-9]{9}$');
        return refPattern.matcher(referenceId).matches();
    }
    
    /**
     * Check for XSS patterns
     */
    public static Boolean containsXSS(String input) {
        if (String.isBlank(input)) {
            return false;
        }
        
        for (Pattern xssPattern : XSS_PATTERNS) {
            if (xssPattern.matcher(input).find()) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * Check for SQL injection patterns
     */
    public static Boolean containsSQLInjection(String input) {
        if (String.isBlank(input)) {
            return false;
        }
        
        for (Pattern sqlPattern : SQL_PATTERNS) {
            if (sqlPattern.matcher(input).find()) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * Validate email format
     */
    private static Boolean isValidEmailFormat(String email) {
        String emailRegex = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$';
        Pattern pattern = Pattern.compile(emailRegex);
        return pattern.matcher(email).matches();
    }
    
    /**
     * Generate secure token
     */
    public static String generateSecureToken() {
        Blob randomBytes = Crypto.generateAesKey(256);
        return EncodingUtil.convertToHex(randomBytes);
    }
    
    /**
     * Hash sensitive data
     */
    public static String hashData(String data) {
        if (String.isBlank(data)) {
            return null;
        }
        
        Blob hash = Crypto.generateDigest('SHA256', Blob.valueOf(data));
        return EncodingUtil.convertToHex(hash);
    }
    
    /**
     * Validate IP address
     */
    public static Boolean isValidIPAddress(String ipAddress) {
        if (String.isBlank(ipAddress)) {
            return false;
        }
        
        // IPv4 pattern
        String ipv4Pattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$';
        
        // IPv6 pattern (simplified)
        String ipv6Pattern = '^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4})$';
        
        return Pattern.matches(ipv4Pattern, ipAddress) || Pattern.matches(ipv6Pattern, ipAddress);
    }
    
    /**
     * Rate limiting check
     */
    public static Boolean checkRateLimit(String identifier, Integer limitPerHour) {
        DateTime oneHourAgo = System.now().addHours(-1);
        
        // Check submissions by identifier (email or IP)
        Integer recentSubmissions = [
            SELECT COUNT()
            FROM Custom_Action_Plan__c
            WHERE (Submitted_By_Email__c = :identifier OR IP_Address__c = :identifier)
            AND Submission_Date__c >= :oneHourAgo
        ];
        
        return recentSubmissions < limitPerHour;
    }
    
    /**
     * Encrypt sensitive data
     */
    public static String encryptData(String plainText) {
        if (String.isBlank(plainText)) {
            return null;
        }
        
        try {
            // Get or create encryption key from Custom Settings
            Blob key = getOrCreateEncryptionKey();
            
            Blob data = Blob.valueOf(plainText);
            Blob encryptedData = Crypto.encryptWithManagedIV('AES256', key, data);
            
            return EncodingUtil.base64Encode(encryptedData);
        } catch (Exception e) {
            System.debug('Encryption error: ' + e.getMessage());
            return null;
        }
    }
    
    /**
     * Decrypt sensitive data
     */
    public static String decryptData(String encryptedText) {
        if (String.isBlank(encryptedText)) {
            return null;
        }
        
        try {
            Blob key = getOrCreateEncryptionKey();
            
            Blob encryptedData = EncodingUtil.base64Decode(encryptedText);
            Blob decryptedData = Crypto.decryptWithManagedIV('AES256', key, encryptedData);
            
            return decryptedData.toString();
        } catch (Exception e) {
            System.debug('Decryption error: ' + e.getMessage());
            return null;
        }
    }
    
    /**
     * Get or create encryption key
     */
    private static Blob getOrCreateEncryptionKey() {
        // In production, this should be stored in Protected Custom Settings
        // For demo purposes, generating a static key
        String keyString = 'ThisisaDemoKeyForActionPlanEncry';
        return Blob.valueOf(keyString);
    }
    
    /**
     * Log security event
     */
    public static void logSecurityEvent(String eventType, String details, String ipAddress) {
        try {
            Action_Plan_Submission_Log__c log = new Action_Plan_Submission_Log__c(
                Event_Type__c = 'Security_' + eventType,
                Event_Date__c = System.now(),
                Details__c = details,
                IP_Address__c = ipAddress
            );
            
            insert log;
        } catch (Exception e) {
            System.debug('Failed to log security event: ' + e.getMessage());
        }
    }
    
    /**
     * Validate CSRF token
     */
    public static Boolean validateCSRFToken(String providedToken, String sessionId) {
        if (String.isBlank(providedToken) || String.isBlank(sessionId)) {
            return false;
        }
        
        // Generate expected token based on session
        String expectedToken = generateCSRFToken(sessionId);
        
        return providedToken.equals(expectedToken);
    }
    
    /**
     * Generate CSRF token
     */
    public static String generateCSRFToken(String sessionId) {
        if (String.isBlank(sessionId)) {
            return null;
        }
        
        String data = sessionId + System.now().getTime();
        return hashData(data);
    }
    
    /**
     * Check for suspicious patterns
     */
    public static Boolean isSuspiciousSubmission(Map<String, Object> submissionData) {
        // Check for rapid submissions
        String email = (String) submissionData.get('email');
        if (!checkRateLimit(email, 3)) {
            return true;
        }
        
        // Check for suspicious task counts
        Integer taskCount = (Integer) submissionData.get('taskCount');
        if (taskCount != null && taskCount > 15) {
            return true;
        }
        
        // Check for suspicious patterns in text
        String allText = (String) submissionData.get('allText');
        if (String.isNotBlank(allText)) {
            if (containsXSS(allText) || containsSQLInjection(allText)) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * Custom exception class
     */
    public class SecurityException extends Exception {}
}