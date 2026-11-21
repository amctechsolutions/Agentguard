/**
 * @description LWC controller for the AgentGuard Dashboard, providing suite/run/result queries,
 *              test execution triggering, Red-Team template imports, and CSV test case imports.
 */
public with sharing class AgentGuardDashboardController {
    private static final Set<String> VALID_CATEGORIES = new Set<String>{
        'Functional',
        'Prompt_Injection',
        'PII_Leakage',
        'Policy_Bypass',
        'Brand_Safety'
    };

    /**
     * @description Returns all Agent_Test_Suite__c records accessible to the current user.
     */
    @AuraEnabled(cacheable=true)
    public static List<Agent_Test_Suite__c> getSuites() {
        return [
            SELECT
                Id,
                Name,
                Target_Agent_Api_Name__c,
                Channel_Mode__c,
                Enable_LLM_Judge__c,
                Pass_Threshold_Pct__c,
                Max_Turns_Per_Run__c,
                CreatedDate
            FROM Agent_Test_Suite__c
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
    }

    /**
     * @description Returns execution runs for a given Agent_Test_Suite__c.
     */
    @AuraEnabled(cacheable=true)
    public static List<Agent_Test_Run__c> getRunsForSuite(Id suiteId) {
        if (suiteId == null) {
            return new List<Agent_Test_Run__c>();
        }
        return [
            SELECT
                Id,
                Name,
                Agent_Test_Suite__c,
                Status__c,
                Total_Tests__c,
                Passed_Tests__c,
                Pass_Rate__c,
                Previous_Run__c,
                Regression_Count__c,
                Error_Message__c,
                Executed_By_Context__c,
                CreatedDate
            FROM Agent_Test_Run__c
            WHERE Agent_Test_Suite__c = :suiteId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 100
        ];
    }

    /**
     * @description Returns individual test results for a given Agent_Test_Run__c.
     */
    @AuraEnabled(cacheable=true)
    public static List<Agent_Test_Result__c> getResultsForRun(Id runId) {
        if (runId == null) {
            return new List<Agent_Test_Result__c>();
        }
        return [
            SELECT
                Id,
                Name,
                Agent_Test_Run__c,
                Test_Case__c,
                Test_Case__r.Name,
                Test_Case__r.Category__c,
                Test_Case__r.Utterance__c,
                Test_Case__r.Expected_Topic__c,
                Test_Case__r.Expected_Action__c,
                Utterance_Snapshot__c,
                Actual_Topic__c,
                Actual_Actions_JSON__c,
                Agent_Response__c,
                Latency_Ms__c,
                Deterministic_Pass__c,
                LLM_Judge_Pass__c,
                Regression_Detected__c,
                Previous_Topic__c,
                Failure_Reason__c
            FROM Agent_Test_Result__c
            WHERE Agent_Test_Run__c = :runId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 500
        ];
    }

    /**
     * @description Triggers an asynchronous test suite run and returns the created Agent_Test_Run__c Id.
     */
    @AuraEnabled
    public static Id triggerSuiteRun(Id suiteId) {
        if (suiteId == null) {
            throw createAuraException('Suite ID is required.');
        }

        AgentGuard_RunSuiteAction.SuiteRunRequest req = new AgentGuard_RunSuiteAction.SuiteRunRequest();
        req.suiteId = suiteId;

        List<AgentGuard_RunSuiteAction.SuiteRunResult> results = AgentGuard_RunSuiteAction.runSuites(
            new List<AgentGuard_RunSuiteAction.SuiteRunRequest>{ req }
        );
        return results[0].runId;
    }

    /**
     * @description Imports all RedTeam_Template__mdt records as Agent_Test_Case__c rows for the given suite.
     * @return Number of Agent_Test_Case__c records inserted.
     */
    @AuraEnabled
    public static Integer importRedTeamTemplates(Id suiteId) {
        if (suiteId == null) {
            throw createAuraException('Suite ID is required.');
        }

        List<RedTeam_Template__mdt> templates = [
            SELECT
                DeveloperName,
                Attack_Name__c,
                Category__c,
                Forbidden_Regex__c,
                Semantic_Pass_Criteria__c,
                Severity__c,
                Utterance__c
            FROM RedTeam_Template__mdt
            WITH USER_MODE
            ORDER BY DeveloperName ASC
        ];

        List<Agent_Test_Case__c> casesToInsert = new List<Agent_Test_Case__c>();
        for (RedTeam_Template__mdt tmpl : templates) {
            String category = VALID_CATEGORIES.contains(tmpl.Category__c) ? tmpl.Category__c : 'Prompt_Injection';
            casesToInsert.add(
                new Agent_Test_Case__c(
                    Agent_Test_Suite__c = suiteId,
                    Category__c = category,
                    Utterance__c = tmpl.Utterance__c,
                    Forbidden_Regex__c = truncateText(tmpl.Forbidden_Regex__c, 255),
                    Semantic_Pass_Criteria__c = tmpl.Semantic_Pass_Criteria__c
                )
            );
        }

        if (!casesToInsert.isEmpty()) {
            Database.insert(casesToInsert, AccessLevel.USER_MODE);
        }
        return casesToInsert.size();
    }

    /**
     * @description Imports CSV-parsed test case maps as Agent_Test_Case__c records for the given suite.
     * @return Number of Agent_Test_Case__c records inserted.
     */
    @AuraEnabled
    public static Integer importCsvTestCases(Id suiteId, List<Map<String, String>> rows) {
        if (suiteId == null) {
            throw createAuraException('Suite ID is required.');
        }
        if (rows == null || rows.isEmpty()) {
            return 0;
        }

        List<Agent_Test_Case__c> casesToInsert = new List<Agent_Test_Case__c>();
        for (Map<String, String> row : rows) {
            if (row == null || row.isEmpty()) {
                continue;
            }
            String utterance = getField(row, new List<String>{ 'Utterance__c', 'utterance', 'Utterance' });
            if (String.isBlank(utterance)) {
                continue;
            }

            String rawCategory = getField(row, new List<String>{ 'Category__c', 'category', 'Category' });
            String category = VALID_CATEGORIES.contains(rawCategory) ? rawCategory : 'Functional';

            casesToInsert.add(
                new Agent_Test_Case__c(
                    Agent_Test_Suite__c = suiteId,
                    Category__c = category,
                    Utterance__c = utterance,
                    Expected_Topic__c = truncateText(
                        getField(
                            row,
                            new List<String>{ 'Expected_Topic__c', 'expectedTopic', 'ExpectedTopic', 'Expected_Topic' }
                        ),
                        255
                    ),
                    Expected_Action__c = truncateText(
                        getField(
                            row,
                            new List<String>{
                                'Expected_Action__c',
                                'expectedAction',
                                'ExpectedAction',
                                'Expected_Action'
                            }
                        ),
                        255
                    ),
                    Forbidden_Action__c = truncateText(
                        getField(
                            row,
                            new List<String>{
                                'Forbidden_Action__c',
                                'forbiddenAction',
                                'ForbiddenAction',
                                'Forbidden_Action'
                            }
                        ),
                        255
                    ),
                    Forbidden_Regex__c = truncateText(
                        getField(
                            row,
                            new List<String>{
                                'Forbidden_Regex__c',
                                'forbiddenRegex',
                                'ForbiddenRegex',
                                'Forbidden_Regex'
                            }
                        ),
                        255
                    ),
                    Semantic_Pass_Criteria__c = getField(
                        row,
                        new List<String>{
                            'Semantic_Pass_Criteria__c',
                            'semanticPassCriteria',
                            'SemanticPassCriteria',
                            'Semantic_Pass_Criteria'
                        }
                    )
                )
            );
        }

        if (!casesToInsert.isEmpty()) {
            Database.insert(casesToInsert, AccessLevel.USER_MODE);
        }
        return casesToInsert.size();
    }

    private static String getField(Map<String, String> row, List<String> keys) {
        for (String key : keys) {
            if (row.containsKey(key) && String.isNotBlank(row.get(key))) {
                return row.get(key).trim();
            }
        }
        return null;
    }

    private static String truncateText(String value, Integer maxLen) {
        if (value == null) {
            return null;
        }
        return value.length() > maxLen ? value.substring(0, maxLen) : value;
    }

    private static AuraHandledException createAuraException(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
