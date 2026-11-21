@isTest
public with sharing class AgentGuardRunnerQueueableTest {
    private class AgentMultiEndpointMock implements HttpCalloutMock {
        private Boolean failSessionStart;

        public AgentMultiEndpointMock(Boolean failSessionStart) {
            this.failSessionStart = failSessionStart;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String endpoint = req.getEndpoint();
            if (endpoint.contains('/sessions') && req.getMethod() == 'POST' && !endpoint.contains('/messages')) {
                if (failSessionStart == true) {
                    res.setStatusCode(500);
                    res.setBody('Internal Error');
                    return res;
                }
                res.setStatusCode(200);
                res.setBody('{"sessionId":"sess-abc"}');
                return res;
            }
            if (endpoint.contains('/messages')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"messages":[{"message":"Order is shipped."}],"trace":{"topic":"Order_Status","actions":["Get_Order"]}}'
                );
                return res;
            }
            if (req.getMethod() == 'DELETE') {
                res.setStatusCode(204);
                return res;
            }
            res.setStatusCode(404);
            return res;
        }
    }

    @isTest
    static void testChunkedExecutionPassed() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Regression Suite',
            Target_Agent_Api_Name__c = 'Support_Agent',
            Enable_LLM_Judge__c = false,
            Pass_Threshold_Pct__c = 80
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        List<Agent_Test_Case__c> cases = new List<Agent_Test_Case__c>();
        for (Integer i = 0; i < 6; i++) {
            cases.add(
                new Agent_Test_Case__c(
                    Agent_Test_Suite__c = suite.Id,
                    Category__c = 'Functional',
                    Utterance__c = 'Check order ' + i,
                    Expected_Topic__c = 'Order_Status',
                    Expected_Action__c = 'Get_Order'
                )
            );
        }
        Database.insert(cases, AccessLevel.USER_MODE);

        // Seed state as if chunks 0 and 1 (cases 0..3) already ran and persisted, so the test
        // can drive only the LAST chunk's real .execute() call. Real chaining can't be driven
        // end-to-end in a test: Salesforce's test context forbids a Queueable from enqueuing
        // another Queueable at all ("Maximum stack depth has been reached"), and driving every
        // chunk via direct, sequential .execute(null, offset) calls instead hits a different
        // platform rule — a later chunk's callout following an earlier chunk's DML within the
        // SAME transaction ("uncommitted work pending... before calling out"). Seeding prior
        // state and exercising one real chunk is the standard way to test this shape of class.
        Agent_Test_Run__c runRec = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Running',
            Total_Tests__c = 6,
            Passed_Tests__c = 4,
            Regression_Count__c = 0
        );
        Database.insert(runRec, AccessLevel.USER_MODE);

        List<Agent_Test_Result__c> seededResults = new List<Agent_Test_Result__c>();
        for (Integer i = 0; i < 4; i++) {
            seededResults.add(
                new Agent_Test_Result__c(
                    Agent_Test_Run__c = runRec.Id,
                    Test_Case__c = cases[i].Id,
                    Utterance_Snapshot__c = cases[i].Utterance__c,
                    Actual_Topic__c = 'Order_Status',
                    Deterministic_Pass__c = true,
                    LLM_Judge_Pass__c = true
                )
            );
        }
        Database.insert(seededResults, AccessLevel.USER_MODE);

        Test.setMock(HttpCalloutMock.class, new AgentMultiEndpointMock(false));
        Test.startTest();
        // Drive only the final chunk (cases 4..5) for real: one round of callouts, then DML.
        new AgentGuardRunnerQueueable(runRec.Id, 4).execute(null);
        Test.stopTest();

        Agent_Test_Run__c updated = [
            SELECT Status__c, Total_Tests__c, Passed_Tests__c, Pass_Rate__c
            FROM Agent_Test_Run__c
            WHERE Id = :runRec.Id
            WITH USER_MODE
        ];
        Assert.areEqual('Passed', updated.Status__c);
        Assert.areEqual(6, updated.Total_Tests__c);
        Assert.areEqual(6, updated.Passed_Tests__c);
        Assert.areEqual(100, updated.Pass_Rate__c);

        List<Agent_Test_Result__c> results = [
            SELECT Id, Utterance_Snapshot__c
            FROM Agent_Test_Result__c
            WHERE Agent_Test_Run__c = :runRec.Id
            WITH USER_MODE
        ];
        Assert.areEqual(6, results.size());
        Assert.isTrue(results[0].Utterance_Snapshot__c.startsWith('Check order '));
    }

    @isTest
    static void testFailedRollupOnRuntimeError() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Failing Suite',
            Target_Agent_Api_Name__c = 'Support_Agent',
            Enable_LLM_Judge__c = false,
            Pass_Threshold_Pct__c = 100
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        Database.insert(
            new Agent_Test_Case__c(
                Agent_Test_Suite__c = suite.Id,
                Utterance__c = 'Hello'
            ),
            AccessLevel.USER_MODE
        );

        Agent_Test_Run__c runRec = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Queued'
        );
        Database.insert(runRec, AccessLevel.USER_MODE);

        Test.setMock(HttpCalloutMock.class, new AgentMultiEndpointMock(true));
        Test.startTest();
        System.enqueueJob(new AgentGuardRunnerQueueable(runRec.Id));
        Test.stopTest();

        Agent_Test_Run__c updated = [
            SELECT Status__c, Passed_Tests__c, Pass_Rate__c
            FROM Agent_Test_Run__c
            WHERE Id = :runRec.Id
            WITH USER_MODE
        ];
        Assert.areEqual('Failed', updated.Status__c);
        Assert.areEqual(0, updated.Passed_Tests__c);
        Assert.areEqual(0, updated.Pass_Rate__c);
    }

    @isTest
    static void testEmptySuiteFinalizes() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Empty Suite',
            Target_Agent_Api_Name__c = 'Support_Agent'
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        Agent_Test_Run__c runRec = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Queued'
        );
        Database.insert(runRec, AccessLevel.USER_MODE);

        Test.startTest();
        new AgentGuardRunnerQueueable(runRec.Id).execute(null);
        Test.stopTest();

        Agent_Test_Run__c updated = [
            SELECT Status__c, Total_Tests__c
            FROM Agent_Test_Run__c
            WHERE Id = :runRec.Id
            WITH USER_MODE
        ];
        Assert.areEqual('No_Tests', updated.Status__c);
        Assert.areEqual(0, updated.Total_Tests__c);
    }

    @isTest
    static void testBudgetCapTruncation() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Budget Capped Suite',
            Target_Agent_Api_Name__c = 'Support_Agent',
            Enable_LLM_Judge__c = false,
            Pass_Threshold_Pct__c = 100,
            Max_Turns_Per_Run__c = 3
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        List<Agent_Test_Case__c> cases = new List<Agent_Test_Case__c>();
        for (Integer i = 0; i < 7; i++) {
            cases.add(
                new Agent_Test_Case__c(
                    Agent_Test_Suite__c = suite.Id,
                    Category__c = 'Functional',
                    Utterance__c = 'Check order ' + i,
                    Expected_Topic__c = 'Order_Status',
                    Expected_Action__c = 'Get_Order'
                )
            );
        }
        Database.insert(cases, AccessLevel.USER_MODE);

        // Seed state as if chunk 0 (cases 0..1) already ran and persisted, so the test can
        // drive only the final chunk's real .execute() call — see testChunkedExecutionPassed
        // for why real chaining and sequential .execute(null, offset) calls both fail here.
        Agent_Test_Run__c runRec = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Running',
            Total_Tests__c = 3,
            Passed_Tests__c = 2,
            Regression_Count__c = 0
        );
        Database.insert(runRec, AccessLevel.USER_MODE);

        List<Agent_Test_Result__c> seededResults = new List<Agent_Test_Result__c>();
        for (Integer i = 0; i < 2; i++) {
            seededResults.add(
                new Agent_Test_Result__c(
                    Agent_Test_Run__c = runRec.Id,
                    Test_Case__c = cases[i].Id,
                    Utterance_Snapshot__c = cases[i].Utterance__c,
                    Actual_Topic__c = 'Order_Status',
                    Deterministic_Pass__c = true,
                    LLM_Judge_Pass__c = true
                )
            );
        }
        Database.insert(seededResults, AccessLevel.USER_MODE);

        Test.setMock(HttpCalloutMock.class, new AgentMultiEndpointMock(false));
        Test.startTest();
        // Drive only the final chunk (case index 2, the 3rd of the budget-capped 3) for real.
        new AgentGuardRunnerQueueable(runRec.Id, 2).execute(null);
        Test.stopTest();

        Agent_Test_Run__c updated = [
            SELECT Status__c, Total_Tests__c, Passed_Tests__c, Pass_Rate__c
            FROM Agent_Test_Run__c
            WHERE Id = :runRec.Id
            WITH USER_MODE
        ];
        Assert.areEqual('Passed', updated.Status__c);
        Assert.areEqual(3, updated.Total_Tests__c, 'Budget cap should limit total tests to Max_Turns_Per_Run__c');
        Assert.areEqual(3, updated.Passed_Tests__c);
        Assert.areEqual(100, updated.Pass_Rate__c);

        Integer resultCount = [
            SELECT COUNT()
            FROM Agent_Test_Result__c
            WHERE Agent_Test_Run__c = :runRec.Id
            WITH USER_MODE
        ];
        Assert.areEqual(3, resultCount, 'Should only execute and persist 3 turns');
    }

    @isTest
    static void testVersionDiffRegressionDetection() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Version Diff Suite',
            Target_Agent_Api_Name__c = 'Support_Agent',
            Enable_LLM_Judge__c = false,
            Pass_Threshold_Pct__c = 100
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        Agent_Test_Case__c driftCase = new Agent_Test_Case__c(
            Agent_Test_Suite__c = suite.Id,
            Category__c = 'Functional',
            Utterance__c = 'Where is my package?',
            Expected_Topic__c = 'Order_Status',
            Expected_Action__c = 'Get_Order'
        );
        Agent_Test_Case__c stableCase = new Agent_Test_Case__c(
            Agent_Test_Suite__c = suite.Id,
            Category__c = 'Functional',
            Utterance__c = 'Check order status',
            Expected_Topic__c = 'Order_Status',
            Expected_Action__c = 'Get_Order'
        );
        Agent_Test_Case__c failRegressionCase = new Agent_Test_Case__c(
            Agent_Test_Suite__c = suite.Id,
            Category__c = 'Functional',
            Utterance__c = 'Cancel my order',
            Expected_Topic__c = 'Order_Status',
            Expected_Action__c = 'Cancel_Order'
        );
        Database.insert(
            new List<Agent_Test_Case__c>{ driftCase, stableCase, failRegressionCase },
            AccessLevel.USER_MODE
        );

        Agent_Test_Run__c priorRun = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Passed',
            Total_Tests__c = 3,
            Passed_Tests__c = 3
        );
        Database.insert(priorRun, AccessLevel.USER_MODE);

        Database.insert(
            new List<Agent_Test_Result__c>{
                new Agent_Test_Result__c(
                    Agent_Test_Run__c = priorRun.Id,
                    Test_Case__c = driftCase.Id,
                    Actual_Topic__c = 'Billing_Support',
                    Deterministic_Pass__c = true
                ),
                new Agent_Test_Result__c(
                    Agent_Test_Run__c = priorRun.Id,
                    Test_Case__c = stableCase.Id,
                    Actual_Topic__c = 'Order_Status',
                    Deterministic_Pass__c = true
                ),
                new Agent_Test_Result__c(
                    Agent_Test_Run__c = priorRun.Id,
                    Test_Case__c = failRegressionCase.Id,
                    Actual_Topic__c = 'Order_Status',
                    Deterministic_Pass__c = true
                )
            },
            AccessLevel.USER_MODE
        );

        Agent_Test_Run__c newRun = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Previous_Run__c = priorRun.Id,
            Status__c = 'Queued'
        );
        Database.insert(newRun, AccessLevel.USER_MODE);

        Test.setMock(HttpCalloutMock.class, new AgentMultiEndpointMock(false));
        Test.startTest();
        new AgentGuardRunnerQueueable(newRun.Id, 0).execute(null);
        new AgentGuardRunnerQueueable(newRun.Id, 2).execute(null);
        Test.stopTest();

        Agent_Test_Run__c updatedRun = [
            SELECT Status__c, Previous_Run__c, Regression_Count__c, Total_Tests__c, Passed_Tests__c
            FROM Agent_Test_Run__c
            WHERE Id = :newRun.Id
            WITH USER_MODE
        ];
        Assert.areEqual(priorRun.Id, updatedRun.Previous_Run__c);
        Assert.areEqual(2, updatedRun.Regression_Count__c, 'Should detect 1 topic drift + 1 pass-to-fail regression');
        Assert.areEqual('Failed', updatedRun.Status__c);
        Assert.areEqual(3, updatedRun.Total_Tests__c);
        Assert.areEqual(2, updatedRun.Passed_Tests__c);

        Map<Id, Agent_Test_Result__c> resultsByCase = new Map<Id, Agent_Test_Result__c>();
        for (Agent_Test_Result__c res : [
            SELECT
                Test_Case__c,
                Utterance_Snapshot__c,
                Actual_Topic__c,
                Previous_Topic__c,
                Deterministic_Pass__c,
                Regression_Detected__c
            FROM Agent_Test_Result__c
            WHERE Agent_Test_Run__c = :newRun.Id
            WITH USER_MODE
        ]) {
            resultsByCase.put(res.Test_Case__c, res);
        }

        Agent_Test_Result__c driftRes = resultsByCase.get(driftCase.Id);
        Assert.areEqual(true, driftRes.Regression_Detected__c, 'Topic drift should flag regression');
        Assert.areEqual('Billing_Support', driftRes.Previous_Topic__c);
        Assert.areEqual('Order_Status', driftRes.Actual_Topic__c);
        Assert.areEqual('Where is my package?', driftRes.Utterance_Snapshot__c);

        Agent_Test_Result__c stableRes = resultsByCase.get(stableCase.Id);
        Assert.areEqual(false, stableRes.Regression_Detected__c, 'Matching topic and pass should not flag regression');
        Assert.areEqual('Order_Status', stableRes.Previous_Topic__c);

        Agent_Test_Result__c failRes = resultsByCase.get(failRegressionCase.Id);
        Assert.areEqual(true, failRes.Regression_Detected__c, 'Pass-to-fail should flag regression');
        Assert.areEqual(false, failRes.Deterministic_Pass__c);
        Assert.areEqual('Order_Status', failRes.Previous_Topic__c);
    }

    private class OversizedResponseMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String endpoint = req.getEndpoint();
            if (endpoint.contains('/sessions') && req.getMethod() == 'POST' && !endpoint.contains('/messages')) {
                res.setStatusCode(200);
                res.setBody('{"sessionId":"sess-err"}');
                return res;
            }
            if (endpoint.contains('/messages')) {
                res.setStatusCode(200);
                res.setBody('{"messages":[{"message":"' + 'A'.repeat(33000) + '"}],"trace":{"topic":"Order_Status"}}');
                return res;
            }
            res.setStatusCode(204);
            return res;
        }
    }

    @isTest
    static void testErrorMessagePersistedOnException() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Error Persistence Suite',
            Target_Agent_Api_Name__c = 'Support_Agent'
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        Database.insert(
            new Agent_Test_Case__c(Agent_Test_Suite__c = suite.Id, Utterance__c = 'Trigger oversized DML error'),
            AccessLevel.USER_MODE
        );

        Agent_Test_Run__c runRec = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Queued'
        );
        Database.insert(runRec, AccessLevel.USER_MODE);

        Test.setMock(HttpCalloutMock.class, new OversizedResponseMock());
        Test.startTest();
        new AgentGuardRunnerQueueable(runRec.Id, 0).execute(null);
        Test.stopTest();

        Agent_Test_Run__c updated = [
            SELECT Status__c, Error_Message__c
            FROM Agent_Test_Run__c
            WHERE Id = :runRec.Id
            WITH USER_MODE
        ];
        Assert.areEqual('Error', updated.Status__c);
        Assert.isTrue(String.isNotBlank(updated.Error_Message__c), 'Error_Message__c should be populated on exception');
    }
}
