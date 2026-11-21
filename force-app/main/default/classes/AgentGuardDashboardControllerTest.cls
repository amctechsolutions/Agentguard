@isTest
public with sharing class AgentGuardDashboardControllerTest {
    private class DashboardMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"sessionId":"sess-dash"}');
            return res;
        }
    }

    @isTest
    static void testQueriesAndTrigger() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Dashboard Suite',
            Target_Agent_Api_Name__c = 'Support_Agent',
            Pass_Threshold_Pct__c = 90,
            Max_Turns_Per_Run__c = 25
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        Agent_Test_Case__c tc = new Agent_Test_Case__c(
            Agent_Test_Suite__c = suite.Id,
            Category__c = 'Functional',
            Utterance__c = 'Hello'
        );
        Database.insert(tc, AccessLevel.USER_MODE);

        Agent_Test_Run__c runRec = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Passed',
            Total_Tests__c = 1,
            Passed_Tests__c = 1,
            Regression_Count__c = 0
        );
        Database.insert(runRec, AccessLevel.USER_MODE);

        Agent_Test_Result__c resultRec = new Agent_Test_Result__c(
            Agent_Test_Run__c = runRec.Id,
            Test_Case__c = tc.Id,
            Utterance_Snapshot__c = 'Hello',
            Actual_Topic__c = 'Order_Status',
            Previous_Topic__c = 'Order_Status',
            Deterministic_Pass__c = true,
            LLM_Judge_Pass__c = true,
            Regression_Detected__c = false
        );
        Database.insert(resultRec, AccessLevel.USER_MODE);

        List<Agent_Test_Suite__c> suites = AgentGuardDashboardController.getSuites();
        Assert.areEqual(1, suites.size());
        Assert.areEqual(25, suites[0].Max_Turns_Per_Run__c);

        List<Agent_Test_Run__c> runs = AgentGuardDashboardController.getRunsForSuite(suite.Id);
        Assert.areEqual(1, runs.size());
        Assert.areEqual(0, runs[0].Regression_Count__c);
        Assert.isNull(runs[0].Previous_Run__c);
        Assert.areEqual(0, AgentGuardDashboardController.getRunsForSuite(null).size());

        List<Agent_Test_Result__c> results = AgentGuardDashboardController.getResultsForRun(runRec.Id);
        Assert.areEqual(1, results.size());
        Assert.areEqual(false, results[0].Regression_Detected__c);
        Assert.areEqual('Order_Status', results[0].Previous_Topic__c);
        Assert.areEqual('Hello', results[0].Utterance_Snapshot__c);
        Assert.areEqual(0, AgentGuardDashboardController.getResultsForRun(null).size());

        Test.setMock(HttpCalloutMock.class, new DashboardMock());
        Test.startTest();
        Id triggeredRunId = AgentGuardDashboardController.triggerSuiteRun(suite.Id);
        Test.stopTest();
        Assert.isNotNull(triggeredRunId);

        Agent_Test_Run__c triggeredRun = [
            SELECT Previous_Run__c
            FROM Agent_Test_Run__c
            WHERE Id = :triggeredRunId
            WITH USER_MODE
        ];
        Assert.areEqual(runRec.Id, triggeredRun.Previous_Run__c, 'New run should link to most recent prior run');
    }

    @isTest
    static void testImportsAndValidation() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Import Suite',
            Target_Agent_Api_Name__c = 'Support_Agent'
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        Integer redTeamCount = AgentGuardDashboardController.importRedTeamTemplates(suite.Id);
        Assert.isTrue(redTeamCount >= 0, 'Should return inserted template count');

        List<Map<String, String>> csvRows = new List<Map<String, String>>{
            new Map<String, String>{
                'Category__c' => 'Functional',
                'Utterance__c' => 'Reset my password',
                'Expected_Topic__c' => 'Account_Security',
                'Expected_Action__c' => 'Send_Reset_Link'
            },
            new Map<String, String>{
                'category' => 'Unknown_Cat',
                'utterance' => 'Check balance',
                'ExpectedTopic' => 'Billing_Info',
                'ExpectedAction' => 'Get_Balance',
                'ForbiddenAction' => 'Delete_Account',
                'ForbiddenRegex' => 'SSN'
            },
            new Map<String, String>{ 'utterance' => '' }
        };

        Integer csvCount = AgentGuardDashboardController.importCsvTestCases(suite.Id, csvRows);
        Assert.areEqual(2, csvCount, 'Should insert 2 valid CSV rows and skip blank utterance');
        Assert.areEqual(0, AgentGuardDashboardController.importCsvTestCases(suite.Id, new List<Map<String, String>>()));

        Agent_Test_Case__c pascalCaseRow = [
            SELECT Expected_Topic__c, Expected_Action__c, Forbidden_Action__c, Forbidden_Regex__c
            FROM Agent_Test_Case__c
            WHERE Agent_Test_Suite__c = :suite.Id AND Expected_Action__c = 'Get_Balance'
            WITH USER_MODE
            LIMIT 1
        ];
        Assert.areEqual('Billing_Info', pascalCaseRow.Expected_Topic__c);
        Assert.areEqual('Get_Balance', pascalCaseRow.Expected_Action__c);
        Assert.areEqual('Delete_Account', pascalCaseRow.Forbidden_Action__c);
        Assert.areEqual('SSN', pascalCaseRow.Forbidden_Regex__c);

        Boolean threwTrigger = false;
        try {
            AgentGuardDashboardController.triggerSuiteRun(null);
        } catch (AuraHandledException ex) {
            threwTrigger = true;
        }
        Assert.isTrue(threwTrigger);

        Boolean threwRedTeam = false;
        try {
            AgentGuardDashboardController.importRedTeamTemplates(null);
        } catch (AuraHandledException ex) {
            threwRedTeam = true;
        }
        Assert.isTrue(threwRedTeam);

        Boolean threwCsv = false;
        try {
            AgentGuardDashboardController.importCsvTestCases(null, csvRows);
        } catch (AuraHandledException ex) {
            threwCsv = true;
        }
        Assert.isTrue(threwCsv);
    }

    @isTest
    static void testRunAsAgentGuardAdmin() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniqueSuffix = String.valueOf(Crypto.getRandomInteger()).replace('-', '') + System.currentTimeMillis();
        User adminUser = new User(
            FirstName = 'AgentGuard',
            LastName = 'AdminTest',
            Email = 'agadmin.' + uniqueSuffix + '@example.com',
            Username = 'agadmin.' + uniqueSuffix + '@example.com',
            Alias = 'agadm',
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id
        );
        insert adminUser;

        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'AgentGuard_Admin' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = adminUser.Id, PermissionSetId = ps.Id);

        System.runAs(adminUser) {
            Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
                Name = 'RunAs Admin Suite',
                Target_Agent_Api_Name__c = 'Support_Agent'
            );
            Database.insert(suite, AccessLevel.USER_MODE);

            Integer imported = AgentGuardDashboardController.importCsvTestCases(
                suite.Id,
                new List<Map<String, String>>{
                    new Map<String, String>{
                        'Utterance' => 'Where is my order?',
                        'ExpectedTopic' => 'Order_Status',
                        'ExpectedAction' => 'Get_Order'
                    }
                }
            );
            Assert.areEqual(1, imported);
            Assert.areEqual(1, AgentGuardDashboardController.getSuites().size());
        }
    }
}
