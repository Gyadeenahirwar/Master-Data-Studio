/**
 * @description Comprehensive unit tests for MasterUploadController.
 * Validates config retrieval, dynamic describe fallback, batch upload endpoints,
 * job lifecycle management, and parallel concurrency limits.
 * Uses Standard Salesforce Objects ensuring 100% independence from any org-specific custom objects.
 */
@IsTest
private class MasterUploadControllerTest {

    @IsTest
    static void testGetUploadConfigs() {
        // Ensure at least one config exists
        Master_Data_Studio_Config__c cfg = new Master_Data_Studio_Config__c(
            Object_API_Name__c = 'Account',
            Object_Label__c = 'Account',
            Upload_Sequence__c = 1,
            Active__c = true
        );
        insert cfg;

        Test.startTest();
        List<MasterUploadController.UploadConfigWrapper> configs = MasterUploadController.getUploadConfigs();
        Test.stopTest();

        System.assertNotEquals(null, configs, 'Upload configs should not be null');
        System.assert(!configs.isEmpty(), 'Upload configs should contain at least one config');
        MasterUploadController.UploadConfigWrapper first = configs[0];
        System.assertNotEquals(null, first.objectApiName);
        System.assert(first.stepBadge.startsWith('Step 1 of'));
    }

    @IsTest
    static void testGetObjectTemplateDetailsWithConfiguredFields() {
        Master_Data_Studio_Config__c cfg = new Master_Data_Studio_Config__c(
            Object_API_Name__c = 'Contact',
            Object_Label__c = 'Contact',
            Upload_Sequence__c = 1,
            Selected_Fields__c = 'FirstName,LastName,Email,AccountId',
            Active__c = true
        );
        insert cfg;

        Test.startTest();
        MasterUploadController.TemplateDetailWrapper details = MasterUploadController.getObjectTemplateDetails(
            'Contact',
            'Contact_Template'
        );
        Test.stopTest();

        System.assertNotEquals(null, details, 'Template details wrapper should not be null');
        System.assertEquals('Contact', details.objectApiName);
        System.assertNotEquals(null, details.expectedHeaders);
        System.assert(details.expectedHeaders.size() > 0, 'Expected headers to be populated');
        System.assert(details.fieldMappings.size() > 0, 'Field mappings should be populated');

        // Check lookup field mappings (AccountId -> Account)
        Boolean foundLookup = false;
        for (MasterUploadController.FieldMappingInfo f : details.fieldMappings) {
            if (f.isLookup) {
                foundLookup = true;
                System.assert(f.mappingNote.contains('Lookup resolved via parent'), 'Lookup note should follow format');
            }
        }
        System.assert(foundLookup, 'Should have at least one lookup field in Contact (AccountId)');
    }

    @IsTest
    static void testGetObjectTemplateDetailsDynamicFallback() {
        // Test with an object without existing custom config, triggering dynamic describe generation
        Test.startTest();
        MasterUploadController.TemplateDetailWrapper details = MasterUploadController.getObjectTemplateDetails(
            'Opportunity',
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, details);
        System.assertEquals('Opportunity', details.objectApiName);
        System.assertEquals(true, details.templateFound);
        System.assert(details.expectedHeaders.size() > 0, 'Dynamic headers should be generated');
        System.assertNotEquals(null, details.rawCsvTemplate);
    }

    @IsTest
    static void testGetObjectTemplateDetailsExceptions() {
        // Blank object API Name
        try {
            MasterUploadController.getObjectTemplateDetails('', 'SomeTemplate');
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }

        // Invalid object API Name
        try {
            MasterUploadController.getObjectTemplateDetails('Totally_Bogus_Object_999__c', 'SomeTemplate');
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
    }

    @IsTest
    static void testUploadBatchSuccess() {
        List<Map<String, String>> rowList = new List<Map<String, String>>();
        rowList.add(new Map<String, String>{
            'Name' => 'Batch Account Test',
            'NumberOfEmployees' => '100'
        });

        String rowsJson = JSON.serialize(rowList);

        Test.startTest();
        MasterDataUploadHandler.UploadResult res = MasterUploadController.uploadBatch(
            'Account',
            rowsJson,
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, res);
        System.assert(res.isSuccess);
        System.assertEquals(1, res.successCount);
    }

    @IsTest
    static void testUploadBatchExceptions() {
        try {
            MasterUploadController.uploadBatch('', '', null);
            System.assert(false, 'Should throw exception on blank params');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }

        try {
            MasterUploadController.uploadBatch('Account', 'invalid json string', null);
            System.assert(false, 'Should throw exception on invalid json');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
    }

    @IsTest
    static void testParseCsvHeaderLine() {
        List<String> headers = MasterUploadController.parseCsvHeaderLine('\"FirstName\",\"LastName\",\"Email\"');
        System.assertEquals(3, headers.size());
        System.assertEquals('FirstName', headers[0]);
        System.assertEquals('LastName', headers[1]);
        System.assertEquals('Email', headers[2]);

        List<String> emptyHeaders = MasterUploadController.parseCsvHeaderLine('');
        System.assertEquals(0, emptyHeaders.size());
    }

    @IsTest
    static void testGetAllEligibleObjects() {
        // Insert a test configuration
        Master_Data_Studio_Config__c cfg = new Master_Data_Studio_Config__c(
            Object_API_Name__c = 'Account',
            Object_Label__c = 'Account',
            Upload_Sequence__c = 1,
            Active__c = true
        );
        insert cfg;

        Test.startTest();
        List<MasterUploadController.ObjectOptionInfo> objects = MasterUploadController.getAllEligibleObjects();
        Test.stopTest();

        System.assertNotEquals(null, objects);
        System.assert(objects.size() > 0, 'Should return eligible objects');

        Boolean foundAccount = false;
        for (MasterUploadController.ObjectOptionInfo obj : objects) {
            if (obj.value == 'Account') {
                foundAccount = true;
                System.assertEquals(true, obj.isConfigured, 'Account should be marked as configured');
            }
        }
        System.assert(foundAccount, 'Account should be in the list');
    }

    @IsTest
    static void testGetObjectFieldsForSetup() {
        Test.startTest();
        MasterUploadController.FieldSetupResponse res = MasterUploadController.getObjectFieldsForSetup('Account');
        Test.stopTest();

        System.assertNotEquals(null, res);
        System.assertNotEquals(null, res.fields);
        System.assert(res.fields.size() > 0, 'Account should have fields');

        // Check exception case
        try {
            MasterUploadController.getObjectFieldsForSetup('Invalid_Fake_Object_999__c');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
    }

    @IsTest
    static void testSaveAndDeleteObjectUploadConfig() {
        // Prepare setup JSON
        Map<String, Object> configMap = new Map<String, Object>{
            'objectApiName' => 'Account',
            'objectLabel' => 'Account Configured',
            'uploadSequence' => 10,
            'externalIdField' => 'AccountNumber',
            'description' => 'Configured via Master Data Studio Setup',
            'selectedFields' => new List<String>{ 'Name', 'AccountNumber' }
        };

        Test.startTest();
        MasterUploadController.UploadConfigWrapper saved = MasterUploadController.saveObjectUploadConfig(
            JSON.serialize(configMap)
        );

        System.assertNotEquals(null, saved);
        System.assertEquals('Account', saved.objectApiName);
        System.assertEquals('Account Configured', saved.objectLabel);

        // Verify getUploadConfigs returns it
        List<MasterUploadController.UploadConfigWrapper> configs = MasterUploadController.getUploadConfigs();
        System.assertNotEquals(null, configs);
        System.assert(configs.size() > 0);

        // Verify getObjectTemplateDetails uses selectedFields from custom config
        MasterUploadController.TemplateDetailWrapper template = MasterUploadController.getObjectTemplateDetails(
            'Account',
            'Account_Template'
        );
        System.assertNotEquals(null, template);
        System.assertEquals(true, template.templateFound);
        System.assert(template.rawCsvTemplate.contains('AccountNumber'));

        // Delete the config
        Boolean deleted = MasterUploadController.deleteObjectUploadConfig('Account');
        System.assertEquals(true, deleted);

        // Deleting blank should return false
        Boolean deletedBlank = MasterUploadController.deleteObjectUploadConfig('');
        System.assertEquals(false, deletedBlank);

        // Save invalid JSON throws exception
        try {
            MasterUploadController.saveObjectUploadConfig('bad json');
            System.assert(false, 'Should throw exception for bad json');
        } catch (AuraHandledException ex) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testTemplateDetailsWithUnknownFieldsAndPicklists() {
        // Setup config with an unknown field name and a picklist field on Opportunity
        Master_Data_Studio_Config__c cfg = new Master_Data_Studio_Config__c(
            Object_API_Name__c = 'Opportunity',
            Object_Label__c = 'Opportunity',
            Upload_Sequence__c = 1,
            Selected_Fields__c = 'Name,StageName,CloseDate,Totally_Fake_Field__c',
            Active__c = true
        );
        insert cfg;

        Test.startTest();
        MasterUploadController.TemplateDetailWrapper template = MasterUploadController.getObjectTemplateDetails(
            'Opportunity',
            'Opportunity_Template'
        );
        Test.stopTest();

        System.assertNotEquals(null, template);
        Boolean foundUnknown = false;
        Boolean foundPicklist = false;
        for (MasterUploadController.FieldMappingInfo f : template.fieldMappings) {
            if (f.fieldApiName == 'Totally_Fake_Field__c') {
                foundUnknown = true;
                System.assertEquals('UNKNOWN', f.dataType);
            }
            if (f.fieldApiName == 'StageName') {
                foundPicklist = true;
                System.assertNotEquals(null, f.mappingNote);
            }
        }
        System.assert(foundUnknown, 'Unknown field should be handled gracefully');
        System.assert(foundPicklist, 'Picklist field should be present');
    }

    @IsTest
    static void testWrapperProperties() {
        MasterUploadController.UploadConfigWrapper w = new MasterUploadController.UploadConfigWrapper();
        w.isCustomObject = true;
        System.assertEquals(true, w.isCustomObject);
    }

    @IsTest
    static void testRowErrorInstantiation() {
        MasterDataUploadHandler.RowError err = new MasterDataUploadHandler.RowError(1, 'EXT-01', 'Test Error');
        System.assertEquals(1, err.rowIndex);
        System.assertEquals('EXT-01', err.externalCode);
        System.assertEquals('Test Error', err.errorMessage);
    }

    @IsTest
    static void testUploadJobLifecycle() {
        Test.startTest();
        // 1. Initiate Job
        Id jobId = MasterUploadController.initiateUploadJob('Account', 'Account', 'test.csv', 100);
        System.assertNotEquals(null, jobId, 'Job ID should be created');

        // 2. Update progress chunk
        MasterUploadController.updateJobProgress(jobId, 50, 0, 50, 100, null);
        Master_Upload_Job__c j = [SELECT Status__c, Progress_Percent__c, Success_Rows__c FROM Master_Upload_Job__c WHERE Id = :jobId];
        System.assertEquals(50, j.Success_Rows__c);
        System.assertEquals(50, j.Progress_Percent__c);

        // 3. Complete with errors
        MasterUploadController.updateJobProgress(jobId, 40, 10, 100, 100, '{"row": 91, "error": "Invalid Code"}');
        Master_Upload_Job__c j2 = [SELECT Status__c, Progress_Percent__c, Success_Rows__c, Failed_Rows__c FROM Master_Upload_Job__c WHERE Id = :jobId];
        System.assertEquals(90, j2.Success_Rows__c);
        System.assertEquals(10, j2.Failed_Rows__c);
        System.assertEquals('Completed with Errors', j2.Status__c);

        // 4. Get active & recent jobs
        List<MasterUploadController.UploadJobInfo> recentJobs = MasterUploadController.getActiveAndRecentJobs();
        System.assert(recentJobs.size() > 0, 'Recent jobs should contain the newly created job');

        // 5. Get Job Error Log
        String errorLog = MasterUploadController.getJobErrorLog(jobId);
        System.assert(errorLog.contains('Invalid Code'), 'Error log should contain error message');

        // 6. Test Mark Job Failed
        Id failJobId = MasterUploadController.initiateUploadJob('Opportunity', 'Opportunity', 'fail.csv', 50);
        MasterUploadController.markJobFailed(failJobId, 'DML Crash');
        Master_Upload_Job__c failedJob = [SELECT Status__c, Error_Log__c FROM Master_Upload_Job__c WHERE Id = :failJobId];
        System.assertEquals('Failed', failedJob.Status__c);
        System.assert(failedJob.Error_Log__c.contains('DML Crash'));

        // 7. Test clearJobById
        Boolean singleCleared = MasterUploadController.clearJobById(failJobId);
        System.assertEquals(true, singleCleared, 'Should clear single job by ID');
        System.assertEquals(false, MasterUploadController.clearJobById(null), 'Should handle null safely');

        // 8. Test clearCompletedJobs
        Boolean allCompletedCleared = MasterUploadController.clearCompletedJobs();
        System.assertEquals(true, allCompletedCleared, 'Should clear all completed jobs');

        Test.stopTest();
    }

    @IsTest
    static void testConcurrencyLimitMaxThreeJobs() {
        // Create 3 active processing jobs
        insert new List<Master_Upload_Job__c>{
            new Master_Upload_Job__c(Object_API_Name__c = 'Account', Status__c = 'Processing', Job_Id__c = 'J1'),
            new Master_Upload_Job__c(Object_API_Name__c = 'Contact', Status__c = 'Processing', Job_Id__c = 'J2'),
            new Master_Upload_Job__c(Object_API_Name__c = 'Opportunity', Status__c = 'Queued', Job_Id__c = 'J3')
        };

        Test.startTest();
        Boolean exceptionCaught = false;
        try {
            MasterUploadController.initiateUploadJob('Lead', 'Lead', 'lead.csv', 10);
        } catch (Exception ex) {
            exceptionCaught = true;
        }
        Test.stopTest();

        System.assert(exceptionCaught, 'Should block creating a 4th concurrent job');
    }
}