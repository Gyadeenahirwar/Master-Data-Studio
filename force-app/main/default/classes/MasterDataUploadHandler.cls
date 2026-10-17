/**
 * @description Generic, dynamic, and metadata-driven bulk data ingestion handler.
 * Supports automated external-code lookup resolution, dynamic type parsing,
 * and governor-limit safe upserts.
 */
public without sharing class MasterDataUploadHandler {

    public class UploadResult {
        @AuraEnabled public Integer totalRows { get; set; }
        @AuraEnabled public Integer successCount { get; set; }
        @AuraEnabled public Integer failureCount { get; set; }
        @AuraEnabled public Boolean isSuccess { get; set; }
        @AuraEnabled public List<RowError> rowErrors { get; set; }
        @AuraEnabled public String message { get; set; }

        public UploadResult() {
            this.totalRows = 0;
            this.successCount = 0;
            this.failureCount = 0;
            this.isSuccess = true;
            this.rowErrors = new List<RowError>();
            this.message = '';
        }
    }

    public class RowError {
        @AuraEnabled public Integer rowIndex { get; set; }
        @AuraEnabled public String externalCode { get; set; }
        @AuraEnabled public String errorMessage { get; set; }

        public RowError(Integer rowIndex, String externalCode, String errorMessage) {
            this.rowIndex = rowIndex;
            this.externalCode = externalCode;
            this.errorMessage = errorMessage;
        }
    }

    /**
     * @description Ingests a list of dynamic row maps into the specified Salesforce object.
     * @param objectApiName The API name of the target SObject.
     * @param rows List of row field-value maps parsed from CSV.
     * @param externalIdFieldOverride Optional field name to use as external ID for upsert.
     * @return UploadResult containing success/failure metrics and row-level errors.
     */
    public static UploadResult processRows(
        String objectApiName,
        List<Map<String, String>> rows,
        String externalIdFieldOverride
    ) {
        UploadResult result = new UploadResult();
        if (String.isBlank(objectApiName)) {
            result.isSuccess = false;
            result.message = 'Target Object API Name is required.';
            return result;
        }
        if (rows == null || rows.isEmpty()) {
            result.isSuccess = false;
            result.message = 'No data rows provided for ingestion.';
            return result;
        }

        result.totalRows = rows.size();

        // 1. Describe Target SObject
        Schema.SObjectType targetSObjectType = Schema.getGlobalDescribe().get(objectApiName);
        if (targetSObjectType == null) {
            result.isSuccess = false;
            result.message = 'Target object \'' + objectApiName + '\' does not exist in this organization.';
            return result;
        }

        Schema.DescribeSObjectResult targetDescribe = targetSObjectType.getDescribe();
        Map<String, Schema.SObjectField> fieldMap = targetDescribe.fields.getMap();
        Map<String, Schema.DescribeFieldResult> fieldLookupMap = new Map<String, Schema.DescribeFieldResult>();

        for (String fName : fieldMap.keySet()) {
            fieldLookupMap.put(fName.toLowerCase(), fieldMap.get(fName).getDescribe());
        }

        // 2. Determine External ID field for Upsert on Target Object
        Schema.SObjectField upsertExternalIdField = resolveTargetExternalIdField(
            targetDescribe,
            fieldLookupMap,
            fieldMap,
            externalIdFieldOverride
        );
        String targetExternalIdFieldName = upsertExternalIdField != null ? upsertExternalIdField.getDescribe().getName() : null;

        // 3. Pre-scan rows to identify all Lookup fields and collect referenced external codes
        Map<String, Schema.DescribeFieldResult> referenceColumns = new Map<String, Schema.DescribeFieldResult>();
        Map<String, String> lookupParentExtIdFieldMap = new Map<String, String>();
        Map<String, Set<String>> parentCodesMap = new Map<String, Set<String>>();

        for (Map<String, String> row : rows) {
            for (String header : row.keySet()) {
                String normalizedHeader = header.trim().toLowerCase();
                if (fieldLookupMap.containsKey(normalizedHeader)) {
                    Schema.DescribeFieldResult dfr = fieldLookupMap.get(normalizedHeader);
                    if (dfr.getType() == Schema.DisplayType.REFERENCE) {
                        String fieldApi = dfr.getName();
                        if (!referenceColumns.containsKey(fieldApi)) {
                            referenceColumns.put(fieldApi, dfr);
                            List<Schema.SObjectType> refToList = dfr.getReferenceTo();
                            if (!refToList.isEmpty()) {
                                Schema.DescribeSObjectResult parentDescribe = refToList[0].getDescribe();
                                String parentObjName = parentDescribe.getName();
                                String parentExtIdField = resolveParentExternalIdField(parentDescribe);
                                lookupParentExtIdFieldMap.put(fieldApi, parentExtIdField);
                                String cacheKey = (parentObjName + ':' + parentExtIdField).toLowerCase();
                                if (!parentCodesMap.containsKey(cacheKey)) {
                                    parentCodesMap.put(cacheKey, new Set<String>());
                                }
                            }
                        }

                        // Collect code value
                        String codeVal = row.get(header);
                        if (String.isNotBlank(codeVal)) {
                            List<Schema.SObjectType> refToList = dfr.getReferenceTo();
                            if (!refToList.isEmpty()) {
                                String parentObjName = refToList[0].getDescribe().getName();
                                String parentExtIdField = lookupParentExtIdFieldMap.get(fieldApi);
                                String cacheKey = (parentObjName + ':' + parentExtIdField).toLowerCase();
                                parentCodesMap.get(cacheKey).add(codeVal.trim());
                            }
                        }
                    }
                }
            }
        }

        // 4. Pre-query Parent Records to build Lookup Resolution Cache
        Map<String, Map<String, Id>> parentLookupCache = new Map<String, Map<String, Id>>();
        for (String fieldApi : referenceColumns.keySet()) {
            Schema.DescribeFieldResult dfr = referenceColumns.get(fieldApi);
            List<Schema.SObjectType> refToList = dfr.getReferenceTo();
            if (refToList.isEmpty()) continue;

            Schema.DescribeSObjectResult parentDescribe = refToList[0].getDescribe();
            String parentObjName = parentDescribe.getName();
            String parentExtIdField = lookupParentExtIdFieldMap.get(fieldApi);
            String cacheKey = (parentObjName + ':' + parentExtIdField).toLowerCase();

            if (!parentLookupCache.containsKey(cacheKey)) {
                parentLookupCache.put(cacheKey, new Map<String, Id>());
                Set<String> codesToQuery = parentCodesMap.get(cacheKey);

                if (codesToQuery != null && !codesToQuery.isEmpty()) {
                    try {
                        String safeQuery = 'SELECT Id, ' + String.escapeSingleQuotes(parentExtIdField) +
                                           ' FROM ' + String.escapeSingleQuotes(parentObjName) +
                                           ' WHERE ' + String.escapeSingleQuotes(parentExtIdField) +
                                           ' IN :codesToQuery';
                        List<SObject> parentRecords = Database.query(safeQuery);
                        for (SObject parentRec : parentRecords) {
                            Object valObj = parentRec.get(parentExtIdField);
                            if (valObj != null) {
                                String extValStr = String.valueOf(valObj).trim();
                                parentLookupCache.get(cacheKey).put(extValStr.toLowerCase(), parentRec.Id);
                            }
                        }
                    } catch (Exception ex) {
                        System.debug(LoggingLevel.ERROR, 'Failed to pre-query parent lookup: ' + ex.getMessage());
                    }
                }
            }
        }

        // 5. Build SObjects and Validate Data
        List<SObject> recordsToUpsert = new List<SObject>();
        Map<Integer, Integer> dmlIndexToCsvRowIndex = new Map<Integer, Integer>();
        Map<Integer, String> dmlIndexToExternalCode = new Map<Integer, String>();

        for (Integer i = 0; i < rows.size(); i++) {
            Map<String, String> row = rows[i];
            Integer csvRowNumber = i + 1;
            String currentExtCode = '';

            // Extract External Code for the row if available
            if (targetExternalIdFieldName != null) {
                for (String h : row.keySet()) {
                    if (h.equalsIgnoreCase(targetExternalIdFieldName)) {
                        currentExtCode = row.get(h) != null ? row.get(h).trim() : '';
                        break;
                    }
                }
            }

            SObject record = targetSObjectType.newSObject();
            Boolean rowValid = true;
            List<String> rowErrorMessages = new List<String>();

            for (String header : row.keySet()) {
                String rawVal = row.get(header);
                if (rawVal == null || String.isBlank(rawVal)) {
                    continue;
                }
                String val = rawVal.trim();
                String normalizedHeader = header.trim().toLowerCase();

                if (!fieldLookupMap.containsKey(normalizedHeader)) {
                    continue; // Skip unknown columns
                }

                Schema.DescribeFieldResult dfr = fieldLookupMap.get(normalizedHeader);
                if (!dfr.isCreateable() && !dfr.isUpdateable()) {
                    continue; // Skip non-writable fields (e.g. formula, system audit)
                }

                String actualFieldApi = dfr.getName();
                Schema.DisplayType dType = dfr.getType();

                try {
                    if (dType == Schema.DisplayType.REFERENCE) {
                        // Resolve Lookup via Parent External ID
                        List<Schema.SObjectType> refToList = dfr.getReferenceTo();
                        if (!refToList.isEmpty()) {
                            String parentObjName = refToList[0].getDescribe().getName();
                            String parentExtIdField = lookupParentExtIdFieldMap.get(actualFieldApi);
                            String cacheKey = (parentObjName + ':' + parentExtIdField).toLowerCase();
                            Map<String, Id> codeMap = parentLookupCache.get(cacheKey);

                            Id resolvedId = (codeMap != null && codeMap.containsKey(val.toLowerCase())) ?
                                            codeMap.get(val.toLowerCase()) : null;

                            if (resolvedId != null) {
                                record.put(actualFieldApi, resolvedId);
                            } else {
                                rowValid = false;
                                rowErrorMessages.add('Parent ' + refToList[0].getDescribe().getLabel() +
                                    ' with code \'' + val + '\' not found for lookup \'' + dfr.getLabel() + '\' (' + actualFieldApi + ').');
                            }
                        }
                    } else {
                        // Standard Field Type Conversion
                        populateFieldValue(record, dfr, val);
                    }
                } catch (Exception parseEx) {
                    rowValid = false;
                    rowErrorMessages.add('Field \'' + dfr.getLabel() + '\': ' + parseEx.getMessage());
                }
            }

            if (!rowValid) {
                result.failureCount++;
                result.rowErrors.add(new RowError(
                    csvRowNumber,
                    currentExtCode,
                    String.join(rowErrorMessages, ' | ')
                ));
            } else {
                Integer dmlIndex = recordsToUpsert.size();
                recordsToUpsert.add(record);
                dmlIndexToCsvRowIndex.put(dmlIndex, csvRowNumber);
                dmlIndexToExternalCode.put(dmlIndex, currentExtCode);
            }
        }

        // 6. Execute DML Upsert / Insert with resilient fallback
        if (!recordsToUpsert.isEmpty()) {
            Boolean upsertAttempted = false;
            if (upsertExternalIdField != null) {
                try {
                    Database.UpsertResult[] upsertResults = Database.upsert(recordsToUpsert, upsertExternalIdField, false);
                    upsertAttempted = true;
                    for (Integer idx = 0; idx < upsertResults.size(); idx++) {
                        Database.UpsertResult ur = upsertResults[idx];
                        Integer origCsvRow = dmlIndexToCsvRowIndex.get(idx);
                        String origExtCode = dmlIndexToExternalCode.get(idx);

                        if (ur.isSuccess()) {
                            result.successCount++;
                        } else {
                            result.failureCount++;
                            List<String> errMsgs = new List<String>();
                            for (Database.Error err : ur.getErrors()) {
                                errMsgs.add(err.getMessage() + (err.getFields().isEmpty() ? '' : ' (' + String.join(err.getFields(), ', ') + ')'));
                            }
                            result.rowErrors.add(new RowError(
                                origCsvRow,
                                origExtCode,
                                String.join(errMsgs, '; ')
                            ));
                        }
                    }
                } catch (Exception upsertEx) {
                    System.debug(LoggingLevel.WARN, 'Upsert with external ID failed, attempting insert fallback: ' + upsertEx.getMessage());
                    upsertAttempted = false;
                }
            }

            if (!upsertAttempted) {
                Database.SaveResult[] saveResults = Database.insert(recordsToUpsert, false);
                for (Integer idx = 0; idx < saveResults.size(); idx++) {
                    Database.SaveResult sr = saveResults[idx];
                    Integer origCsvRow = dmlIndexToCsvRowIndex.get(idx);
                    String origExtCode = dmlIndexToExternalCode.get(idx);

                    if (sr.isSuccess()) {
                        result.successCount++;
                    } else {
                        result.failureCount++;
                        List<String> errMsgs = new List<String>();
                        for (Database.Error err : sr.getErrors()) {
                            errMsgs.add(err.getMessage() + (err.getFields().isEmpty() ? '' : ' (' + String.join(err.getFields(), ', ') + ')'));
                        }
                        result.rowErrors.add(new RowError(
                            origCsvRow,
                            origExtCode,
                            String.join(errMsgs, '; ')
                        ));
                    }
                }
            }
        }

        result.isSuccess = (result.failureCount == 0);
        result.message = 'Processed ' + result.totalRows + ' records: ' +
                         result.successCount + ' succeeded, ' +
                         result.failureCount + ' failed.';
        return result;
    }

    /**
     * @description Populates SObject field with dynamic type conversion.
     */
    private static void populateFieldValue(SObject record, Schema.DescribeFieldResult dfr, String val) {
        String fieldName = dfr.getName();
        Schema.DisplayType dType = dfr.getType();

        switch on dType {
            when BOOLEAN {
                String boolStr = val.toLowerCase();
                if (boolStr == 'true' || boolStr == '1' || boolStr == 'yes' || boolStr == 'y') {
                    record.put(fieldName, true);
                } else if (boolStr == 'false' || boolStr == '0' || boolStr == 'no' || boolStr == 'n') {
                    record.put(fieldName, false);
                } else {
                    record.put(fieldName, Boolean.valueOf(boolStr));
                }
            }
            when INTEGER {
                String cleanNum = val.replaceAll('[^0-9\\-]', '');
                record.put(fieldName, Integer.valueOf(cleanNum));
            }
            when DOUBLE, CURRENCY, PERCENT {
                String cleanDec = val.replaceAll('[^0-9.\\-]', '');
                record.put(fieldName, Decimal.valueOf(cleanDec));
            }
            when DATE {
                record.put(fieldName, parseDate(val));
            }
            when DATETIME {
                record.put(fieldName, parseDateTime(val));
            }
            when else {
                record.put(fieldName, val);
            }
        }
    }

    /**
     * @description Parses various common date strings into Date object.
     */
    public static Date parseDate(String val) {
        if (String.isBlank(val)) return null;
        val = val.trim();

        // Standard ISO YYYY-MM-DD
        if (Pattern.matches('^\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}$', val)) {
            String norm = val.replace('/', '-');
            return Date.valueOf(norm);
        }

        // DD-MM-YYYY or DD/MM/YYYY
        if (Pattern.matches('^\\d{1,2}[-/]\\d{1,2}[-/]\\d{4}$', val)) {
            String[] parts = val.contains('/') ? val.split('/') : val.split('-');
            Integer day = Integer.valueOf(parts[0]);
            Integer month = Integer.valueOf(parts[1]);
            Integer year = Integer.valueOf(parts[2]);
            return Date.newInstance(year, month, day);
        }

        return Date.valueOf(val);
    }

    /**
     * @description Parses standard datetime strings into Datetime object.
     */
    public static Datetime parseDateTime(String val) {
        if (String.isBlank(val)) return null;
        val = val.trim();

        if (val.contains('T')) {
            String iso = val.replace('Z', '').replace('T', ' ');
            return Datetime.valueOf(iso);
        }
        if (Pattern.matches('^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$', val)) {
            return Datetime.valueOf(val);
        }
        Date d = parseDate(val);
        return Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0));
    }

    /**
     * @description Dynamically finds the External ID field on a parent object.
     */
    public static String resolveParentExternalIdField(Schema.DescribeSObjectResult parentDescribe) {
        Map<String, Schema.SObjectField> pFields = parentDescribe.fields.getMap();

        // 1. Check for standard External_Code__c
        if (pFields.containsKey('external_code__c')) {
            Schema.DescribeFieldResult dfr = pFields.get('external_code__c').getDescribe();
            if (dfr.isAccessible()) {
                return dfr.getName();
            }
        }

        // 2. Check for any field marked as isExternalId() that is accessible
        for (String fName : pFields.keySet()) {
            Schema.DescribeFieldResult dfr = pFields.get(fName).getDescribe();
            if (dfr.isExternalId() && dfr.isAccessible()) {
                return dfr.getName();
            }
        }

        // 3. Check for Name field
        for (String fName : pFields.keySet()) {
            Schema.DescribeFieldResult dfr = pFields.get(fName).getDescribe();
            if (dfr.isNameField() && dfr.isAccessible()) {
                return dfr.getName();
            }
        }

        return 'Id';
    }

    /**
     * @description Dynamically finds the External ID field on the target object for upserting.
     */
    public static Schema.SObjectField resolveTargetExternalIdField(
        Schema.DescribeSObjectResult targetDescribe,
        Map<String, Schema.DescribeFieldResult> fieldLookupMap,
        Map<String, Schema.SObjectField> fieldMap,
        String externalIdFieldOverride
    ) {
        // 1. Check override
        if (String.isNotBlank(externalIdFieldOverride)) {
            String lowerOverride = externalIdFieldOverride.trim().toLowerCase();
            if (fieldLookupMap.containsKey(lowerOverride)) {
                Schema.DescribeFieldResult dfr = fieldLookupMap.get(lowerOverride);
                if (dfr.isAccessible() && (dfr.isCreateable() || dfr.isUpdateable())) {
                    return fieldMap.get(dfr.getName());
                }
            }
        }

        // 2. Check for External_Code__c
        if (fieldLookupMap.containsKey('external_code__c')) {
            Schema.DescribeFieldResult dfr = fieldLookupMap.get('external_code__c');
            if (dfr.isAccessible() && (dfr.isCreateable() || dfr.isUpdateable())) {
                return fieldMap.get(dfr.getName());
            }
        }

        // 3. Check for any field marked as isExternalId() that is accessible
        for (String fName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(fName).getDescribe();
            if (dfr.isExternalId() && dfr.isAccessible() && (dfr.isCreateable() || dfr.isUpdateable())) {
                return fieldMap.get(fName);
            }
        }

        return null;
    }
}
