/**
 * actionPlanMonitor.js
 * Lightning Web Component for monitoring action plan submissions and sync status
 */
import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getMonitoringData from '@salesforce/apex/ActionPlanMonitorController.getMonitoringData';
import processPendingPlans from '@salesforce/apex/ActionPlanMonitorController.processPendingPlans';
import retryFailedPlans from '@salesforce/apex/ActionPlanMonitorController.retryFailedPlans';
import getSystemHealth from '@salesforce/apex/ActionPlanMonitorController.getSystemHealth';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Import custom labels
import TITLE from '@salesforce/label/c.Action_Plan_Monitor_Title';
import REFRESH from '@salesforce/label/c.Refresh';
import PROCESS_PENDING from '@salesforce/label/c.Process_Pending';
import RETRY_FAILED from '@salesforce/label/c.Retry_Failed';

export default class ActionPlanMonitor extends LightningElement {
    @track isLoading = false;
    @track lastRefreshTime = null;
    @track selectedTimeRange = '7';
    @track showDetails = false;
    @track selectedStatus = 'all';
    @track showSystemHealth = false;
    
    // Dashboard metrics
    @track metrics = {
        total: 0,
        pending: 0,
        processing: 0,
        synced: 0,
        failed: 0,
        syncRate: 0,
        avgProcessingTime: 0,
        todaySubmissions: 0,
        weekSubmissions: 0,
        monthSubmissions: 0
    };
    
    // System health metrics
    @track systemHealth = {
        overallHealthScore: 0,
        status: 'Unknown',
        platformEventUsage: 0,
        asyncJobsQueued: 0,
        storageUsage: 0,
        apiRequestsUsed: 0,
        apiRequestsLimit: 0
    };
    
    // Chart data
    @track chartData = {
        daily: [],
        hourly: [],
        statusDistribution: []
    };
    
    // Table data
    @track recentSubmissions = [];
    @track failedSubmissions = [];
    
    // Cached wire result for refresh
    wiredMonitoringResult;
    wiredSystemHealthResult;
    
    // Labels
    label = {
        title: TITLE,
        refresh: REFRESH,
        processPending: PROCESS_PENDING,
        retryFailed: RETRY_FAILED
    };
    
    // Time range options
    get timeRangeOptions() {
        return [
            { label: 'Last 24 Hours', value: '1' },
            { label: 'Last 7 Days', value: '7' },
            { label: 'Last 30 Days', value: '30' },
            { label: 'Last 90 Days', value: '90' }
        ];
    }
    
    // Status filter options
    get statusOptions() {
        return [
            { label: 'All', value: 'all' },
            { label: 'Pending', value: 'Pending' },
            { label: 'Processing', value: 'Processing' },
            { label: 'Synced', value: 'Synced' },
            { label: 'Failed', value: 'Failed' }
        ];
    }
    
    // Computed properties
    get formattedLastRefresh() {
        if (!this.lastRefreshTime) return 'Never';
        return new Intl.DateTimeFormat('en-US', {
            hour: 'numeric',
            minute: 'numeric',
            second: 'numeric',
            hour12: true
        }).format(this.lastRefreshTime);
    }
    
    get hasPendingPlans() {
        return this.metrics.pending > 0;
    }
    
    get hasFailedPlans() {
        return this.metrics.failed > 0;
    }
    
    get syncRateClass() {
        if (this.metrics.syncRate >= 95) return 'slds-text-color_success';
        if (this.metrics.syncRate >= 80) return 'slds-text-color_weak';
        return 'slds-text-color_error';
    }
    
    get syncRateIcon() {
        if (this.metrics.syncRate >= 95) return 'utility:success';
        if (this.metrics.syncRate >= 80) return 'utility:warning';
        return 'utility:error';
    }
    
    get healthStatusClass() {
        if (this.systemHealth.status === 'Healthy') return 'slds-text-color_success';
        if (this.systemHealth.status === 'Warning') return 'slds-text-color_weak';
        return 'slds-text-color_error';
    }
    
    get healthStatusIcon() {
        if (this.systemHealth.status === 'Healthy') return 'utility:check';
        if (this.systemHealth.status === 'Warning') return 'utility:warning';
        return 'utility:clear';
    }
    
    // Wire adapter for monitoring data
    @wire(getMonitoringData, { 
        timeRangeDays: '$selectedTimeRange',
        statusFilter: '$selectedStatus'
    })
    wiredMonitoring(result) {
        this.wiredMonitoringResult = result;
        
        if (result.data) {
            this.processMonitoringData(result.data);
            this.lastRefreshTime = new Date();
        } else if (result.error) {
            this.handleError(result.error);
        }
    }
    
    // Wire adapter for system health
    @wire(getSystemHealth)
    wiredSystemHealth(result) {
        this.wiredSystemHealthResult = result;
        
        if (result.data) {
            this.systemHealth = {
                ...this.systemHealth,
                ...result.data
            };
        } else if (result.error) {
            console.error('Error loading system health:', result.error);
        }
    }
    
    // Lifecycle
    connectedCallback() {
        // Set up auto-refresh every 30 seconds
        this.refreshInterval = setInterval(() => {
            this.handleRefresh();
        }, 30000);
    }
    
    disconnectedCallback() {
        // Clear interval on component destroy
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
        }
    }
    
    // Data processing
    processMonitoringData(data) {
        // Update metrics
        if (data.metrics) {
            this.metrics = {
                ...this.metrics,
                ...data.metrics
            };
            
            // Calculate sync rate
            if (this.metrics.total > 0) {
                this.metrics.syncRate = Math.round(
                    (this.metrics.synced / this.metrics.total) * 100
                );
            }
        }
        
        // Update chart data
        if (data.chartData) {
            this.chartData = data.chartData;
            // In production, you would render charts here using Chart.js or D3
        }
        
        // Update tables
        if (data.recentSubmissions) {
            this.recentSubmissions = this.processTableData(data.recentSubmissions);
        }
        
        if (data.failedSubmissions) {
            this.failedSubmissions = this.processTableData(data.failedSubmissions);
        }
    }
    
    processTableData(records) {
        return records.map(record => ({
            ...record,
            submissionDateFormatted: this.formatDateTime(record.Submission_Date__c),
            statusClass: this.getStatusClass(record.Status__c),
            statusIcon: this.getStatusIcon(record.Status__c),
            viewUrl: `/lightning/r/Custom_Action_Plan__c/${record.Id}/view`
        }));
    }
    
    // Event handlers
    handleTimeRangeChange(event) {
        this.selectedTimeRange = event.detail.value;
    }
    
    handleStatusFilterChange(event) {
        this.selectedStatus = event.detail.value;
    }
    
    async handleRefresh() {
        this.isLoading = true;
        
        try {
            await refreshApex(this.wiredMonitoringResult);
            await refreshApex(this.wiredSystemHealthResult);
            this.showToast('Success', 'Dashboard refreshed', 'success');
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }
    
    async handleProcessPending() {
        this.isLoading = true;
        
        try {
            const result = await processPendingPlans();
            
            if (result.success) {
                this.showToast(
                    'Success', 
                    `Processing ${result.count} pending plan(s)`, 
                    'success'
                );
                
                // Refresh data after processing
                await refreshApex(this.wiredMonitoringResult);
            } else {
                throw new Error(result.message);
            }
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }
    
    async handleRetryFailed() {
        this.isLoading = true;
        
        try {
            const result = await retryFailedPlans();
            
            if (result.success) {
                this.showToast(
                    'Success', 
                    `Retrying ${result.count} failed plan(s)`, 
                    'success'
                );
                
                // Refresh data after retry
                await refreshApex(this.wiredMonitoringResult);
            } else {
                throw new Error(result.message);
            }
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }
    
    handleToggleDetails() {
        this.showDetails = !this.showDetails;
    }
    
    handleToggleSystemHealth() {
        this.showSystemHealth = !this.showSystemHealth;
        if (this.showSystemHealth) {
            refreshApex(this.wiredSystemHealthResult);
        }
    }
    
    handleViewRecord(event) {
        const recordId = event.currentTarget.dataset.recordId;
        window.open(`/lightning/r/Custom_Action_Plan__c/${recordId}/view`, '_blank');
    }
    
    handleExportData() {
        // Export current data as CSV
        const csv = this.convertToCSV(this.recentSubmissions);
        this.downloadCSV(csv, `action-plans-${Date.now()}.csv`);
        this.showToast('Success', 'Data exported successfully', 'success');
    }
    
    // Utility methods
    formatDateTime(dateTimeString) {
        if (!dateTimeString) return '';
        
        const date = new Date(dateTimeString);
        return new Intl.DateTimeFormat('en-US', {
            month: 'short',
            day: 'numeric',
            year: 'numeric',
            hour: 'numeric',
            minute: 'numeric',
            hour12: true
        }).format(date);
    }
    
    formatNumber(num) {
        if (num === null || num === undefined) return '0';
        return new Intl.NumberFormat('en-US').format(num);
    }
    
    formatPercentage(num) {
        if (num === null || num === undefined) return '0%';
        return `${Math.round(num)}%`;
    }
    
    getStatusClass(status) {
        const statusClasses = {
            'Pending': 'slds-badge',
            'Processing': 'slds-badge slds-theme_warning',
            'Synced': 'slds-badge slds-theme_success',
            'Failed': 'slds-badge slds-theme_error'
        };
        return statusClasses[status] || 'slds-badge';
    }
    
    getStatusIcon(status) {
        const statusIcons = {
            'Pending': 'utility:clock',
            'Processing': 'utility:sync',
            'Synced': 'utility:success',
            'Failed': 'utility:error'
        };
        return statusIcons[status] || 'utility:question';
    }
    
    convertToCSV(data) {
        if (!data || data.length === 0) return '';
        
        // Get headers
        const headers = [
            'Reference ID',
            'Status',
            'Sync Status',
            'Submitted By',
            'Submission Date'
        ];
        const csvHeaders = headers.join(',');
        
        // Get rows
        const csvRows = data.map(row => {
            return [
                row.External_Reference_Id__c || '',
                row.Status__c || '',
                row.Sync_Status__c || '',
                row.Submitted_By_Email__c || '',
                row.Submission_Date__c || ''
            ].map(value => {
                // Escape values containing commas
                return typeof value === 'string' && value.includes(',') 
                    ? `"${value}"` 
                    : value;
            }).join(',');
        });
        
        return `${csvHeaders}\n${csvRows.join('\n')}`;
    }
    
    downloadCSV(csv, filename) {
        const blob = new Blob([csv], { type: 'text/csv' });
        const url = window.URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = filename;
        link.click();
        window.URL.revokeObjectURL(url);
    }
    
    handleError(error) {
        console.error('Error:', error);
        const message = error.body?.message || error.message || 'An error occurred';
        this.showToast('Error', message, 'error');
    }
    
    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title,
            message,
            variant
        });
        this.dispatchEvent(event);
    }
}