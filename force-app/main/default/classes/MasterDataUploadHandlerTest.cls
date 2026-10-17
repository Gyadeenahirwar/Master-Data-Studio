/**
 * @description Comprehensive unit tests for MasterDataUploadHandler.
 * Uses Standard Salesforce objects (Account, Contact, Opportunity, Case)
 * ensuring 100% independence from any org-specific custom objects or namespaces.
 */
@IsTest
private class MasterDataUploadHandlerTest {

    @TestSetup
    static void setupTestData() {
        // Create parent Account
        Account parentAcc = new Account(
            Name = 'Parent Global HQ',
            NumberOfEmployees = 500
        );
        insert parentAcc;

        Account regionalAcc = new Account(
            Name = 'North Regional Office',
            ParentId = parentAcc.Id,
            NumberOfEmployees = 150
        );
        insert regionalAcc;
    }

    @IsTest
    static void testSuccessfulIngestionWithLookups() {
        // Prepare rows for Contact referencing parent Account via Name
        List<Map<String, String>> rows = new List<Map<String, String>>();

        Map<String, String> row1 = new Map<String, String>{
            'FirstName' => 'John',
            'LastName' => 'Doe',
            'Email' => 'john.doe@testmasterdata.com',
            'AccountId' => 'North Regional Office'
        };
        rows.add(row1);

        Map<String, String> row2 = new Map<String, String>{
            'FirstName' => 'Jane',
            'LastName' => 'Smith',
            'Email' => 'jane.smith@testmasterdata.com',
            'AccountId' => 'Parent Global HQ'
        };
        rows.add(row2);

        Test.startTest();
        MasterDataUploadHandler.UploadResult result = MasterDataUploadHandler.processRows(
            'Contact',
            rows,
            null
        );
        Test.stopTest();

        System.assert(result.isSuccess, 'Expected upload to succeed: ' + result.message);
        System.assertEquals(2, result.totalRows, 'Total rows should be 2');
        System.assertEquals(2, result.successCount, 'Success count should be 2');
        System.assertEquals(0, result.failureCount, 'Failure count should be 0');

        // Verify child records were inserted and lookups resolved
        Contact insertedCon = [
            SELECT Id, FirstName, LastName, AccountId
            FROM Contact
            WHERE Email = 'john.doe@testmasterdata.com'
            LIMIT 1
        ];
        System.assertNotEquals(null, insertedCon.AccountId, 'AccountId should be resolved');
        Account matchedAcc = [SELECT Id, Name FROM Account WHERE Id = :insertedCon.AccountId];
        System.assertEquals('North Regional Office', matchedAcc.Name);
    }

    @IsTest
    static void testLookupResolutionMissingParentCode() {
        List<Map<String, String>> rows = new List<Map<String, String>>();

        // Valid row
        Map<String, String> validRow = new Map<String, String>{
            'FirstName' => 'Valid',
            'LastName' => 'User',
            'Email' => 'valid.user@testmasterdata.com',
            'AccountId' => 'North Regional Office'
        };
        rows.add(validRow);

        // Invalid row with non-existent parent lookup
        Map<String, String> invalidRow = new Map<String, String>{
            'FirstName' => 'Unknown',
            'LastName' => 'User',
            'Email' => 'unknown.user@testmasterdata.com',
            'AccountId' => 'NON-EXISTENT-PARENT-ACCOUNT'
        };
        rows.add(invalidRow);

        Test.startTest();
        MasterDataUploadHandler.UploadResult result = MasterDataUploadHandler.processRows(
            'Contact',
            rows,
            null
        );
        Test.stopTest();

        System.assertEquals(2, result.totalRows, 'Total rows should be 2');
        System.assertEquals(1, result.successCount, 'One row should succeed');
        System.assertEquals(1, result.failureCount, 'One row should fail');
        System.assertEquals(false, result.isSuccess, 'Overall success flag should be false');
        System.assertEquals(1, result.rowErrors.size(), 'Should have 1 row error logged');
        System.assertEquals(2, result.rowErrors[0].rowIndex, 'Row index should be 2');
        System.assert(result.rowErrors[0].errorMessage.contains('not found for lookup'), 'Should describe lookup failure');
    }

    @IsTest
    static void testTypeConversionsAndDateParsing() {
        // Test date parser directly
        Date d1 = MasterDataUploadHandler.parseDate('2026-10-17');
        Date d2 = MasterDataUploadHandler.parseDate('17/10/2026');
        Date d3 = MasterDataUploadHandler.parseDate('17-10-2026');
        Date d4 = MasterDataUploadHandler.parseDate('2026/10/17');
        System.assertEquals(Date.newInstance(2026, 10, 17), d1);
        System.assertEquals(Date.newInstance(2026, 10, 17), d2);
        System.assertEquals(Date.newInstance(2026, 10, 17), d3);
        System.assertEquals(Date.newInstance(2026, 10, 17), d4);
        System.assertEquals(null, MasterDataUploadHandler.parseDate(''));

        // Test datetime parser directly
        Datetime dt1 = MasterDataUploadHandler.parseDateTime('2026-10-17 12:00:00');
        Datetime dt2 = MasterDataUploadHandler.parseDateTime('2026-10-17T12:00:00Z');
        Datetime dt3 = MasterDataUploadHandler.parseDateTime('2026-10-17');
        System.assertNotEquals(null, dt1);
        System.assertNotEquals(null, dt2);
        System.assertNotEquals(null, dt3);
        System.assertEquals(null, MasterDataUploadHandler.parseDateTime(''));

        // Test Boolean conversions with Contact (DoNotCall)
        List<Map<String, String>> contactRows = new List<Map<String, String>>{
            new Map<String, String>{
                'FirstName' => 'Bool',
                'LastName' => 'Test1',
                'DoNotCall' => 'true'
            },
            new Map<String, String>{
                'FirstName' => 'Bool',
                'LastName' => 'Test2',
                'DoNotCall' => '0'
            }
        };

        Test.startTest();
        MasterDataUploadHandler.UploadResult conResult = MasterDataUploadHandler.processRows(
            'Contact',
            contactRows,
            null
        );

        // Test Currency, Date, Integer type conversions with Opportunity & Account
        List<Map<String, String>> oppRows = new List<Map<String, String>>{
            new Map<String, String>{
                'Name' => 'Enterprise Opportunity Q4',
                'StageName' => 'Prospecting',
                'CloseDate' => '2026-10-31',
                'Amount' => '75000.50'
            }
        };
        MasterDataUploadHandler.UploadResult oppResult = MasterDataUploadHandler.processRows('Opportunity', oppRows, null);
        System.assert(oppResult.isSuccess, 'Opportunity currency and date conversion should succeed');

        List<Map<String, String>> accRows = new List<Map<String, String>>{
            new Map<String, String>{
                'Name' => 'Global Logistics Inc',
                'NumberOfEmployees' => '450'
            }
        };
        MasterDataUploadHandler.UploadResult accResult = MasterDataUploadHandler.processRows('Account', accRows, null);
        System.assert(accResult.isSuccess, 'Account integer conversion should succeed');

        Test.stopTest();

        System.assert(conResult.isSuccess, 'Contact rows should insert successfully: ' + conResult.message);
        System.assertEquals(2, conResult.totalRows);
        System.assertEquals(2, conResult.successCount);
    }

    @IsTest
    static void testResolveHelperMethods() {
        Schema.DescribeSObjectResult accDesc = Account.SObjectType.getDescribe();
        String parentExtId = MasterDataUploadHandler.resolveParentExternalIdField(accDesc);
        System.assertNotEquals(null, parentExtId);

        Schema.DescribeSObjectResult conDesc = Contact.SObjectType.getDescribe();
        Map<String, Schema.SObjectField> fieldMap = conDesc.fields.getMap();
        Map<String, Schema.DescribeFieldResult> fieldLookupMap = new Map<String, Schema.DescribeFieldResult>();
        for (String f : fieldMap.keySet()) {
            fieldLookupMap.put(f.toLowerCase(), fieldMap.get(f).getDescribe());
        }

        Schema.SObjectField extField = MasterDataUploadHandler.resolveTargetExternalIdField(
            conDesc,
            fieldLookupMap,
            fieldMap,
            'Email'
        );
        System.assertNotEquals(null, extField);

        // Test fallback to standard Name or Id when parent has no external ID
        Schema.DescribeSObjectResult caseDesc = Case.SObjectType.getDescribe();
        String caseParentKey = MasterDataUploadHandler.resolveParentExternalIdField(caseDesc);
        System.assertNotEquals(null, caseParentKey);
    }

    @IsTest
    static void testDmlFailureHandling() {
        // Attempt to insert Opportunity missing required fields (StageName and CloseDate) to trigger DML failure
        List<Map<String, String>> badRows = new List<Map<String, String>>{
            new Map<String, String>{ 'Name' => 'Invalid Opp Row Without Required Fields' }
        };

        Test.startTest();
        MasterDataUploadHandler.UploadResult res = MasterDataUploadHandler.processRows('Opportunity', badRows, null);
        Test.stopTest();

        System.assertEquals(false, res.isSuccess, 'Should report failure on missing required fields');
        System.assertEquals(1, res.failureCount);
        System.assertEquals(1, res.rowErrors.size());
    }

    @IsTest
    static void testValidationAndEdgeCases() {
        // Blank object name
        MasterDataUploadHandler.UploadResult res1 = MasterDataUploadHandler.processRows(
            '',
            new List<Map<String, String>>{ new Map<String, String>{ 'Name' => 'Test' } },
            null
        );
        System.assertEquals(false, res1.isSuccess);

        // Empty rows
        MasterDataUploadHandler.UploadResult res2 = MasterDataUploadHandler.processRows(
            'Account',
            new List<Map<String, String>>(),
            null
        );
        System.assertEquals(false, res2.isSuccess);

        // Invalid object API name
        MasterDataUploadHandler.UploadResult res3 = MasterDataUploadHandler.processRows(
            'Non_Existent_Object_99__c',
            new List<Map<String, String>>{ new Map<String, String>{ 'Name' => 'Test' } },
            null
        );
        System.assertEquals(false, res3.isSuccess);
    }

    @IsTest
    static void testBulkIngestion() {
        List<Map<String, String>> bulkRows = new List<Map<String, String>>();
        for (Integer i = 1; i <= 50; i++) {
            bulkRows.add(new Map<String, String>{
                'FirstName' => 'BulkFirst' + i,
                'LastName' => 'BulkLast' + i,
                'Email' => 'bulk' + i + '@testmasterdata.com',
                'AccountId' => 'Parent Global HQ'
            });
        }

        Test.startTest();
        MasterDataUploadHandler.UploadResult result = MasterDataUploadHandler.processRows(
            'Contact',
            bulkRows,
            null
        );
        Test.stopTest();

        System.assert(result.isSuccess, 'Bulk ingestion should succeed');
        System.assertEquals(50, result.totalRows);
        System.assertEquals(50, result.successCount);
    }
}
