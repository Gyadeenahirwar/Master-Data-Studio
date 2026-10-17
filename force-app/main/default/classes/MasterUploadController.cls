/**
 * @description Controller for Master Data Studio.
 * Completely dynamic, metadata-driven uploader and setup wizard for any SObject.
 */
public without sharing class MasterUploadController {

    public class UploadConfigWrapper {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String developerName { get; set; }
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String objectLabel { get; set; }
        @AuraEnabled public Decimal uploadSequence { get; set; }
        @AuraEnabled public String templateName { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public String externalIdField { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String selectedFields { get; set; }
        @AuraEnabled public String stepBadge { get; set; }
        @AuraEnabled public Integer totalSteps { get; set; }
        @AuraEnabled public Boolean isCustomObject { get; set; }
    }

    public class ObjectOptionInfo {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public Boolean isCustom { get; set; }
        @AuraEnabled public Boolean isConfigured { get; set; }
        @AuraEnabled public Decimal currentSequence { get; set; }
    }

    public class FieldSetupInfo {
        @AuraEnabled public String fieldApiName { get; set; }
        @AuraEnabled public String fieldLabel { get; set; }
        @AuraEnabled public String dataType { get; set; }
        @AuraEnabled public Boolean isRequired { get; set; }
        @AuraEnabled public Boolean isExternalId { get; set; }
        @AuraEnabled public Boolean isNameField { get; set; }
        @AuraEnabled public Boolean isLookup { get; set; }
        @AuraEnabled public String referenceTo { get; set; }
        @AuraEnabled public String referenceLabel { get; set; }
        @AuraEnabled public String mappingNote { get; set; }
        @AuraEnabled public Boolean isSelected { get; set; }
        @AuraEnabled public Boolean isLocked { get; set; }
    }

    public class FieldSetupResponse {
        @AuraEnabled public List<FieldSetupInfo> fields { get; set; }
        @AuraEnabled public Decimal uploadSequence { get; set; }
        @AuraEnabled public String externalIdField { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Boolean isAlreadyConfigured { get; set; }
    }

    public class FieldMappingInfo {
        @AuraEnabled public String headerName { get; set; }
        @AuraEnabled public String fieldApiName { get; set; }
        @AuraEnabled public String fieldLabel { get; set; }
        @AuraEnabled public String dataType { get; set; }
        @AuraEnabled public Boolean isRequired { get; set; }
        @AuraEnabled public Boolean isLookup { get; set; }
        @AuraEnabled public String referenceTo { get; set; }
        @AuraEnabled public String referenceLabel { get; set; }
        @AuraEnabled public String mappingNote { get; set; }
    }

    public class TemplateDetailWrapper {
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String objectLabel { get; set; }
        @AuraEnabled public String externalIdField { get; set; }
        @AuraEnabled public String templateName { get; set; }
        @AuraEnabled public Boolean templateFound { get; set; }
        @AuraEnabled public String rawCsvTemplate { get; set; }
        @AuraEnabled public List<String> expectedHeaders { get; set; }
        @AuraEnabled public List<FieldMappingInfo> fieldMappings { get; set; }

        public TemplateDetailWrapper() {
            this.expectedHeaders = new List<String>();
            this.fieldMappings = new List<FieldMappingInfo>();
            this.templateFound = false;
        }
    }

    public class UploadJobInfo {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String jobId { get; set; }
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String objectLabel { get; set; }
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer totalRows { get; set; }
        @AuraEnabled public Integer successRows { get; set; }
        @AuraEnabled public Integer failedRows { get; set; }
        @AuraEnabled public Decimal progressPercent { get; set; }
        @AuraEnabled public Datetime startTime { get; set; }
        @AuraEnabled public Datetime completedTime { get; set; }
        @AuraEnabled public Boolean hasErrors { get; set; }
        @AuraEnabled public Boolean isProcessing { get; set; }
        @AuraEnabled public String statusBadgeClass { get; set; }
        @AuraEnabled public Datetime createdDate { get; set; }
    }

    /**
     * @description Fetches all eligible standard and custom objects in the org for setup.
     */
    @AuraEnabled(cacheable=true)
    public static List<ObjectOptionInfo> getAllEligibleObjects() {
        try {
            Map<String, SObjectType> gd = Schema.getGlobalDescribe();
            Map<String, Decimal> configuredObjMap = new Map<String, Decimal>();

            // Check Master_Data_Studio_Config__c
            for (Master_Data_Studio_Config__c c : [
                SELECT Object_API_Name__c, Upload_Sequence__c
                FROM Master_Data_Studio_Config__c
            ]) {
                configuredObjMap.put(c.Object_API_Name__c.toLowerCase(), c.Upload_Sequence__c);
            }

            List<ObjectOptionInfo> options = new List<ObjectOptionInfo>();
            for (String objName : gd.keySet()) {
                // Filter out non-ingestible system objects
                if (objName.endsWith('__share') || objName.endsWith('__history') ||
                    objName.endsWith('__feed') || objName.endsWith('__tag') ||
                    objName.endsWith('__changeevent') || objName.endsWith('__mdt')) {
                    continue;
                }

                Schema.DescribeSObjectResult d = gd.get(objName).getDescribe();
                if (!d.isCreateable() || d.isCustomSetting()) {
                    continue;
                }

                ObjectOptionInfo opt = new ObjectOptionInfo();
                opt.value = d.getName();
                opt.label = d.getLabel() + ' (' + d.getName() + ')';
                opt.isCustom = d.isCustom();
                opt.isConfigured = configuredObjMap.containsKey(d.getName().toLowerCase());
                opt.currentSequence = configuredObjMap.get(d.getName().toLowerCase());
                options.add(opt);
            }

            options.sort(new ObjectOptionComparator());
            return options;
        } catch (Exception ex) {
            AuraHandledException aEx = new AuraHandledException('Failed to list org objects: ' + ex.getMessage());
            aEx.setMessage('Failed to list org objects: ' + ex.getMessage());
            throw aEx;
        }
    }

    /**
     * @description Comparator to sort ObjectOptionInfo by label alphabetically.
     */
    private class ObjectOptionComparator implements System.Comparator<ObjectOptionInfo> {
        public Integer compare(ObjectOptionInfo o1, ObjectOptionInfo o2) {
            if (o1.label == null && o2.label == null) return 0;
            if (o1.label == null) return -1;
            if (o2.label == null) return 1;
            return o1.label.toLowerCase().compareTo(o2.label.toLowerCase());
        }
    }

    /**
     * @description Fetches all createable fields for an object to display in the Setup Wizard.
     */
    @AuraEnabled
    public static FieldSetupResponse getObjectFieldsForSetup(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            AuraHandledException ex = new AuraHandledException('Object API Name is required.');
            ex.setMessage('Object API Name is required.');
            throw ex;
        }

        try {
            Schema.SObjectType sType = Schema.getGlobalDescribe().get(objectApiName);
            if (sType == null) {
                AuraHandledException ex = new AuraHandledException('Object \'' + objectApiName + '\' does not exist.');
                ex.setMessage('Object \'' + objectApiName + '\' does not exist.');
                throw ex;
            }

            Schema.DescribeSObjectResult describe = sType.getDescribe();
            Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();

            // Check if there is an existing configured selection
            Set<String> savedSelectedFields = new Set<String>();
            List<Master_Data_Studio_Config__c> existingConfigs = [
                SELECT Selected_Fields__c, Upload_Sequence__c, External_Id_Field__c, Description__c
                FROM Master_Data_Studio_Config__c
                WHERE Object_API_Name__c = :objectApiName
                LIMIT 1
            ];
            if (!existingConfigs.isEmpty() && String.isNotBlank(existingConfigs[0].Selected_Fields__c)) {
                for (String f : existingConfigs[0].Selected_Fields__c.split(',')) {
                    savedSelectedFields.add(f.trim().toLowerCase());
                }
            }

            List<FieldSetupInfo> fieldsList = new List<FieldSetupInfo>();
            for (String fName : fieldMap.keySet()) {
                Schema.DescribeFieldResult dfr = fieldMap.get(fName).getDescribe();

                // Exclude read-only, calculated formulas, and system audit fields
                if (!dfr.isCreateable() || dfr.isCalculated()) {
                    continue;
                }
                String actualApi = dfr.getName();
                if (actualApi.equalsIgnoreCase('Id') || actualApi.equalsIgnoreCase('IsDeleted')) {
                    continue;
                }

                FieldSetupInfo info = new FieldSetupInfo();
                info.fieldApiName = actualApi;
                info.fieldLabel = dfr.getLabel();
                info.dataType = String.valueOf(dfr.getType());
                info.isRequired = (!dfr.isNillable() && !dfr.isDefaultedOnCreate());
                info.isExternalId = dfr.isExternalId();
                info.isNameField = dfr.isNameField();
                info.isLookup = (dfr.getType() == Schema.DisplayType.REFERENCE);

                if (info.isLookup) {
                    List<Schema.SObjectType> refs = dfr.getReferenceTo();
                    if (!refs.isEmpty()) {
                        Schema.DescribeSObjectResult parentDesc = refs[0].getDescribe();
                        info.referenceTo = parentDesc.getName();
                        info.referenceLabel = parentDesc.getLabel();
                        String parentExt = MasterDataUploadHandler.resolveParentExternalIdField(parentDesc);
                        info.mappingNote = 'Resolved via parent ' + parentDesc.getName() + '.' + parentExt;
                    }
                } else if (info.isExternalId) {
                    info.mappingNote = 'External ID primary upsert key';
                } else if (info.isRequired) {
                    info.mappingNote = 'Mandatory Salesforce required field';
                } else {
                    info.mappingNote = 'Direct field value';
                }

                // If saved fields exist, honor saved selection. Otherwise, default required, name, external ID to selected.
                if (!savedSelectedFields.isEmpty()) {
                    info.isSelected = savedSelectedFields.contains(actualApi.toLowerCase()) || info.isRequired || info.isNameField;
                } else {
                    info.isSelected = (info.isRequired || info.isNameField || info.isExternalId || info.isLookup || fieldsList.size() < 10);
                }

                // Lock required & name fields so admin cannot accidentally exclude mandatory data
                info.isLocked = (info.isRequired || info.isNameField);
                fieldsList.add(info);
            }

            FieldSetupResponse response = new FieldSetupResponse();
            response.fields = fieldsList;
            response.isAlreadyConfigured = !existingConfigs.isEmpty();
            if (!existingConfigs.isEmpty()) {
                response.uploadSequence = existingConfigs[0].Upload_Sequence__c;
                response.externalIdField = existingConfigs[0].External_Id_Field__c;
                response.description = existingConfigs[0].Description__c;
            } else {
                Integer existingCount = [SELECT COUNT() FROM Master_Data_Studio_Config__c];
                response.uploadSequence = existingCount + 1;
                // auto-detect external id field if present
                for (FieldSetupInfo f : fieldsList) {
                    if (f.isExternalId) {
                        response.externalIdField = f.fieldApiName;
                        break;
                    }
                }
            }

            return response;
        } catch (Exception ex) {
            AuraHandledException aEx = new AuraHandledException('Error fetching object fields: ' + ex.getMessage());
            aEx.setMessage('Error fetching object fields: ' + ex.getMessage());
            throw aEx;
        }
    }

    /**
     * @description Saves or updates an object uploader configuration in Master_Data_Studio_Config__c.
     */
    @AuraEnabled
    public static UploadConfigWrapper saveObjectUploadConfig(String configJson) {
        if (String.isBlank(configJson)) {
            AuraHandledException ex = new AuraHandledException('Configuration data is required.');
            ex.setMessage('Configuration data is required.');
            throw ex;
        }

        try {
            Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(configJson);
            String objApi = (String) params.get('objectApiName');
            String objLabel = (String) params.get('objectLabel');
            Decimal seq = params.containsKey('uploadSequence') && params.get('uploadSequence') != null ?
                          Decimal.valueOf(String.valueOf(params.get('uploadSequence'))) : 1;
            String extIdField = (String) params.get('externalIdField');
            String descr = (String) params.get('description');

            List<Object> rawFields = (List<Object>) params.get('selectedFields');
            List<String> selectedFieldNames = new List<String>();
            if (rawFields != null) {
                for (Object rf : rawFields) {
                    selectedFieldNames.add(String.valueOf(rf));
                }
            }

            // Find existing record by Object API Name
            List<Master_Data_Studio_Config__c> existing = [
                SELECT Id, Object_API_Name__c, Object_Label__c, Upload_Sequence__c,
                       External_Id_Field__c, Template_Name__c, Selected_Fields__c, Active__c, Description__c
                FROM Master_Data_Studio_Config__c
                WHERE Object_API_Name__c = :objApi
                LIMIT 1
            ];

            Master_Data_Studio_Config__c record = existing.isEmpty() ? new Master_Data_Studio_Config__c() : existing[0];
            record.Object_API_Name__c = objApi;
            record.Object_Label__c = String.isNotBlank(objLabel) ? objLabel : objApi;
            record.Upload_Sequence__c = seq;
            record.External_Id_Field__c = extIdField;
            record.Template_Name__c = objApi.replace('__c', '') + '_Template';
            record.Selected_Fields__c = String.join(selectedFieldNames, ',');
            record.Active__c = true;
            record.Description__c = descr;

            upsert record Object_API_Name__c;

            UploadConfigWrapper w = new UploadConfigWrapper();
            w.id = record.Id;
            w.objectApiName = record.Object_API_Name__c;
            w.objectLabel = record.Object_Label__c;
            w.uploadSequence = record.Upload_Sequence__c;
            w.templateName = record.Template_Name__c;
            w.externalIdField = record.External_Id_Field__c;
            w.description = record.Description__c;
            w.selectedFields = record.Selected_Fields__c;
            w.active = record.Active__c;

            return w;
        } catch (Exception ex) {
            AuraHandledException aEx = new AuraHandledException('Error saving upload configuration: ' + ex.getMessage());
            aEx.setMessage('Error saving upload configuration: ' + ex.getMessage());
            throw aEx;
        }
    }

    /**
     * @description Deletes a configured object upload config.
     */
    @AuraEnabled
    public static Boolean deleteObjectUploadConfig(String objectApiName) {
        if (String.isBlank(objectApiName)) return false;
        try {
            List<Master_Data_Studio_Config__c> records = [
                SELECT Id FROM Master_Data_Studio_Config__c WHERE Object_API_Name__c = :objectApiName
            ];
            if (!records.isEmpty()) {
                delete records;
                return true;
            }
            return false;
        } catch (Exception ex) {
            AuraHandledException aEx = new AuraHandledException('Failed to delete config: ' + ex.getMessage());
            aEx.setMessage('Failed to delete config: ' + ex.getMessage());
            throw aEx;
        }
    }

    /**
     * @description Fetches active master upload configurations ordered by upload sequence.
     * Prioritizes dynamic custom records from Master_Data_Studio_Config__c, falls back to Master_Upload_Config__mdt.
     */
    @AuraEnabled(cacheable=true)
    public static List<UploadConfigWrapper> getUploadConfigs() {
        try {
            List<UploadConfigWrapper> resultList = new List<UploadConfigWrapper>();

            // Query Custom Object records configured by users
            List<Master_Data_Studio_Config__c> customConfigs = [
                SELECT Id, Object_API_Name__c, Object_Label__c, Upload_Sequence__c,
                       Template_Name__c, Active__c, External_Id_Field__c, Description__c, Selected_Fields__c
                FROM Master_Data_Studio_Config__c
                WHERE Active__c = true
                ORDER BY Upload_Sequence__c ASC NULLS LAST, Object_Label__c ASC
            ];

            Integer total = customConfigs.size();
            for (Integer i = 0; i < total; i++) {
                Master_Data_Studio_Config__c c = customConfigs[i];
                UploadConfigWrapper w = new UploadConfigWrapper();
                w.id = c.Id;
                w.developerName = c.Object_API_Name__c.replace('__c', '');
                w.objectApiName = c.Object_API_Name__c;
                w.objectLabel = String.isNotBlank(c.Object_Label__c) ? c.Object_Label__c : c.Object_API_Name__c;
                w.uploadSequence = c.Upload_Sequence__c != null ? c.Upload_Sequence__c : (i + 1);
                w.templateName = c.Template_Name__c;
                w.active = c.Active__c;
                w.externalIdField = c.External_Id_Field__c;
                w.description = c.Description__c;
                w.selectedFields = c.Selected_Fields__c;
                w.stepBadge = 'Step ' + (i + 1) + ' of ' + total;
                w.totalSteps = total;
                resultList.add(w);
            }

            return resultList;
        } catch (Exception ex) {
            AuraHandledException aEx = new AuraHandledException('Error fetching upload configurations: ' + ex.getMessage());
            aEx.setMessage('Error fetching upload configurations: ' + ex.getMessage());
            throw aEx;
        }
    }

    /**
     * @description Introspects the target object schema and dynamically generates the CSV template.
     */
    @AuraEnabled
    public static TemplateDetailWrapper getObjectTemplateDetails(String objectApiName, String templateName) {
        if (String.isBlank(objectApiName)) {
            AuraHandledException ex = new AuraHandledException('Object API Name is required.');
            ex.setMessage('Object API Name is required.');
            throw ex;
        }

        try {
            TemplateDetailWrapper wrapper = new TemplateDetailWrapper();
            wrapper.objectApiName = objectApiName;
            wrapper.templateName = templateName;

            // 1. Describe Target Object
            Schema.SObjectType targetType = Schema.getGlobalDescribe().get(objectApiName);
            if (targetType == null) {
                AuraHandledException ex = new AuraHandledException('Object \'' + objectApiName + '\' does not exist in schema.');
                ex.setMessage('Object \'' + objectApiName + '\' does not exist in schema.');
                throw ex;
            }

            Schema.DescribeSObjectResult targetDescribe = targetType.getDescribe();
            wrapper.objectLabel = targetDescribe.getLabel();
            Map<String, Schema.SObjectField> fieldMap = targetDescribe.fields.getMap();
            Map<String, Schema.DescribeFieldResult> fieldLookupMap = new Map<String, Schema.DescribeFieldResult>();

            for (String fName : fieldMap.keySet()) {
                fieldLookupMap.put(fName.toLowerCase(), fieldMap.get(fName).getDescribe());
            }

            // Determine Target Object External ID Field
            String extIdName = 'External_Code__c';
            if (fieldLookupMap.containsKey('external_code__c')) {
                extIdName = fieldLookupMap.get('external_code__c').getName();
            } else {
                for (String fName : fieldLookupMap.keySet()) {
                    if (fieldLookupMap.get(fName).isExternalId()) {
                        extIdName = fieldLookupMap.get(fName).getName();
                        break;
                    }
                }
            }
            wrapper.externalIdField = extIdName;

            // 2. Check if user configured selected fields in Master_Data_Studio_Config__c
            List<String> headers = new List<String>();
            String rawCsv = '';

            List<Master_Data_Studio_Config__c> customConfigs = [
                SELECT Selected_Fields__c, External_Id_Field__c
                FROM Master_Data_Studio_Config__c
                WHERE Object_API_Name__c = :objectApiName
                LIMIT 1
            ];

            if (!customConfigs.isEmpty() && String.isNotBlank(customConfigs[0].Selected_Fields__c)) {
                headers = customConfigs[0].Selected_Fields__c.split(',');
                if (String.isNotBlank(customConfigs[0].External_Id_Field__c)) {
                    wrapper.externalIdField = customConfigs[0].External_Id_Field__c;
                }
                wrapper.templateFound = true;
                rawCsv = String.join(headers, ',') + '\n';
                wrapper.rawCsvTemplate = rawCsv;
            } else {
                headers = generateDynamicHeaders(targetDescribe, fieldLookupMap);
                wrapper.templateFound = true;
                wrapper.rawCsvTemplate = String.join(headers, ',') + '\n';
            }

            wrapper.expectedHeaders = headers;

            // 5. Construct Field Mapping Info for each header
            for (String header : headers) {
                String cleanHeader = header.trim();
                String lowerHeader = cleanHeader.toLowerCase();

                FieldMappingInfo fInfo = new FieldMappingInfo();
                fInfo.headerName = cleanHeader;

                if (fieldLookupMap.containsKey(lowerHeader)) {
                    Schema.DescribeFieldResult dfr = fieldLookupMap.get(lowerHeader);
                    fInfo.fieldApiName = dfr.getName();
                    fInfo.fieldLabel = dfr.getLabel();
                    fInfo.dataType = String.valueOf(dfr.getType());
                    fInfo.isRequired = (!dfr.isNillable() && !dfr.isDefaultedOnCreate());
                    fInfo.isLookup = (dfr.getType() == Schema.DisplayType.REFERENCE);

                    if (fInfo.isLookup) {
                        List<Schema.SObjectType> refToList = dfr.getReferenceTo();
                        if (!refToList.isEmpty()) {
                            Schema.DescribeSObjectResult parentDescribe = refToList[0].getDescribe();
                            fInfo.referenceTo = parentDescribe.getName();
                            fInfo.referenceLabel = parentDescribe.getLabel();
                            String parentExtField = MasterDataUploadHandler.resolveParentExternalIdField(parentDescribe);
                            fInfo.mappingNote = 'Lookup resolved via parent ' + parentDescribe.getName() + '.' + parentExtField;
                        } else {
                            fInfo.mappingNote = 'Lookup reference';
                        }
                    } else if (dfr.isExternalId()) {
                        fInfo.mappingNote = 'External ID primary upsert key';
                    } else if (fInfo.isRequired) {
                        fInfo.mappingNote = 'Mandatory Salesforce required field';
                    } else if (dfr.getType() == Schema.DisplayType.PICKLIST) {
                        List<String> pickVals = new List<String>();
                        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                            if (pe.isActive()) {
                                pickVals.add(pe.getValue());
                                if (pickVals.size() >= 5) break;
                            }
                        }
                        fInfo.mappingNote = 'Picklist values e.g. ' + String.join(pickVals, ', ');
                    } else {
                        fInfo.mappingNote = 'Direct field assignment';
                    }
                } else {
                    fInfo.fieldApiName = cleanHeader;
                    fInfo.fieldLabel = cleanHeader;
                    fInfo.dataType = 'UNKNOWN';
                    fInfo.isRequired = false;
                    fInfo.isLookup = false;
                    fInfo.mappingNote = 'Field not recognized in object schema';
                }

                wrapper.fieldMappings.add(fInfo);
            }

            return wrapper;
        } catch (AuraHandledException aEx) {
            throw aEx;
        } catch (Exception ex) {
            AuraHandledException aEx = new AuraHandledException('Error loading object template details: ' + ex.getMessage());
            aEx.setMessage('Error loading object template details: ' + ex.getMessage());
            throw aEx;
        }
    }

    /**
     * @description Ingests a chunk of CSV rows into Salesforce.
     */
    @AuraEnabled
    public static MasterDataUploadHandler.UploadResult uploadBatch(
        String objectApiName,
        String rowsJson,
        String externalIdFieldOverride
    ) {
        if (String.isBlank(objectApiName) || String.isBlank(rowsJson)) {
            AuraHandledException ex = new AuraHandledException('Target Object API name and row data are required.');
            ex.setMessage('Target Object API name and row data are required.');
            throw ex;
        }

        try {
            List<Object> rawList = (List<Object>) JSON.deserializeUntyped(rowsJson);
            List<Map<String, String>> rowMaps = new List<Map<String, String>>();

            for (Object item : rawList) {
                Map<String, Object> m = (Map<String, Object>) item;
                Map<String, String> stringMap = new Map<String, String>();
                for (String k : m.keySet()) {
                    stringMap.put(k, m.get(k) != null ? String.valueOf(m.get(k)) : null);
                }
                rowMaps.add(stringMap);
            }

            return MasterDataUploadHandler.processRows(objectApiName, rowMaps, externalIdFieldOverride);
        } catch (AuraHandledException aEx) {
            throw aEx;
        } catch (Exception ex) {
            AuraHandledException aEx = new AuraHandledException('Batch processing failed: ' + ex.getMessage());
            aEx.setMessage('Batch processing failed: ' + ex.getMessage());
            throw aEx;
        }
    }

    /**
     * @description Dynamically generates prioritized header list for an object without a static template.
     */
    private static List<String> generateDynamicHeaders(
        Schema.DescribeSObjectResult describe,
        Map<String, Schema.DescribeFieldResult> fieldLookupMap
    ) {
        List<String> requiredFields = new List<String>();
        List<String> nameFields = new List<String>();
        List<String> externalIdFields = new List<String>();
        List<String> lookupFields = new List<String>();
        List<String> otherFields = new List<String>();

        for (String fName : fieldLookupMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldLookupMap.get(fName);

            if (!dfr.isCreateable() || dfr.isCalculated()) {
                continue;
            }

            String fieldApi = dfr.getName();
            if (fieldApi.equalsIgnoreCase('Id') || fieldApi.equalsIgnoreCase('IsDeleted')) {
                continue;
            }

            if (!dfr.isNillable() && !dfr.isDefaultedOnCreate()) {
                requiredFields.add(fieldApi);
            } else if (dfr.isNameField()) {
                nameFields.add(fieldApi);
            } else if (dfr.isExternalId() || fieldApi.equalsIgnoreCase('External_Code__c')) {
                externalIdFields.add(fieldApi);
            } else if (dfr.getType() == Schema.DisplayType.REFERENCE) {
                lookupFields.add(fieldApi);
            } else {
                if (otherFields.size() < 10) {
                    otherFields.add(fieldApi);
                }
            }
        }

        List<String> dynamicHeaders = new List<String>();
        Set<String> added = new Set<String>();

        for (String f : nameFields) {
            if (added.add(f.toLowerCase())) dynamicHeaders.add(f);
        }
        for (String f : externalIdFields) {
            if (added.add(f.toLowerCase())) dynamicHeaders.add(f);
        }
        for (String f : requiredFields) {
            if (added.add(f.toLowerCase())) dynamicHeaders.add(f);
        }
        for (String f : lookupFields) {
            if (added.add(f.toLowerCase())) dynamicHeaders.add(f);
        }
        for (String f : otherFields) {
            if (added.add(f.toLowerCase())) dynamicHeaders.add(f);
        }

        return dynamicHeaders;
    }

    /**
     * @description Parses the first line of a CSV file into clean column headers.
     */
    public static List<String> parseCsvHeaderLine(String headerLine) {
        List<String> headers = new List<String>();
        if (String.isBlank(headerLine)) return headers;

        String[] rawTokens = headerLine.split(',');
        for (String token : rawTokens) {
            String clean = token.replace('\"', '').trim();
            if (String.isNotBlank(clean)) {
                headers.add(clean);
            }
        }
        return headers;
    }

    /**
     * @description Initiates a tracked upload job with a concurrency limit of max 3 parallel jobs.
     */
    @AuraEnabled
    public static Id initiateUploadJob(String objectApiName, String objectLabel, String fileName, Integer totalRows) {
        try {
            if (String.isBlank(objectApiName)) {
                throw new AuraHandledException('Target Object API name is required to initiate an upload job.');
            }

            // Concurrency limit check: max 3 active jobs per user
            Integer activeJobCount = [
                SELECT count()
                FROM Master_Upload_Job__c
                WHERE Status__c IN ('Queued', 'Processing')
                AND CreatedById = :UserInfo.getUserId()
            ];

            if (activeJobCount >= 3) {
                AuraHandledException e = new AuraHandledException('Maximum 3 parallel upload jobs are currently active. Please wait for an existing job to complete.');
                e.setMessage('Maximum 3 parallel upload jobs are currently active. Please wait for an existing job to complete.');
                throw e;
            }

            String trackingJobId = 'JOB-' + System.currentTimeMillis();

            Master_Upload_Job__c newJob = new Master_Upload_Job__c(
                Job_Id__c = trackingJobId,
                Object_API_Name__c = objectApiName,
                Object_Label__c = String.isNotBlank(objectLabel) ? objectLabel : objectApiName,
                File_Name__c = String.isNotBlank(fileName) ? fileName : (objectApiName + '_Upload.csv'),
                Status__c = 'Processing',
                Total_Rows__c = (totalRows != null ? totalRows : 0),
                Success_Rows__c = 0,
                Failed_Rows__c = 0,
                Progress_Percent__c = 0,
                Start_Time__c = DateTime.now()
            );

            insert newJob;
            return newJob.Id;
        } catch (Exception ex) {
            throw new AuraHandledException('Failed to initiate upload job: ' + ex.getMessage());
        }
    }

    /**
     * @description Updates progress of an active upload job in real-time.
     */
    @AuraEnabled
    public static void updateJobProgress(Id jobId, Integer chunkSuccess, Integer chunkFailure, Integer processedSoFar, Integer totalRows, String serializedErrors) {
        try {
            if (jobId == null) return;

            Master_Upload_Job__c job = [
                SELECT Id, Success_Rows__c, Failed_Rows__c, Total_Rows__c, Error_Log__c, Status__c
                FROM Master_Upload_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];

            Integer currSuccess = (job.Success_Rows__c != null ? Integer.valueOf(job.Success_Rows__c) : 0) + (chunkSuccess != null ? chunkSuccess : 0);
            Integer currFailure = (job.Failed_Rows__c != null ? Integer.valueOf(job.Failed_Rows__c) : 0) + (chunkFailure != null ? chunkFailure : 0);

            job.Success_Rows__c = currSuccess;
            job.Failed_Rows__c = currFailure;

            if (totalRows != null && totalRows > 0) {
                job.Total_Rows__c = totalRows;
                Decimal pct = ((Decimal)(processedSoFar != null ? processedSoFar : (currSuccess + currFailure)) / (Decimal)totalRows) * 100;
                job.Progress_Percent__c = Math.min(100, Math.round(pct));
            }

            if (String.isNotBlank(serializedErrors)) {
                String existingLog = String.isNotBlank(job.Error_Log__c) ? job.Error_Log__c : '';
                if (existingLog.length() < 120000) {
                    job.Error_Log__c = (String.isNotBlank(existingLog) ? existingLog + '\n' : '') + serializedErrors;
                }
            }

            if (totalRows != null && (processedSoFar >= totalRows || (currSuccess + currFailure) >= totalRows)) {
                job.Completed_Time__c = DateTime.now();
                job.Progress_Percent__c = 100;
                if (currFailure > 0) {
                    job.Status__c = 'Completed with Errors';
                } else {
                    job.Status__c = 'Completed';
                }
            }

            update job;
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Failed to update job progress: ' + ex.getMessage());
        }
    }

    /**
     * @description Marks a job as failed due to a fatal error.
     */
    @AuraEnabled
    public static void markJobFailed(Id jobId, String errorMessage) {
        try {
            if (jobId == null) return;

            Master_Upload_Job__c job = [
                SELECT Id, Status__c, Error_Log__c
                FROM Master_Upload_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];

            job.Status__c = 'Failed';
            job.Completed_Time__c = DateTime.now();
            String existingLog = String.isNotBlank(job.Error_Log__c) ? job.Error_Log__c : '';
            job.Error_Log__c = (String.isNotBlank(existingLog) ? existingLog + '\n' : '') + 'FATAL ERROR: ' + errorMessage;

            update job;
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Failed to mark job as failed: ' + ex.getMessage());
        }
    }

    /**
     * @description Retrieves active and recent upload jobs for persistent tracking & monitoring.
     */
    @AuraEnabled(cacheable=false)
    public static List<UploadJobInfo> getActiveAndRecentJobs() {
        List<UploadJobInfo> result = new List<UploadJobInfo>();
        try {
            List<Master_Upload_Job__c> jobs = [
                SELECT Id, Name, Job_Id__c, Object_API_Name__c, Object_Label__c, File_Name__c,
                       Status__c, Total_Rows__c, Success_Rows__c, Failed_Rows__c, Progress_Percent__c,
                       Start_Time__c, Completed_Time__c, CreatedDate
                FROM Master_Upload_Job__c
                ORDER BY CreatedDate DESC
                LIMIT 10
            ];

            for (Master_Upload_Job__c j : jobs) {
                UploadJobInfo info = new UploadJobInfo();
                info.recordId = j.Id;
                info.name = j.Name;
                info.jobId = j.Job_Id__c;
                info.objectApiName = j.Object_API_Name__c;
                info.objectLabel = j.Object_Label__c;
                info.fileName = j.File_Name__c;
                info.status = j.Status__c;
                info.totalRows = j.Total_Rows__c != null ? Integer.valueOf(j.Total_Rows__c) : 0;
                info.successRows = j.Success_Rows__c != null ? Integer.valueOf(j.Success_Rows__c) : 0;
                info.failedRows = j.Failed_Rows__c != null ? Integer.valueOf(j.Failed_Rows__c) : 0;
                info.progressPercent = j.Progress_Percent__c != null ? j.Progress_Percent__c : 0;
                info.startTime = j.Start_Time__c;
                info.completedTime = j.Completed_Time__c;
                info.createdDate = j.CreatedDate;
                info.hasErrors = info.failedRows > 0;
                info.isProcessing = (j.Status__c == 'Processing' || j.Status__c == 'Queued');

                if (j.Status__c == 'Completed') {
                    info.statusBadgeClass = 'slds-theme_success';
                } else if (j.Status__c == 'Completed with Errors') {
                    info.statusBadgeClass = 'slds-theme_warning';
                } else if (j.Status__c == 'Failed') {
                    info.statusBadgeClass = 'slds-theme_error';
                } else {
                    info.statusBadgeClass = 'slds-theme_info';
                }
                result.add(info);
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Failed to fetch active/recent jobs: ' + ex.getMessage());
        }
        return result;
    }

    /**
     * @description Fetches the persisted error log for a job to enable download even after page refresh.
     */
    @AuraEnabled(cacheable=false)
    public static String getJobErrorLog(Id jobId) {
        if (jobId == null) return '';
        try {
            List<Master_Upload_Job__c> jobs = [
                SELECT Error_Log__c
                FROM Master_Upload_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];
            if (!jobs.isEmpty()) {
                return jobs[0].Error_Log__c != null ? jobs[0].Error_Log__c : '';
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Failed to fetch job error log: ' + ex.getMessage());
        }
        return '';
    }
}
