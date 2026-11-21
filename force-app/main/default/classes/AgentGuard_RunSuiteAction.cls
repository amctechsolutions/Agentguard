/**
 * @description Invocable Action allowing Flow, Agentforce, or Apex callers to trigger
 *              an asynchronous AgentGuard test suite run.
 */
public with sharing class AgentGuard_RunSuiteAction {
    public class SuiteRunRequest {
        @InvocableVariable(required=true label='Suite ID' description='ID of the Agent_Test_Suite__c to execute')
        public Id suiteId;
    }

    public class SuiteRunResult {
        @InvocableVariable(label='Run ID' description='Created Agent_Test_Run__c record ID')
        public Id runId;

        @InvocableVariable(label='Status' description='Initial status of the test run')
        public String status;
    }

    /**
     * @description Queues test runs for the requested Agent_Test_Suite__c IDs.
     * @param requests List of SuiteRunRequest containing suiteId.
     * @return List of SuiteRunResult with created runId and Queued status.
     */
    @InvocableMethod(
        label='Run AgentGuard Test Suite'
        description='Executes regression & red-team suite against an Agentforce Agent'
    )
    public static List<SuiteRunResult> runSuites(List<SuiteRunRequest> requests) {
        List<SuiteRunResult> results = new List<SuiteRunResult>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        Set<Id> suiteIds = new Set<Id>();
        for (SuiteRunRequest req : requests) {
            if (req == null || req.suiteId == null) {
                throw new IllegalArgumentException('Suite ID is required.');
            }
            suiteIds.add(req.suiteId);
        }

        Map<Id, Id> latestPriorRunBySuite = resolveLatestPriorRuns(suiteIds);
        List<Agent_Test_Run__c> runsToInsert = new List<Agent_Test_Run__c>();
        String contextUser = UserInfo.getUserName();

        for (SuiteRunRequest req : requests) {
            runsToInsert.add(
                new Agent_Test_Run__c(
                    Agent_Test_Suite__c = req.suiteId,
                    Previous_Run__c = latestPriorRunBySuite.get(req.suiteId),
                    Status__c = 'Queued',
                    Executed_By_Context__c = contextUser
                )
            );
        }

        Database.insert(runsToInsert, AccessLevel.USER_MODE);

        for (Agent_Test_Run__c runRec : runsToInsert) {
            System.enqueueJob(new AgentGuardRunnerQueueable(runRec.Id));
            SuiteRunResult res = new SuiteRunResult();
            res.runId = runRec.Id;
            res.status = runRec.Status__c;
            results.add(res);
        }

        return results;
    }

    private static Map<Id, Id> resolveLatestPriorRuns(Set<Id> suiteIds) {
        Map<Id, Id> latestBySuite = new Map<Id, Id>();
        if (suiteIds == null || suiteIds.isEmpty()) {
            return latestBySuite;
        }
        for (Agent_Test_Run__c priorRun : [
            SELECT Id, Agent_Test_Suite__c
            FROM Agent_Test_Run__c
            WHERE Agent_Test_Suite__c IN :suiteIds AND Status__c IN ('Passed', 'Failed')
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
        ]) {
            if (!latestBySuite.containsKey(priorRun.Agent_Test_Suite__c)) {
                latestBySuite.put(priorRun.Agent_Test_Suite__c, priorRun.Id);
            }
        }
        return latestBySuite;
    }
}
