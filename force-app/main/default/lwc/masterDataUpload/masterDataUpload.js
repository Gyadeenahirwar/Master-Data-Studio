import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getUploadConfigs from '@salesforce/apex/MasterUploadController.getUploadConfigs';
import getObjectTemplateDetails from '@salesforce/apex/MasterUploadController.getObjectTemplateDetails';
import uploadBatch from '@salesforce/apex/MasterUploadController.uploadBatch';
import getAllEligibleObjects from '@salesforce/apex/MasterUploadController.getAllEligibleObjects';
import getObjectFieldsForSetup from '@salesforce/apex/MasterUploadController.getObjectFieldsForSetup';
import saveObjectUploadConfig from '@salesforce/apex/MasterUploadController.saveObjectUploadConfig';
import deleteObjectUploadConfig from '@salesforce/apex/MasterUploadController.deleteObjectUploadConfig';
import initiateUploadJob from '@salesforce/apex/MasterUploadController.initiateUploadJob';
import updateJobProgress from '@salesforce/apex/MasterUploadController.updateJobProgress';
import markJobFailed from '@salesforce/apex/MasterUploadController.markJobFailed';
import getActiveAndRecentJobs from '@salesforce/apex/MasterUploadController.getActiveAndRecentJobs';
import getJobErrorLog from '@salesforce/apex/MasterUploadController.getJobErrorLog';

const BATCH_CHUNK_SIZE = 200;
const PREVIEW_LIMIT = 10;

export default class MasterDataUpload extends LightningElement {
    // Component State
    isLoading = false;
    isUploading = false;
    activeTab = 'uploadTab';

    // Job Monitoring & Concurrency State
    @track recentJobs = [];
    pollingTimer = null;
    activeJobId = null;

    // Metadata Configurations
    wiredConfigsResult;
    @track uploadConfigs = [];
    @track objectOptions = [];
    selectedObjectApi = '';
    selectedConfig = null;

    // Object Details & Schema
    @track templateDetails = null;
    @track fieldMappings = [];
    schemaSearchKey = '';
    activeExternalIdField = 'External_Code__c';

    // CSV File & Parsed Data
    fileName = '';
    fileSizeFormatted = '';
    @track parsedHeaders = [];
    @track parsedRows = [];
    @track previewRows = [];
    isDragOver = false;

    // Ingestion Execution & Progress
    progressPercentage = 0;
    progressStatusText = '';
    @track resultsSummary = {
        totalProcessed: 0,
        totalSuccess: 0,
        totalFailure: 0
    };
    @track aggregatedErrors = [];
    hasCompletedResults = false;

    // =========================================================================
    // SETUP WIZARD STATE
    // =========================================================================
    isSetupModalOpen = false;
    isSetupLoading = false;
    @track allEligibleObjects = [];
    @track allEligibleObjectOptions = [];
    @track setupForm = {
        objectApiName: '',
        objectLabel: '',
        uploadSequence: 1,
        externalIdField: '',
        description: ''
    };
    @track setupFields = [];
    setupFieldSearchKey = '';

    connectedCallback() {
        this.fetchRecentJobs();
        // Auto-poll active and recent jobs every 4 seconds for live persistent monitoring
        this.pollingTimer = setInterval(() => {
            this.fetchRecentJobs();
        }, 4000);
    }

    disconnectedCallback() {
        if (this.pollingTimer) {
            clearInterval(this.pollingTimer);
            this.pollingTimer = null;
        }
    }

    async fetchRecentJobs() {
        try {
            const jobs = await getActiveAndRecentJobs();
            this.recentJobs = jobs || [];
        } catch (ex) {
            // Polling background failover
        }
    }

    // Wire configuration
    @wire(getUploadConfigs)
    wiredConfigs(result) {
        this.wiredConfigsResult = result;
        const { data, error } = result;
        if (data) {
            this.uploadConfigs = data;
            this.objectOptions = data.map(cfg => ({
                label: `${cfg.stepBadge} - ${cfg.objectLabel} (${cfg.objectApiName})`,
                value: cfg.objectApiName
            }));

            if (this.objectOptions.length > 0) {
                // If currently selected object still exists, keep it, else pick the first
                const exists = this.objectOptions.some(o => o.value === this.selectedObjectApi);
                if (!exists) {
                    this.selectedObjectApi = this.objectOptions[0].value;
                }
                this.syncSelectedConfig();
                this.loadTemplateDetails();
            } else {
                this.selectedConfig = null;
                this.templateDetails = null;
                this.fieldMappings = [];
            }
        } else if (error) {
            this.showToast('Error', 'Failed to load upload configurations: ' + (error.body ? error.body.message : error.message), 'error');
        }
    }

    syncSelectedConfig() {
        this.selectedConfig = this.uploadConfigs.find(c => c.objectApiName === this.selectedObjectApi) || null;
        if (this.selectedConfig && this.selectedConfig.externalIdField) {
            this.activeExternalIdField = this.selectedConfig.externalIdField;
        } else {
            this.activeExternalIdField = 'External_Code__c';
        }
    }

    // Load schema & template details for current selected object
    async loadTemplateDetails() {
        if (!this.selectedObjectApi) return;
        this.isLoading = true;
        try {
            const templateName = this.selectedConfig ? this.selectedConfig.templateName : '';
            const details = await getObjectTemplateDetails({
                objectApiName: this.selectedObjectApi,
                templateName: templateName
            });

            this.templateDetails = details;
            this.fieldMappings = details.fieldMappings || [];
            if (details.externalIdField) {
                this.activeExternalIdField = details.externalIdField;
            }
        } catch (ex) {
            this.showToast('Error', 'Failed to inspect object schema: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Event Handlers
    handleObjectChange(event) {
        this.selectedObjectApi = event.detail.value;
        this.syncSelectedConfig();
        this.handleClearFile();
        this.loadTemplateDetails();
    }

    async handleRefreshAll() {
        this.handleClearFile();
        if (this.wiredConfigsResult) {
            await refreshApex(this.wiredConfigsResult);
        }
        await this.loadTemplateDetails();
        this.showToast('Refreshed', 'Configurations and schema refreshed successfully.', 'info');
    }

    handleSchemaSearch(event) {
        this.schemaSearchKey = event.target.value.toLowerCase();
    }

    // =========================================================================
    // SETUP WIZARD METHODS
    // =========================================================================
    async handleOpenSetupModal() {
        this.isSetupModalOpen = true;
        this.isSetupLoading = true;
        this.setupFieldSearchKey = '';

        try {
            const objects = await getAllEligibleObjects();
            this.allEligibleObjects = objects || [];
            this.allEligibleObjectOptions = this.allEligibleObjects.map(o => ({
                label: o.label + (o.isConfigured ? ' [Configured - Seq #' + o.currentSequence + ']' : ''),
                value: o.value
            }));

            // Default to currently selected object or first eligible
            const targetObj = this.selectedObjectApi || (this.allEligibleObjectOptions.length > 0 ? this.allEligibleObjectOptions[0].value : '');
            if (targetObj) {
                await this.initSetupForObject(targetObj);
            }
        } catch (ex) {
            this.showToast('Error', 'Failed to load eligible objects: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isSetupLoading = false;
        }
    }

    handleEditCurrentUploader() {
        if (!this.selectedObjectApi) return;
        this.handleOpenSetupModal();
    }

    async handleDeleteCurrentUploader() {
        if (!this.selectedObjectApi) return;
        const objectLabel = this.selectedConfig ? this.selectedConfig.objectLabel : this.selectedObjectApi;
        // eslint-disable-next-line no-alert
        const confirmed = confirm(`Are you sure you want to delete the uploader configuration for "${objectLabel}"? This will remove it from the studio.`);
        if (!confirmed) return;

        this.isLoading = true;
        try {
            const deleted = await deleteObjectUploadConfig({ objectApiName: this.selectedObjectApi });
            if (deleted) {
                this.showToast('Deleted', `Uploader for "${objectLabel}" was removed successfully.`, 'success');
                this.selectedObjectApi = '';
                this.selectedConfig = null;
                this.templateDetails = null;
                this.fieldMappings = [];
                this.handleClearFile();
                if (this.wiredConfigsResult) {
                    await refreshApex(this.wiredConfigsResult);
                }
            } else {
                this.showToast('Warning', 'No configuration found to delete.', 'warning');
            }
        } catch (ex) {
            this.showToast('Error', 'Failed to delete configuration: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async initSetupForObject(objectApiName) {
        this.isSetupLoading = true;
        const matchingObj = this.allEligibleObjects.find(o => o.value === objectApiName);
        const existingCfg = this.uploadConfigs.find(c => c.objectApiName === objectApiName);

        this.setupForm = {
            objectApiName: objectApiName,
            objectLabel: existingCfg ? existingCfg.objectLabel : (matchingObj ? matchingObj.label.split(' (')[0] : objectApiName),
            uploadSequence: existingCfg && existingCfg.uploadSequence ? existingCfg.uploadSequence : (this.uploadConfigs.length + 1),
            externalIdField: existingCfg && existingCfg.externalIdField ? existingCfg.externalIdField : 'External_Code__c',
            description: existingCfg && existingCfg.description ? existingCfg.description : ''
        };

        try {
            const res = await getObjectFieldsForSetup({ objectApiName: objectApiName });
            const fieldList = res.fields || [];
            this.setupFields = fieldList.map(f => ({
                ...f,
                rowClass: f.isLocked ? 'slds-theme_shade locked-row' : ''
            }));

            if (res.isAlreadyConfigured) {
                if (res.uploadSequence) this.setupForm.uploadSequence = res.uploadSequence;
                if (res.externalIdField) this.setupForm.externalIdField = res.externalIdField;
                if (res.description) this.setupForm.description = res.description;
            } else {
                if (res.uploadSequence) this.setupForm.uploadSequence = res.uploadSequence;
                if (res.externalIdField) this.setupForm.externalIdField = res.externalIdField;
            }
        } catch (ex) {
            this.showToast('Error', 'Failed to load fields for ' + objectApiName + ': ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isSetupLoading = false;
        }
    }

    async handleSetupObjectChange(event) {
        const selectedObj = event.detail.value;
        await this.initSetupForObject(selectedObj);
    }

    handleSetupLabelChange(event) {
        this.setupForm.objectLabel = event.target.value;
    }

    handleSetupSequenceChange(event) {
        this.setupForm.uploadSequence = event.target.value;
    }

    handleSetupExtIdChange(event) {
        this.setupForm.externalIdField = event.target.value;
    }

    handleSetupDescChange(event) {
        this.setupForm.description = event.target.value;
    }

    handleSetupFieldSearch(event) {
        this.setupFieldSearchKey = event.target.value.toLowerCase();
    }

    handleFieldToggle(event) {
        const fieldName = event.target.dataset.field;
        const checked = event.target.checked;
        const targetField = this.setupFields.find(f => f.fieldApiName === fieldName);
        if (targetField && !targetField.isLocked) {
            targetField.isSelected = checked;
            this.setupFields = [...this.setupFields];
        }
    }

    handleSelectAllFields() {
        this.setupFields = this.setupFields.map(f => ({ ...f, isSelected: true }));
    }

    handleSelectRequiredOnly() {
        this.setupFields = this.setupFields.map(f => ({
            ...f,
            isSelected: f.isRequired || f.isNameField
        }));
    }

    handleDeselectOptionalFields() {
        this.setupFields = this.setupFields.map(f => ({
            ...f,
            isSelected: f.isLocked || f.isRequired || f.isNameField
        }));
    }

    async handleSaveSetupConfig() {
        const selectedFieldNames = this.setupFields.filter(f => f.isSelected).map(f => f.fieldApiName);
        if (selectedFieldNames.length === 0) {
            this.showToast('Warning', 'Please select at least one field to include in the CSV template.', 'warning');
            return;
        }

        this.isSetupLoading = true;
        try {
            const payload = {
                objectApiName: this.setupForm.objectApiName,
                objectLabel: this.setupForm.objectLabel,
                uploadSequence: this.setupForm.uploadSequence,
                externalIdField: this.setupForm.externalIdField,
                description: this.setupForm.description,
                selectedFields: selectedFieldNames
            };

            const savedConfig = await saveObjectUploadConfig({ configJson: JSON.stringify(payload) });

            this.showToast('Success', `Uploader configured successfully for ${savedConfig.objectLabel}!`, 'success');
            this.isSetupModalOpen = false;

            // Refresh configurations and auto-select newly saved object
            this.selectedObjectApi = savedConfig.objectApiName;
            if (this.wiredConfigsResult) {
                await refreshApex(this.wiredConfigsResult);
            }
            await this.loadTemplateDetails();
        } catch (ex) {
            this.showToast('Error', 'Failed to save configuration: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isSetupLoading = false;
        }
    }

    async handleDeleteConfig() {
        if (!confirm(`Are you sure you want to delete the uploader configuration for ${this.setupForm.objectLabel}?`)) {
            return;
        }
        this.isSetupLoading = true;
        try {
            await deleteObjectUploadConfig({ objectApiName: this.setupForm.objectApiName });
            this.showToast('Deleted', `Uploader for ${this.setupForm.objectLabel} was removed.`, 'info');
            this.isSetupModalOpen = false;
            this.selectedObjectApi = '';
            if (this.wiredConfigsResult) {
                await refreshApex(this.wiredConfigsResult);
            }
        } catch (ex) {
            this.showToast('Error', 'Failed to delete configuration: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isSetupLoading = false;
        }
    }

    handleDownloadSetupPreviewCsv() {
        const headerText = this.generatedCsvHeaderPreview;
        if (!headerText) return;
        const fileName = `${this.setupForm.objectApiName}_Template.csv`;
        this.triggerFileDownload(fileName, headerText + '\n');
    }

    handleCloseSetupModal() {
        this.isSetupModalOpen = false;
    }

    // =========================================================================
    // DRAG & DROP AND FILE PROCESSING
    // =========================================================================
    handleDragOver(event) {
        event.preventDefault();
        this.isDragOver = true;
    }

    handleDragLeave(event) {
        event.preventDefault();
        this.isDragOver = false;
    }

    handleDrop(event) {
        event.preventDefault();
        this.isDragOver = false;
        if (event.dataTransfer.files && event.dataTransfer.files.length > 0) {
            this.processSelectedFile(event.dataTransfer.files[0]);
        }
    }

    handleFileSelect(event) {
        if (event.target.files && event.target.files.length > 0) {
            this.processSelectedFile(event.target.files[0]);
        }
    }

    processSelectedFile(file) {
        if (!file.name.toLowerCase().endsWith('.csv')) {
            this.showToast('Invalid File', 'Please select a valid .csv file.', 'error');
            return;
        }

        this.fileName = file.name;
        this.fileSizeFormatted = this.formatFileSize(file.size);
        this.isLoading = true;

        const reader = new FileReader();
        reader.onload = (e) => {
            const textContent = e.target.result;
            this.parseCsvContent(textContent);
            this.isLoading = false;
        };
        reader.onerror = () => {
            this.showToast('Error', 'Unable to read the chosen file.', 'error');
            this.isLoading = false;
        };
        reader.readAsText(file);
    }

    // RFC 4180 Compliant CSV Parser
    parseCsvContent(text) {
        if (!text || !text.trim()) {
            this.showToast('Empty File', 'The selected CSV file has no content.', 'warning');
            this.handleClearFile();
            return;
        }

        const rows = this.parseCsvIntoArray(text);
        if (rows.length === 0) {
            this.showToast('Warning', 'No valid rows found in CSV.', 'warning');
            return;
        }

        // Header row
        this.parsedHeaders = rows[0].map(h => (h ? h.trim() : ''));
        const dataRows = rows.slice(1).filter(r => r.some(cell => cell && cell.trim().length > 0));

        this.parsedRows = dataRows.map(r => {
            const rowObj = {};
            this.parsedHeaders.forEach((header, index) => {
                rowObj[header] = r[index] !== undefined ? r[index].trim() : '';
            });
            return rowObj;
        });

        // Generate Preview Rows
        const previewLimit = Math.min(this.parsedRows.length, PREVIEW_LIMIT);
        this.previewRows = this.parsedRows.slice(0, previewLimit).map((row, idx) => {
            const cells = this.parsedHeaders.map(h => ({
                header: h,
                value: row[h] || ''
            }));
            return {
                _rowId: 'preview_' + idx,
                _rowNumber: idx + 1,
                cells: cells
            };
        });

        this.hasCompletedResults = false;
        this.aggregatedErrors = [];
    }

    parseCsvIntoArray(text) {
        const result = [];
        let currentRow = [];
        let currentField = '';
        let insideQuote = false;

        for (let i = 0; i < text.length; i++) {
            const char = text[i];
            const nextChar = text[i + 1];

            if (char === '"') {
                if (insideQuote && nextChar === '"') {
                    currentField += '"';
                    i++; // skip escaped quote
                } else {
                    insideQuote = !insideQuote;
                }
            } else if (char === ',' && !insideQuote) {
                currentRow.push(currentField);
                currentField = '';
            } else if ((char === '\r' || char === '\n') && !insideQuote) {
                if (char === '\r' && nextChar === '\n') {
                    i++; // handle CRLF
                }
                currentRow.push(currentField);
                currentField = '';
                if (currentRow.length > 0 && currentRow.some(c => c.trim().length > 0)) {
                    result.push(currentRow);
                }
                currentRow = [];
            } else {
                currentField += char;
            }
        }

        if (currentField.length > 0 || currentRow.length > 0) {
            currentRow.push(currentField);
            if (currentRow.some(c => c.trim().length > 0)) {
                result.push(currentRow);
            }
        }

        return result;
    }

    handleClearFile() {
        this.fileName = '';
        this.fileSizeFormatted = '';
        this.parsedHeaders = [];
        this.parsedRows = [];
        this.previewRows = [];
        this.hasCompletedResults = false;
        this.aggregatedErrors = [];
        this.progressPercentage = 0;
        this.progressStatusText = '';
    }

    // Execute Bulk Ingestion in sequential chunks with persistent Salesforce Job tracking
    async handleExecuteUpload() {
        if (this.parsedRows.length === 0) {
            this.showToast('Warning', 'No rows available to upload.', 'warning');
            return;
        }

        // Concurrency check: fetch current active jobs
        await this.fetchRecentJobs();
        if (this.activeJobsCount >= 3) {
            this.showToast(
                'Parallel Limit Reached',
                'Maximum 3 parallel upload jobs can run simultaneously. Please wait for an active job to complete.',
                'warning'
            );
            return;
        }

        this.isUploading = true;
        this.progressPercentage = 0;
        this.hasCompletedResults = false;
        this.aggregatedErrors = [];

        const totalRows = this.parsedRows.length;
        const totalBatches = Math.ceil(totalRows / BATCH_CHUNK_SIZE);

        let totalSuccess = 0;
        let totalFailure = 0;
        let trackedJobId = null;

        try {
            // 1. Initiate Persistent Job in Salesforce DB
            trackedJobId = await initiateUploadJob({
                objectApiName: this.selectedObjectApi,
                objectLabel: this.currentObjectLabel,
                fileName: this.fileName,
                totalRows: totalRows
            });
            this.activeJobId = trackedJobId;
            await this.fetchRecentJobs();

            // 2. Process in batch chunks
            for (let batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
                const startIndex = batchIndex * BATCH_CHUNK_SIZE;
                const endIndex = Math.min(startIndex + BATCH_CHUNK_SIZE, totalRows);
                const chunk = this.parsedRows.slice(startIndex, endIndex);

                this.progressStatusText = `Uploading Batch ${batchIndex + 1} of ${totalBatches} (${startIndex + 1}–${endIndex} of ${totalRows} records)...`;

                const chunkResult = await uploadBatch({
                    objectApiName: this.selectedObjectApi,
                    rowsJson: JSON.stringify(chunk),
                    externalIdFieldOverride: this.activeExternalIdField
                });

                let chunkErrorsSerialized = '';

                if (chunkResult) {
                    const cSuccess = chunkResult.successCount || 0;
                    const cFailure = chunkResult.failureCount || 0;
                    totalSuccess += cSuccess;
                    totalFailure += cFailure;

                    if (chunkResult.rowErrors && chunkResult.rowErrors.length > 0) {
                        const errorLines = [];
                        chunkResult.rowErrors.forEach(err => {
                            const absRow = startIndex + err.rowIndex;
                            this.aggregatedErrors.push({
                                key: `err_${absRow}`,
                                rowIndex: absRow,
                                externalCode: err.externalCode || 'N/A',
                                errorMessage: err.errorMessage
                            });
                            errorLines.push(`Row ${absRow} [${err.externalCode || 'N/A'}]: ${err.errorMessage}`);
                        });
                        chunkErrorsSerialized = errorLines.join('\n');
                    }

                    // 3. Update persistent Job progress in Salesforce
                    if (trackedJobId) {
                        await updateJobProgress({
                            jobId: trackedJobId,
                            chunkSuccess: cSuccess,
                            chunkFailure: cFailure,
                            processedSoFar: endIndex,
                            totalRows: totalRows,
                            serializedErrors: chunkErrorsSerialized
                        });
                    }
                }

                this.progressPercentage = Math.round(((batchIndex + 1) / totalBatches) * 100);
                this.fetchRecentJobs();
            }

            this.resultsSummary = {
                totalProcessed: totalRows,
                totalSuccess: totalSuccess,
                totalFailure: totalFailure
            };

            this.hasCompletedResults = true;

            if (totalFailure === 0) {
                this.showToast('Success', `All ${totalSuccess} records upserted successfully!`, 'success');
            } else {
                this.showToast('Completed with Warnings', `${totalSuccess} succeeded, ${totalFailure} failed. Review error log below.`, 'warning');
            }
        } catch (ex) {
            if (trackedJobId) {
                await markJobFailed({
                    jobId: trackedJobId,
                    errorMessage: ex.body ? ex.body.message : ex.message
                });
            }
            this.showToast('Upload Failed', 'An error occurred during ingestion: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isUploading = false;
            await this.fetchRecentJobs();
        }
    }

    // Download Error Log CSV directly from persistent Job record
    async handleDownloadJobErrorCsv(event) {
        const jobId = event.currentTarget.dataset.jobId;
        if (!jobId) return;

        const job = this.recentJobs.find(j => j.recordId === jobId);
        this.isLoading = true;
        try {
            const rawLog = await getJobErrorLog({ jobId: jobId });
            if (!rawLog || !rawLog.trim()) {
                this.showToast('Info', 'No detailed error log entries recorded for this job.', 'info');
                return;
            }

            const csvLines = ['Row_Index,External_Code,Error_Reason'];
            const lines = rawLog.split('\n');
            lines.forEach(line => {
                if (line.trim()) {
                    const match = line.match(/^Row\s+(\d+)\s+\[([^\]]*)\]:\s*(.*)$/);
                    if (match) {
                        csvLines.push(`${match[1]},${this.escapeCsvCell(match[2])},${this.escapeCsvCell(match[3])}`);
                    } else {
                        csvLines.push(`N/A,N/A,${this.escapeCsvCell(line)}`);
                    }
                }
            });

            const fileName = `${job ? job.objectApiName : 'Upload'}_Errors_${job ? job.jobId : 'Log'}.csv`;
            this.triggerFileDownload(fileName, csvLines.join('\n'));
            this.showToast('Success', 'Error CSV downloaded successfully.', 'success');
        } catch (ex) {
            this.showToast('Error', 'Failed to retrieve error log: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Download CSV Template
    async handleDownloadTemplate() {
        if (!this.selectedObjectApi) {
            this.showToast('Info', 'Please select an object first to download its template.', 'info');
            return;
        }

        this.isLoading = true;
        try {
            let csvContent = this.templateDetails ? this.templateDetails.rawCsvTemplate : '';
            if (!csvContent) {
                const details = await getObjectTemplateDetails({
                    objectApiName: this.selectedObjectApi,
                    templateName: ''
                });
                this.templateDetails = details;
                this.fieldMappings = details.fieldMappings || [];
                csvContent = details.rawCsvTemplate;
            }

            if (!csvContent) {
                this.showToast('Warning', 'Could not generate CSV template for ' + this.selectedObjectApi, 'warning');
                return;
            }

            const fileName = `${this.selectedObjectApi}_Template.csv`;
            this.triggerFileDownload(fileName, csvContent);
            this.showToast('Success', `CSV Template for ${this.currentObjectLabel} downloaded successfully.`, 'success');
        } catch (ex) {
            this.showToast('Error', 'Failed to download template: ' + (ex.body ? ex.body.message : ex.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Download Error Log CSV
    handleDownloadErrorLog() {
        if (this.aggregatedErrors.length === 0) return;

        const errorHeaders = [...this.parsedHeaders, 'UPLOAD_ERROR'];
        const csvLines = [errorHeaders.map(h => this.escapeCsvCell(h)).join(',')];

        const errorMap = new Map();
        this.aggregatedErrors.forEach(err => {
            errorMap.set(err.rowIndex, err.errorMessage);
        });

        this.parsedRows.forEach((row, idx) => {
            const csvRowIndex = idx + 1;
            if (errorMap.has(csvRowIndex)) {
                const lineCells = this.parsedHeaders.map(h => this.escapeCsvCell(row[h] || ''));
                lineCells.push(this.escapeCsvCell(errorMap.get(csvRowIndex)));
                csvLines.push(lineCells.join(','));
            }
        });

        const csvOutput = csvLines.join('\n');
        const fileName = `${this.selectedObjectApi}_Upload_Errors.csv`;
        this.triggerFileDownload(fileName, csvOutput);
    }

    triggerFileDownload(fileName, content) {
        try {
            const BOM = '\uFEFF';
            const blob = new Blob([BOM + content], { type: 'text/csv;charset=utf-8;' });

            if (window.navigator && window.navigator.msSaveOrOpenBlob) {
                window.navigator.msSaveOrOpenBlob(blob, fileName);
                return;
            }

            const url = window.URL.createObjectURL(blob);
            const link = document.createElement('a');
            link.href = url;
            link.setAttribute('download', fileName);
            link.style.display = 'none';
            document.body.appendChild(link);
            link.click();

            // Do NOT revoke immediately! Delay revoke so browser starts download stream
            setTimeout(() => {
                try {
                    document.body.removeChild(link);
                    window.URL.revokeObjectURL(url);
                } catch (e) {
                    // Ignore cleanup error
                }
            }, 1000);
        } catch (e) {
            // Fallback using Data URI
            const encodedUri = encodeURI('data:text/csv;charset=utf-8,\uFEFF' + content);
            const link = document.createElement('a');
            link.setAttribute('href', encodedUri);
            link.setAttribute('download', fileName);
            link.style.display = 'none';
            document.body.appendChild(link);
            link.click();
            setTimeout(() => {
                try {
                    document.body.removeChild(link);
                } catch (err) {
                    // Ignore
                }
            }, 1000);
        }
    }

    escapeCsvCell(value) {
        if (value === null || value === undefined) return '""';
        const str = String(value);
        if (str.includes(',') || str.includes('"') || str.includes('\n') || str.includes('\r')) {
            return `"${str.replace(/"/g, '""')}"`;
        }
        return `"${str}"`;
    }

    formatFileSize(bytes) {
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / 1048576).toFixed(1) + ' MB';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // Getters & Computed Properties
    get dropzoneClass() {
        return `slds-box dropzone-box ${this.isDragOver ? 'dropzone-active' : ''}`;
    }

    get hasPreviewData() {
        return this.previewRows && this.previewRows.length > 0;
    }

    get previewRowCount() {
        return this.previewRows ? this.previewRows.length : 0;
    }

    get totalCsvRows() {
        return this.parsedRows ? this.parsedRows.length : 0;
    }

    get hasUploadConfigs() {
        return Array.isArray(this.uploadConfigs) && this.uploadConfigs.length > 0;
    }

    get activeJobsCount() {
        return this.recentJobs ? this.recentJobs.filter(j => j.isProcessing).length : 0;
    }

    get hasRecentJobs() {
        return this.recentJobs && this.recentJobs.length > 0;
    }

    get topThreeJobs() {
        return this.recentJobs ? this.recentJobs.slice(0, 3) : [];
    }

    get jobSlots() {
        const slots = [];
        const jobs = this.recentJobs || [];
        for (let i = 0; i < 3; i++) {
            if (i < jobs.length) {
                slots.push({
                    slotIndex: i + 1,
                    isOccupied: true,
                    ...jobs[i]
                });
            } else {
                slots.push({
                    slotIndex: i + 1,
                    isOccupied: false,
                    slotLabel: `Slot ${i + 1} — Idle / Ready`,
                    recordId: `slot_empty_${i + 1}`
                });
            }
        }
        return slots;
    }

    get parallelSlotsBadge() {
        return `${this.activeJobsCount} / 3 Active Slots`;
    }

    get parallelSlotsBadgeClass() {
        return this.activeJobsCount >= 3 ? 'slds-badge slds-theme_error font-weight-bold' : 'slds-badge slds-theme_success font-weight-bold';
    }

    get isTemplateDownloadDisabled() {
        return !this.hasUploadConfigs || !this.selectedObjectApi;
    }

    get currentObjectLabel() {
        return this.selectedConfig ? this.selectedConfig.objectLabel : (this.selectedObjectApi || 'Object');
    }

    get templateColumnCount() {
        return this.fieldMappings && this.fieldMappings.length > 0
            ? this.fieldMappings.length
            : (this.templateDetails && this.templateDetails.expectedHeaders ? this.templateDetails.expectedHeaders.length : 0);
    }

    get isUploadDisabled() {
        return this.isUploading || this.parsedRows.length === 0 || this.missingRequiredHeaders.length > 0;
    }

    get uploadButtonLabel() {
        return this.isUploading ? 'Ingesting Batch...' : `Upload ${this.totalCsvRows} Records to ${this.selectedConfig ? this.selectedConfig.objectLabel : 'Salesforce'}`;
    }

    get missingRequiredHeaders() {
        if (!this.fieldMappings || this.parsedHeaders.length === 0) return [];
        const currentHeadersLower = new Set(this.parsedHeaders.map(h => h.toLowerCase()));
        const missing = [];

        this.fieldMappings.forEach(f => {
            if (f.isRequired) {
                const found = currentHeadersLower.has(f.headerName.toLowerCase()) || currentHeadersLower.has(f.fieldApiName.toLowerCase());
                if (!found) {
                    missing.push(f.headerName || f.fieldApiName);
                }
            }
        });

        return missing;
    }

    get missingRequiredHeadersString() {
        return this.missingRequiredHeaders.join(', ');
    }

    get hasErrors() {
        return this.aggregatedErrors && this.aggregatedErrors.length > 0;
    }

    get filteredFieldMappings() {
        if (!this.fieldMappings) return [];
        if (!this.schemaSearchKey) return this.fieldMappings;

        return this.fieldMappings.filter(f =>
            (f.headerName && f.headerName.toLowerCase().includes(this.schemaSearchKey)) ||
            (f.fieldLabel && f.fieldLabel.toLowerCase().includes(this.schemaSearchKey)) ||
            (f.fieldApiName && f.fieldApiName.toLowerCase().includes(this.schemaSearchKey)) ||
            (f.mappingNote && f.mappingNote.toLowerCase().includes(this.schemaSearchKey))
        );
    }

    get filteredSetupFields() {
        if (!this.setupFields) return [];
        if (!this.setupFieldSearchKey) return this.setupFields;

        return this.setupFields.filter(f =>
            (f.fieldLabel && f.fieldLabel.toLowerCase().includes(this.setupFieldSearchKey)) ||
            (f.fieldApiName && f.fieldApiName.toLowerCase().includes(this.setupFieldSearchKey)) ||
            (f.dataType && f.dataType.toLowerCase().includes(this.setupFieldSearchKey)) ||
            (f.mappingNote && f.mappingNote.toLowerCase().includes(this.setupFieldSearchKey))
        );
    }

    get selectedFieldCount() {
        return this.setupFields ? this.setupFields.filter(f => f.isSelected).length : 0;
    }

    get generatedCsvHeaderPreview() {
        if (!this.setupFields) return '';
        const selected = this.setupFields.filter(f => f.isSelected).map(f => f.fieldApiName);
        return selected.join(',');
    }

    get isObjectAlreadyConfigured() {
        if (!this.setupForm.objectApiName || !this.allEligibleObjects) return false;
        const match = this.allEligibleObjects.find(o => o.value === this.setupForm.objectApiName);
        return match && match.isConfigured;
    }

    get existingConfigSequence() {
        if (!this.setupForm.objectApiName || !this.allEligibleObjects) return 1;
        const match = this.allEligibleObjects.find(o => o.value === this.setupForm.objectApiName);
        return match && match.currentSequence ? match.currentSequence : 1;
    }

    get isSaveSetupDisabled() {
        return this.isSetupLoading || !this.setupForm.objectApiName || this.selectedFieldCount === 0;
    }
}
