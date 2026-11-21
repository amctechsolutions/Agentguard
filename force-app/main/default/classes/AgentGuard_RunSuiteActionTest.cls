@isTest
public with sharing class AgentGuard_RunSuiteActionTest {
    private class SimpleRuntimeMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"sessionId":"sess-invocable"}');
            return res;
        }
    }

    @isTest
    static void testRunSuitesSuccess() {
        Agent_Test_Suite__c suite = new Agent_Test_Suite__c(
            Name = 'Invocable Suite',
            Target_Agent_Api_Name__c = 'Support_Agent'
        );
        Database.insert(suite, AccessLevel.USER_MODE);

        Agent_Test_Run__c baselineRun = new Agent_Test_Run__c(
            Agent_Test_Suite__c = suite.Id,
            Status__c = 'Passed',
            Total_Tests__c = 1,
            Passed_Tests__c = 1
        );
        Database.insert(baselineRun, AccessLevel.USER_MODE);

        AgentGuard_RunSuiteAction.SuiteRunRequest req = new AgentGuard_RunSuiteAction.SuiteRunRequest();
        req.suiteId = suite.Id;

        Test.setMock(HttpCalloutMock.class, new SimpleRuntimeMock());
        Test.startTest();
        List<AgentGuard_RunSuiteAction.SuiteRunResult> results = AgentGuard_RunSuiteAction.runSuites(
            new List<AgentGuard_RunSuiteAction.SuiteRunRequest>{ req }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isNotNull(results[0].runId);
        Assert.areEqual('Queued', results[0].status);

        List<Agent_Test_Run__c> runs = [
            SELECT Id, Agent_Test_Suite__c, Previous_Run__c
            FROM Agent_Test_Run__c
            WHERE Id = :results[0].runId
            WITH USER_MODE
        ];
        Assert.areEqual(1, runs.size());
        Assert.areEqual(suite.Id, runs[0].Agent_Test_Suite__c);
        Assert.areEqual(baselineRun.Id, runs[0].Previous_Run__c, 'RunSuiteAction must resolve Previous_Run__c baseline');
    }

    @isTest
    static void testRunSuitesEdgeCases() {
        List<AgentGuard_RunSuiteAction.SuiteRunResult> emptyResults = AgentGuard_RunSuiteAction.runSuites(
            new List<AgentGuard_RunSuiteAction.SuiteRunRequest>()
        );
        Assert.areEqual(0, emptyResults.size());

        Boolean threw = false;
        try {
            AgentGuard_RunSuiteAction.SuiteRunRequest badReq = new AgentGuard_RunSuiteAction.SuiteRunRequest();
            AgentGuard_RunSuiteAction.runSuites(new List<AgentGuard_RunSuiteAction.SuiteRunRequest>{ badReq });
        } catch (IllegalArgumentException ex) {
            threw = true;
        }
        Assert.isTrue(threw, 'Null suiteId should throw IllegalArgumentException');
    }
}
