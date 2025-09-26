/**
 * dynamicActionPlanBuilder.js
 * Main LWC component for guest user action plan creation
 */
import { LightningElement, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTaskTemplates from '@salesforce/apex/DynamicActionPlanController.getTaskTemplates';
import saveActionPlan from '@salesforce/apex/DynamicActionPlanController.saveActionPlan';
import getActionPlanStatus from '@salesforce/apex/DynamicActionPlanController.getActionPlanStatus';

export default class DynamicActionPlanBuilder extends LightningElement {
    @api recordId; // Optional - for authenticated context
    @api referenceId; // For tracking in unauthenticated context
    @api relatedObjectType = 'Lead'; // Default to Lead for guest users
    
    @track tasks = [];
    @track taskTemplates = [];
    @track isLoading = false;
    @track currentStep = 1; // 1: Info, 2: Tasks, 3: Review, 4: Complete
    @track userInfo = {
        email: '',
        name: ''
    };
    @track completedReferenceId = null;
    @track error = null;
    
    // Pagination
    @track currentPage = 1;
    tasksPerPage = 5;
    
    // Task template
    taskPrototype = {
        tempId: null,
        name: '',
        description: '',
        dueDate: null,
        priority: 'Medium',
        category: 'Follow-up',
        assignedToEmail: '',
        daysAfterStart: 1,
        isRequired: true,
        reminderDaysBefore: 1
    };
    
    // Priority options
    priorityOptions = [
        { label: 'High', value: 'High' },
        { label: 'Medium', value: 'Medium' },
        { label: 'Low', value: 'Low' }
    ];
    
    // Category options
    categoryOptions = [
        { label: 'Follow-up', value: 'Follow-up' },
        { label: 'Documentation', value: 'Documentation' },
        { label: 'Review', value: 'Review' },
        { label: 'Approval', value: 'Approval' },
        { label: 'Other', value: 'Other' }
    ];
    
    // Computed properties
    get progressPercent() {
        return (this.currentStep / 4) * 100;
    }
    
    get isStep1() {
        return this.currentStep === 1;
    }
    
    get isStep2() {
        return this.currentStep === 2;
    }
    
    get isStep3() {
        return this.currentStep === 3;
    }
    
    get isStep4() {
        return this.currentStep === 4;
    }
    
    get hasNoTasks() {
        return this.tasks.length === 0;
    }
    
    get totalTasks() {
        return this.tasks.length;
    }
    
    get canProceed() {
        if (this.currentStep === 1) {
            return this.isValidEmail(this.userInfo.email) && this.userInfo.name;
        }
        if (this.currentStep === 2) {
            return this.tasks.length > 0 && this.areTasksValid();
        }
        return true;
    }
    
    get paginatedTasks() {
        const start = (this.currentPage - 1) * this.tasksPerPage;
        const end = start + this.tasksPerPage;
        return this.tasks.slice(start, end);
    }
    
    get totalPages() {
        return Math.ceil(this.tasks.length / this.tasksPerPage);
    }
    
    get hasPreviousPage() {
        return this.currentPage > 1;
    }
    
    get hasNextPage() {
        return this.currentPage < this.totalPages;
    }
    
    get trackingUrl() {
        if (this.completedReferenceId) {
            return `/action-plan-status?ref=${this.completedReferenceId}`;
        }
        return null;
    }
    
    // Lifecycle
    connectedCallback() {
        this.initializeComponent();
    }
    
    async initializeComponent() {
        try {
            this.isLoading = true;
            
            // Generate reference ID if not provided
            if (!this.referenceId) {
                this.referenceId = this.generateReferenceId();
            }
            
            // Load templates
            await this.loadTaskTemplates();
            
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }
    
    async loadTaskTemplates() {
        try {
            const templates = await getTaskTemplates();
            this.taskTemplates = templates || [];
        } catch (error) {
            console.error('Error loading templates:', error);
            this.showToast('Error', 'Unable to load task templates', 'error');
        }
    }
    
    // Event Handlers
    handleUserInfoChange(event) {
        const field = event.target.dataset.field;
        this.userInfo[field] = event.target.value;
    }
    
    handleNext() {
        if (this.canProceed && this.currentStep < 4) {
            this.currentStep++;
        }
    }
    
    handlePrevious() {
        if (this.currentStep > 1) {
            this.currentStep--;
        }
    }
    
    handleAddTask() {
        const newTask = {
            ...this.taskPrototype,
            tempId: this.generateTempId()
        };
        this.tasks = [...this.tasks, newTask];
        
        // Navigate to last page to show new task
        this.currentPage = this.totalPages;
    }
    
    handleAddTemplate(event) {
        const templateId = event.target.dataset.templateId;
        const template = this.taskTemplates.find(t => t.Id === templateId);
        
        if (template) {
            const newTask = {
                tempId: this.generateTempId(),
                name: template.Name,
                description: template.Description__c || '',
                dueDate: this.calculateDueDate(template.Default_Duration_Days__c || 7),
                priority: template.Default_Priority__c || 'Medium',
                category: template.Category__c || 'Follow-up',
                assignedToEmail: '',
                daysAfterStart: template.Default_Duration_Days__c || 1,
                isRequired: true,
                reminderDaysBefore: 1
            };
            
            this.tasks = [...this.tasks, newTask];
            this.showToast('Success', 'Task template added', 'success');
        }
    }
    
    handleTaskChange(event) {
        const tempId = event.target.dataset.taskId;
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        
        this.tasks = this.tasks.map(task => {
            if (task.tempId === tempId) {
                return { ...task, [field]: value };
            }
            return task;
        });
    }
    
    handleRemoveTask(event) {
        const tempId = event.currentTarget.dataset.taskId;
        this.tasks = this.tasks.filter(task => task.tempId !== tempId);
        
        // Adjust page if needed
        if (this.currentPage > this.totalPages && this.totalPages > 0) {
            this.currentPage = this.totalPages;
        }
    }
    
    handleDuplicateTask(event) {
        const tempId = event.currentTarget.dataset.taskId;
        const taskToDuplicate = this.tasks.find(task => task.tempId === tempId);
        
        if (taskToDuplicate) {
            const duplicatedTask = {
                ...taskToDuplicate,
                tempId: this.generateTempId(),
                name: taskToDuplicate.name + ' (Copy)'
            };
            
            this.tasks = [...this.tasks, duplicatedTask];
            this.showToast('Success', 'Task duplicated', 'success');
        }
    }
    
    handlePreviousPage() {
        if (this.hasPreviousPage) {
            this.currentPage--;
        }
    }
    
    handleNextPage() {
        if (this.hasNextPage) {
            this.currentPage++;
        }
    }
    
    async handleSave() {
        try {
            this.isLoading = true;
            
            // Validate
            if (!this.validateSubmission()) {
                return;
            }
            
            // Prepare data
            const actionPlanData = {
                referenceId: this.referenceId,
                submittedByEmail: this.userInfo.email,
                submittedByName: this.userInfo.name,
                relatedRecordId: this.recordId || null,
                relatedObjectType: this.relatedObjectType,
                ipAddress: await this.getClientIP(),
                userAgent: navigator.userAgent,
                sessionId: this.generateSessionId(),
                tasks: this.tasks.map(task => ({
                    name: task.name,
                    description: task.description,
                    dueDate: task.dueDate,
                    priority: task.priority,
                    category: task.category,
                    assignedToEmail: task.assignedToEmail,
                    daysAfterStart: task.daysAfterStart,
                    isRequired: task.isRequired,
                    reminderDaysBefore: task.reminderDaysBefore
                }))
            };
            
            // Save
            const result = await saveActionPlan({ 
                actionPlanJson: JSON.stringify(actionPlanData) 
            });
            
            if (result.success) {
                this.completedReferenceId = result.referenceId;
                this.currentStep = 4;
                this.showToast('Success', 'Your action plan has been submitted successfully!', 'success');
            }
            
        } catch (error) {
            this.handleError(error);
        } finally {
            this.isLoading = false;
        }
    }
    
    handleStartOver() {
        // Reset component
        this.currentStep = 1;
        this.tasks = [];
        this.userInfo = { email: '', name: '' };
        this.referenceId = this.generateReferenceId();
        this.completedReferenceId = null;
        this.currentPage = 1;
        this.error = null;
    }
    
    // Validation
    validateSubmission() {
        // Validate user info
        if (!this.isValidEmail(this.userInfo.email)) {
            this.showToast('Error', 'Please provide a valid email address', 'error');
            return false;
        }
        
        if (!this.userInfo.name || this.userInfo.name.trim().length < 2) {
            this.showToast('Error', 'Please provide your name', 'error');
            return false;
        }
        
        // Validate tasks
        if (this.tasks.length === 0) {
            this.showToast('Error', 'Please add at least one task', 'error');
            return false;
        }
        
        if (!this.areTasksValid()) {
            this.showToast('Error', 'Please complete all required task fields', 'error');
            return false;
        }
        
        return true;
    }
    
    areTasksValid() {
        return this.tasks.every(task => {
            return task.name && task.name.trim().length > 0;
        });
    }
    
    isValidEmail(email) {
        const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        return emailRegex.test(email);
    }
    
    // Utility Methods
    generateReferenceId() {
        const timestamp = Date.now();
        const random = Math.random().toString(36).substring(2, 11);
        return `EXT-${timestamp}-${random}`;
    }
    
    generateTempId() {
        return `task-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
    }
    
    generateSessionId() {
        return `session-${Date.now()}-${Math.random().toString(36).substring(2, 15)}`;
    }
    
    calculateDueDate(daysFromNow) {
        const date = new Date();
        date.setDate(date.getDate() + daysFromNow);
        return date.toISOString().split('T')[0];
    }
    
    async getClientIP() {
        try {
            // This would need to call an external service or use a server-side method
            // For now, return placeholder
            return 'Guest User IP';
        } catch (error) {
            return 'Unknown';
        }
    }
    
    formatDate(dateString) {
        if (!dateString) return '';
        const date = new Date(dateString);
        return date.toLocaleDateString('en-US', {
            month: 'short',
            day: 'numeric',
            year: 'numeric'
        });
    }
    
    handleError(error) {
        console.error('Error:', error);
        const message = error.body?.message || error.message || 'An unexpected error occurred';
        this.error = message;
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