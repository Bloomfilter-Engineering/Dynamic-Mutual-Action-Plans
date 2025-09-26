/**
 * ActionPlanMonitorController.cls
 * Controller for the Action Plan Monitoring Dashboard
 */
public with sharing class ActionPlanMonitorController {
    
    /**
     * Get monitoring data for dashboard
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getMonitoringData(Integer timeRangeDays, String statusFilter) {
        try {
            Map<String, Object> result = new Map<String, Object>();
            
            // Calculate date range
            DateTime startDate = System.now().addDays(-timeRangeDays);
            DateTime endDate = System.now();
            
            // Get metrics
            result.put('metrics', calculateMetrics(startDate, endDate, statusFilter));
            
            // Get chart data
            result.put('chartData', getChartData(startDate, endDate));
            
            // Get recent submissions
            result.put('recentSubmissions', getRecentSubmissions(20, statusFilter));
            
            // Get failed submissions
            result.put('failedSubmissions', getFailedSubmissions(10));
            
            return result;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error loading monitoring data: ' + e.getMessage());
        }
    }
    
    /**
     * Calculate dashboard metrics
     */
    private static Map<String, Object> calculateMetrics(DateTime startDate, DateTime endDate, String statusFilter) {
        Map<String, Object> metrics = new Map<String, Object>();
        
        // Build base query
        String baseQuery = 'SELECT COUNT(Id) total, Status__c status ' +
                          'FROM Custom_Action_Plan__c ' +
                          'WHERE Submission_Date__c >= :startDate ' +
                          'AND Submission_Date__c <= :endDate ';
        
        if (statusFilter != null && statusFilter != 'all') {
            baseQuery += 'AND Status__c = :statusFilter ';
        }
        
        baseQuery += 'GROUP BY Status__c';
        
        // Execute query and process results
        Integer total = 0;
        Integer pending = 0;
        Integer processing = 0;
        Integer synced = 0;
        Integer failed = 0;
        
        for (AggregateResult ar : Database.query(baseQuery)) {
            String status = (String) ar.get('status');
            Integer count = (Integer) ar.get('total');
            
            total += count;
            
            if (status == 'Pending') pending = count;
            else if (status == 'Processing') processing = count;
            else if (status == 'Synced') synced = count;
            else if (status == 'Failed') failed = count;
        }
        
        metrics.put('total', total);
        metrics.put('pending', pending);
        metrics.put('processing', processing);
        metrics.put('synced', synced);
        metrics.put('failed', failed);
        
        // Calculate average processing time
        List<AggregateResult> avgTime = [
            SELECT AVG(Processing_Time_Minutes__c) avgTime
            FROM Custom_Action_Plan__c
            WHERE Status__c = 'Synced'
            AND Submission_Date__c >= :startDate
            AND Submission_Date__c <= :endDate
        ];
        
        if (!avgTime.isEmpty() && avgTime[0].get('avgTime') != null) {
            metrics.put('avgProcessingTime', avgTime[0].get('avgTime'));
        } else {
            metrics.put('avgProcessingTime', 0);
        }
        
        // Get today's submissions
        DateTime todayStart = DateTime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));
        Integer todayCount = [
            SELECT COUNT()
            FROM Custom_Action_Plan__c
            WHERE Submission_Date__c >= :todayStart
        ];
        metrics.put('todaySubmissions', todayCount);
        
        // Get this week's submissions
        DateTime weekStart = DateTime.newInstance(Date.today().toStartOfWeek(), Time.newInstance(0, 0, 0, 0));
        Integer weekCount = [
            SELECT COUNT()
            FROM Custom_Action_Plan__c
            WHERE Submission_Date__c >= :weekStart
        ];
        metrics.put('weekSubmissions', weekCount);
        
        // Get this month's submissions
        DateTime monthStart = DateTime.newInstance(Date.today().toStartOfMonth(), Time.newInstance(0, 0, 0, 0));
        Integer monthCount = [
            SELECT COUNT()
            FROM Custom_Action_Plan__c
            WHERE Submission_Date__c >= :monthStart
        ];
        metrics.put('monthSubmissions', monthCount);
        
        return metrics;
    }
    
    /**
     * Get chart data for visualizations
     */
    private static Map<String, Object> getChartData(DateTime startDate, DateTime endDate) {
        Map<String, Object> chartData = new Map<String, Object>();
        
        // Daily submissions
        List<AggregateResult> dailyData = [
            SELECT DAY_ONLY(Submission_Date__c) submissionDay, COUNT(Id) total
            FROM Custom_Action_Plan__c
            WHERE Submission_Date__c >= :startDate
            AND Submission_Date__c <= :endDate
            GROUP BY DAY_ONLY(Submission_Date__c)
            ORDER BY DAY_ONLY(Submission_Date__c)
        ];
        
        List<Map<String, Object>> dailyChart = new List<Map<String, Object>>();
        for (AggregateResult ar : dailyData) {
            dailyChart.add(new Map<String, Object>{
                'date' => ar.get('submissionDay'),
                'count' => ar.get('total')
            });
        }
        chartData.put('daily', dailyChart);
        
        // Hourly distribution (last 24 hours)
        DateTime last24Hours = System.now().addHours(-24);
        List<AggregateResult> hourlyData = [
            SELECT HOUR_IN_DAY(Submission_Date__c) submissionHour, COUNT(Id) total
            FROM Custom_Action_Plan__c
            WHERE Submission_Date__c >= :last24Hours
            GROUP BY HOUR_IN_DAY(Submission_Date__c)
            ORDER BY HOUR_IN_DAY(Submission_Date__c)
        ];
        
        List<Map<String, Object>> hourlyChart = new List<Map<String, Object>>();
        for (AggregateResult ar : hourlyData) {
            hourlyChart.add(new Map<String, Object>{
                'hour' => ar.get('submissionHour'),
                'count' => ar.get('total')
            });
        }
        chartData.put('hourly', hourlyChart);
        
        // Status distribution
        List<AggregateResult> statusData = [
            SELECT Status__c status, COUNT(Id) total
            FROM Custom_Action_Plan__c
            WHERE Submission_Date__c >= :startDate
            AND Submission_Date__c <= :endDate
            GROUP BY Status__c
        ];
        
        List<Map<String, Object>> statusChart = new List<Map<String, Object>>();
        for (AggregateResult ar : statusData) {
            statusChart.add(new Map<String, Object>{
                'status' => ar.get('status'),
                'count' => ar.get('total')
            });
        }
        chartData.put('statusDistribution', statusChart);
        
        return chartData;
    }
    
    /**
     * Get recent submissions
     */
    private static List<Custom_Action_Plan__c> getRecentSubmissions(Integer recordLimit, String statusFilter) {
        String query = 'SELECT Id, External_Reference_Id__c, Status__c, ' +
                      'Sync_Status__c, Submitted_By_Email__c, Submitted_By_Name__c, ' +
                      'Submission_Date__c, Native_Action_Plan_Id__c, ' +
                      '(SELECT COUNT() FROM Custom_Tasks__r) Task_Count__c ' +
                      'FROM Custom_Action_Plan__c ';
        
        if (statusFilter != null && statusFilter != 'all') {
            query += 'WHERE Status__c = :statusFilter ';
        }
        
        query += 'ORDER BY Submission_Date__c DESC ' +
                'LIMIT :recordLimit';
        
        return Database.query(query);
    }
    
    /**
     * Get failed submissions
     */
    private static List<Custom_Action_Plan__c> getFailedSubmissions(Integer recordLimit) {
        return [
            SELECT Id, External_Reference_Id__c, Status__c, 
                   Sync_Status__c, Submitted_By_Email__c, 
                   Submission_Date__c, Error_Message__c,
                   (SELECT COUNT() FROM Custom_Tasks__r) Task_Count__c
            FROM Custom_Action_Plan__c
            WHERE Status__c = 'Failed'
            OR Sync_Status__c = 'Error'
            ORDER BY Submission_Date__c DESC
            LIMIT :recordLimit
        ];
    }
    
    /**
     * Process pending action plans
     */
    @AuraEnabled
    public static Map<String, Object> processPendingPlans() {
        try {
            // Check permissions
            if (!Schema.sObjectType.Custom_Action_Plan__c.isUpdateable()) {
                throw new AuraHandledException('Insufficient permissions to process plans');
            }
            
            // Get pending plans
            List<Custom_Action_Plan__c> pendingPlans = [
                SELECT Id
                FROM Custom_Action_Plan__c
                WHERE Status__c = 'Pending'
                AND Sync_Status__c = 'Not Started'
                LIMIT 100
            ];
            
            if (pendingPlans.isEmpty()) {
                return new Map<String, Object>{
                    'success' => true,
                    'count' => 0,
                    'message' => 'No pending plans to process'
                };
            }
            
            // Extract IDs
            List<Id> planIds = new List<Id>();
            for (Custom_Action_Plan__c plan : pendingPlans) {
                planIds.add(plan.Id);
            }
            
            // Process using future method or queueable
            if (!System.isFuture() && !System.isBatch() && !System.isQueueable()) {
                ActionPlanEventHandler.processFuture(planIds);
            } else {
                // If already in async context, enqueue
                System.enqueueJob(new ActionPlanEventHandler.ActionPlanQueueable(planIds));
            }
            
            return new Map<String, Object>{
                'success' => true,
                'count' => planIds.size(),
                'message' => 'Processing ' + planIds.size() + ' pending plans'
            };
            
        } catch (Exception e) {
            throw new AuraHandledException('Error processing pending plans: ' + e.getMessage());
        }
    }
    
    /**
     * Retry failed action plans
     */
    @AuraEnabled
    public static Map<String, Object> retryFailedPlans() {
        try {
            // Check permissions
            if (!Schema.sObjectType.Custom_Action_Plan__c.isUpdateable()) {
                throw new AuraHandledException('Insufficient permissions to retry plans');
            }
            
            // Get failed plans
            List<Custom_Action_Plan__c> failedPlans = [
                SELECT Id
                FROM Custom_Action_Plan__c
                WHERE (Status__c = 'Failed' OR Sync_Status__c = 'Error')
                AND Submission_Date__c >= :System.now().addDays(-7)
                LIMIT 50
            ];
            
            if (failedPlans.isEmpty()) {
                return new Map<String, Object>{
                    'success' => true,
                    'count' => 0,
                    'message' => 'No failed plans to retry'
                };
            }
            
            // Reset status for retry
            for (Custom_Action_Plan__c plan : failedPlans) {
                plan.Status__c = 'Pending';
                plan.Sync_Status__c = 'Not Started';
                plan.Error_Message__c = null;
            }
            
            update failedPlans;
            
            // Extract IDs and process
            List<Id> planIds = new List<Id>();
            for (Custom_Action_Plan__c plan : failedPlans) {
                planIds.add(plan.Id);
            }
            
            // Process using future method or queueable
            if (!System.isFuture() && !System.isBatch() && !System.isQueueable()) {
                ActionPlanEventHandler.processFuture(planIds);
            } else {
                System.enqueueJob(new ActionPlanEventHandler.ActionPlanQueueable(planIds));
            }
            
            return new Map<String, Object>{
                'success' => true,
                'count' => planIds.size(),
                'message' => 'Retrying ' + planIds.size() + ' failed plans'
            };
            
        } catch (Exception e) {
            throw new AuraHandledException('Error retrying failed plans: ' + e.getMessage());
        }
    }
    
    /**
     * Get system health metrics
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSystemHealth() {
        Map<String, Object> health = new Map<String, Object>();
        
        try {
            // Check platform event usage
            Integer eventUsage = Limits.getPublishImmediateDML();
            Integer eventLimit = Limits.getLimitPublishImmediateDML();
            health.put('platformEventUsage', (Double) eventUsage / eventLimit * 100);
            
            // Check async apex jobs
            Integer asyncJobs = [
                SELECT COUNT()
                FROM AsyncApexJob
                WHERE Status IN ('Queued', 'Processing', 'Preparing')
                AND CreatedDate = TODAY
            ];
            health.put('asyncJobsQueued', asyncJobs);
            
            // Check storage usage
            Organization org = [
                SELECT UsedDataStorageMB, TotalDataStorageMB
                FROM Organization
                LIMIT 1
            ];
            
            Double storageUsage = 0;
            if (org.TotalDataStorageMB > 0) {
                storageUsage = (Double) org.UsedDataStorageMB / org.TotalDataStorageMB * 100;
            }
            health.put('storageUsage', storageUsage);
            
            // Check API usage
            health.put('apiRequestsUsed', OrgLimits.getMap().get('DailyApiRequests').getValue());
            health.put('apiRequestsLimit', OrgLimits.getMap().get('DailyApiRequests').getLimit());
            
            // Overall health score
            Double healthScore = 100;
            if (storageUsage > 80) healthScore -= 20;
            if (asyncJobs > 50) healthScore -= 10;
            if (eventUsage > eventLimit * 0.8) healthScore -= 10;
            
            health.put('overallHealthScore', healthScore);
            health.put('status', healthScore >= 80 ? 'Healthy' : healthScore >= 60 ? 'Warning' : 'Critical');
            
        } catch (Exception e) {
            health.put('error', 'Unable to retrieve system health: ' + e.getMessage());
        }
        
        return health;
    }
}