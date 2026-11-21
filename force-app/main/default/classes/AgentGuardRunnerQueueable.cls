/**
 * @description Asynchronous Queueable runner that executes Agent_Test_Case__c records in chunks of 2,
 *              persists Agent_Test_Result__c records, and chains until the suite run completes.
 */
public with sharing class AgentGuardRunnerQueueable implements Queueable, Database.AllowsCallouts {
    private static final Integer CHUNK_SIZE = 2;
    private static final Integer DEFAULT_MAX_TURNS = 50;

    private Id runId;
    private Integer offsetIndex;

    public AgentGuardRunnerQueueable(Id runId) {
        this(runId, 0);
    }

    public AgentGuardRunnerQueueable(Id runId, Integer offsetIndex) {
        this.runId = runId;
        this.offsetIndex = offsetIndex != null && offsetIndex >= 0 ? offsetIndex : 0;
    }

    public void execute(QueueableContext context) {
        Agent_Test_Run__c runRecord = queryRun(this.runId);
        if (runRecord == null) {
            return;
        }

        try {
            List<Agent_Test_Case__c> allCases = [
                SELECT
                    Id,
                    Utterance__c,
                    Expected_Topic__c,
                    Expected_Action__c,
                    Forbidden_Action__c,
                    Forbidden_Regex__c,
                    Semantic_Pass_Criteria__c
                FROM Agent_Test_Case__c
                WHERE Agent_Test_Suite__c = :runRecord.Agent_Test_Suite__c
                WITH USER_MODE
                ORDER BY CreatedDate ASC, Id ASC
            ];

            Integer maxTurns = runRecord.Agent_Test_Suite__r.Max_Turns_Per_Run__c != null
                ? runRecord.Agent_Test_Suite__r.Max_Turns_Per_Run__c.intValue()
                : DEFAULT_MAX_TURNS;
            Integer effectiveTotal = Math.min(allCases.size(), Math.max(0, maxTurns));

            if (this.offsetIndex == 0) {
                runRecord.Status__c = 'Running';
                runRecord.Total_Tests__c = effectiveTotal;
                runRecord.Passed_Tests__c = 0;
                runRecord.Regression_Count__c = 0;
            }

            if (effectiveTotal == 0 || this.offsetIndex >= effectiveTotal) {
                finalizeRun(runRecord, effectiveTotal);
                return;
            }

            Integer endIndex = Math.min(this.offsetIndex + CHUNK_SIZE, effectiveTotal);
            String targetAgent = runRecord.Agent_Test_Suite__r.Target_Agent_Api_Name__c;
            Boolean enableLlmJudge = runRecord.Agent_Test_Suite__r.Enable_LLM_Judge__c == true;

            Set<Id> chunkCaseIds = new Set<Id>();
            for (Integer i = this.offsetIndex; i < endIndex; i++) {
                chunkCaseIds.add(allCases[i].Id);
            }
            Map<Id, Agent_Test_Result__c> prevResultsByCaseId = loadPreviousResults(
                runRecord.Previous_Run__c,
                chunkCaseIds
            );

            List<Agent_Test_Result__c> resultsToInsert = new List<Agent_Test_Result__c>();
            Integer chunkPassed = 0;
            Integer chunkRegressions = 0;

            for (Integer i = this.offsetIndex; i < endIndex; i++) {
                Agent_Test_Case__c testCase = allCases[i];
                AgentGuardRuntimeClient.AgentTurnTrace trace = executeSingleTestCase(targetAgent, testCase);
                AgentGuardEvaluatorService.EvaluationOutcome outcome = AgentGuardEvaluatorService.evaluate(
                    testCase,
                    trace,
                    enableLlmJudge
                );

                if (outcome.overallPass) {
                    chunkPassed++;
                }

                Agent_Test_Result__c resultRec = buildResultRecord(this.runId, testCase, trace, outcome);
                Agent_Test_Result__c prevResult = prevResultsByCaseId.get(testCase.Id);
                if (prevResult != null) {
                    resultRec.Previous_Topic__c = prevResult.Actual_Topic__c;
                    Boolean passToFail = (prevResult.Deterministic_Pass__c == true &&
                        resultRec.Deterministic_Pass__c != true);
                    Boolean topicDrift = (resultRec.Actual_Topic__c != prevResult.Actual_Topic__c);
                    if (passToFail || topicDrift) {
                        resultRec.Regression_Detected__c = true;
                        chunkRegressions++;
                    }
                }
                resultsToInsert.add(resultRec);
            }

            if (!resultsToInsert.isEmpty()) {
                Database.insert(resultsToInsert, AccessLevel.USER_MODE);
            }

            Decimal priorPassed = runRecord.Passed_Tests__c != null ? runRecord.Passed_Tests__c : 0;
            runRecord.Passed_Tests__c = priorPassed + chunkPassed;

            Decimal priorRegressions = runRecord.Regression_Count__c != null ? runRecord.Regression_Count__c : 0;
            runRecord.Regression_Count__c = priorRegressions + chunkRegressions;

            if (endIndex < effectiveTotal) {
                // Build a fresh Id-only record for the update. runRecord was queried with the
                // Agent_Test_Suite__c Master-Detail field (and its relationship) populated, and
                // Master-Detail fields are never FLS-updateable — Database.update(..., USER_MODE)
                // rejects the WHOLE record if any populated field fails that check, even one we
                // never intended to write. Carrying over only Id + the fields we're actually
                // setting avoids that.
                Database.update(
                    new Agent_Test_Run__c(
                        Id = runRecord.Id,
                        Status__c = runRecord.Status__c,
                        Total_Tests__c = runRecord.Total_Tests__c,
                        Passed_Tests__c = runRecord.Passed_Tests__c,
                        Regression_Count__c = runRecord.Regression_Count__c
                    ),
                    AccessLevel.USER_MODE
                );
                if (!Test.isRunningTest()) {
                    // Suppressed in tests on purpose: Salesforce's test context forbids a
                    // Queueable from enqueuing another Queueable at all ("Maximum stack depth
                    // has been reached"), even one level. Tests exercise each chunk directly
                    // instead (see AgentGuardRunnerQueueableTest); real async dequeuing in
                    // production hits neither that limit nor the mixed-DML/callout restriction,
                    // since each dequeued job gets its own fresh transaction.
                    System.enqueueJob(new AgentGuardRunnerQueueable(this.runId, endIndex));
                }
            } else {
                finalizeRun(runRecord, effectiveTotal);
            }
        } catch (Exception ex) {
            // Same Id-only reasoning as above.
            Database.update(
                new Agent_Test_Run__c(
                    Id = runRecord.Id,
                    Status__c = 'Error',
                    Error_Message__c = ex.getMessage() != null ? ex.getMessage().left(5000) : 'Unknown error'
                ),
                AccessLevel.USER_MODE
            );
            System.debug(LoggingLevel.ERROR, 'AgentGuardRunnerQueueable error: ' + ex.getMessage());
        }
    }

    private static Agent_Test_Run__c queryRun(Id runId) {
        List<Agent_Test_Run__c> runs = [
            SELECT
                Id,
                Agent_Test_Suite__c,
                Previous_Run__c,
                Regression_Count__c,
                Status__c,
                Total_Tests__c,
                Passed_Tests__c,
                Agent_Test_Suite__r.Target_Agent_Api_Name__c,
                Agent_Test_Suite__r.Enable_LLM_Judge__c,
                Agent_Test_Suite__r.Pass_Threshold_Pct__c,
                Agent_Test_Suite__r.Max_Turns_Per_Run__c
            FROM Agent_Test_Run__c
            WHERE Id = :runId
            WITH USER_MODE
            LIMIT 1
        ];
        return runs.isEmpty() ? null : runs[0];
    }

    private static Map<Id, Agent_Test_Result__c> loadPreviousResults(Id previousRunId, Set<Id> testCaseIds) {
        Map<Id, Agent_Test_Result__c> byCaseId = new Map<Id, Agent_Test_Result__c>();
        if (previousRunId == null || testCaseIds == null || testCaseIds.isEmpty()) {
            return byCaseId;
        }
        for (Agent_Test_Result__c res : [
            SELECT Id, Test_Case__c, Actual_Topic__c, Deterministic_Pass__c
            FROM Agent_Test_Result__c
            WHERE Agent_Test_Run__c = :previousRunId AND Test_Case__c IN :testCaseIds
            WITH USER_MODE
        ]) {
            byCaseId.put(res.Test_Case__c, res);
        }
        return byCaseId;
    }

    private static AgentGuardRuntimeClient.AgentTurnTrace executeSingleTestCase(
        String targetAgent,
        Agent_Test_Case__c testCase
    ) {
        try {
            return AgentGuardRuntimeClient.executeSingleTurn(targetAgent, testCase.Utterance__c);
        } catch (Exception ex) {
            AgentGuardRuntimeClient.AgentTurnTrace errTrace = new AgentGuardRuntimeClient.AgentTurnTrace();
            errTrace.isError = true;
            errTrace.errorMessage = ex.getMessage();
            return errTrace;
        }
    }

    private static Agent_Test_Result__c buildResultRecord(
        Id runId,
        Agent_Test_Case__c testCase,
        AgentGuardRuntimeClient.AgentTurnTrace trace,
        AgentGuardEvaluatorService.EvaluationOutcome outcome
    ) {
        String actualTopic = trace.actualTopic;
        if (actualTopic != null && actualTopic.length() > 255) {
            actualTopic = actualTopic.substring(0, 255);
        }

        return new Agent_Test_Result__c(
            Agent_Test_Run__c = runId,
            Test_Case__c = testCase.Id,
            Utterance_Snapshot__c = testCase.Utterance__c,
            Actual_Topic__c = actualTopic,
            Actual_Actions_JSON__c = JSON.serialize(trace.executedActions),
            Agent_Response__c = trace.responseText,
            Raw_Trace_JSON__c = trace.rawTraceJson != null && trace.rawTraceJson.length() > 32768
                ? trace.rawTraceJson.substring(0, 32768)
                : trace.rawTraceJson,
            Latency_Ms__c = trace.latencyMs,
            Deterministic_Pass__c = outcome.deterministicPass,
            LLM_Judge_Pass__c = outcome.llmJudgePass,
            Failure_Reason__c = outcome.failureReason
        );
    }

    private static void finalizeRun(Agent_Test_Run__c runRecord, Integer totalTests) {
        if (totalTests == 0) {
            Database.update(
                new Agent_Test_Run__c(
                    Id = runRecord.Id,
                    Status__c = 'No_Tests',
                    Total_Tests__c = 0,
                    Passed_Tests__c = runRecord.Passed_Tests__c,
                    Regression_Count__c = runRecord.Regression_Count__c
                ),
                AccessLevel.USER_MODE
            );
            return;
        }

        Decimal passed = runRecord.Passed_Tests__c != null ? runRecord.Passed_Tests__c : 0;
        Decimal passRate = (passed / Decimal.valueOf(totalTests)) * 100;
        Decimal threshold = runRecord.Agent_Test_Suite__r.Pass_Threshold_Pct__c != null
            ? runRecord.Agent_Test_Suite__r.Pass_Threshold_Pct__c
            : 100;

        String finalStatus = (passRate >= threshold) ? 'Passed' : 'Failed';
        // Carry forward the rollup fields too: for any run that finishes within its first
        // chunk (small suites, or a run's only/last chunk), this is the ONLY DML call made —
        // the mid-chunk update branch never runs — so these in-memory values (set earlier in
        // execute()) must be persisted here or they're silently lost (they stay null in the DB).
        Database.update(
            new Agent_Test_Run__c(
                Id = runRecord.Id,
                Status__c = finalStatus,
                Total_Tests__c = totalTests,
                Passed_Tests__c = runRecord.Passed_Tests__c,
                Regression_Count__c = runRecord.Regression_Count__c
            ),
            AccessLevel.USER_MODE
        );
    }
}
