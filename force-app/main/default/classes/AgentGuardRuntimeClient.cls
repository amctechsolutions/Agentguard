/**
 * @description HTTP runtime client for executing Agentforce agent sessions and turns
 *              via Named Credential (callout:Self_Agent_Runtime_NC).
 */
public with sharing class AgentGuardRuntimeClient {
    private static final String NAMED_CREDENTIAL_PREFIX = 'callout:Self_Agent_Runtime_NC';
    private static final Integer DEFAULT_TIMEOUT_MS = 30000;

    public class AgentGuardRuntimeException extends Exception {}

    /**
     * @description Trace wrapper capturing agent response, topic, actions, latency, and error state.
     */
    public class AgentTurnTrace {
        @AuraEnabled public String actualTopic { get; set; }
        @AuraEnabled public List<String> executedActions { get; set; }
        @AuraEnabled public String responseText { get; set; }
        @AuraEnabled public Integer latencyMs { get; set; }
        @AuraEnabled public String rawTraceJson { get; set; }
        @AuraEnabled public Boolean isError { get; set; }
        @AuraEnabled public String errorMessage { get; set; }

        public AgentTurnTrace() {
            this.executedActions = new List<String>();
            this.latencyMs = 0;
            this.isError = false;
        }
    }

    /**
     * @description Starts an Agentforce runtime session for the given agent API name.
     * @param agentApiName Developer/API name of the target Agentforce agent.
     * @return The created runtime sessionId.
     */
    public static String startSession(String agentApiName) {
        if (String.isBlank(agentApiName)) {
            throw new AgentGuardRuntimeException('Target Agent API Name cannot be blank.');
        }

        String agentId = resolveAgentId(agentApiName.trim());
        String encodedAgent = EncodingUtil.urlEncode(agentId, 'UTF-8');
        String endpoint = NAMED_CREDENTIAL_PREFIX + '/einstein/ai-agent/v1/agents/' + encodedAgent + '/sessions';

        Map<String, Object> payload = new Map<String, Object>{
            'externalSessionKey' => String.valueOf(Crypto.getRandomLong()) + '-' + String.valueOf(System.currentTimeMillis()),
            'instanceConfig' => new Map<String, Object>{
                'endpoint' => URL.getOrgDomainUrl().toExternalForm()
            },
            'featureSupport' => 'Sync',
            'bypassUser' => true,
            'tz' => 'America/Chicago'
        };

        HttpRequest req = buildJsonRequest('POST', endpoint, JSON.serialize(payload));
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException ex) {
            throw new AgentGuardRuntimeException('Session start callout failed: ' + ex.getMessage(), ex);
        }

        Integer statusCode = res.getStatusCode();
        if (statusCode == 429) {
            throw new AgentGuardRuntimeException('Agent runtime rate limit exceeded (HTTP 429) on session start.');
        }
        if (statusCode < 200 || statusCode >= 300) {
            throw new AgentGuardRuntimeException(
                'Failed to start agent session (HTTP ' + statusCode + '): ' + res.getBody()
            );
        }

        Map<String, Object> parsed = parseJsonObject(res.getBody());
        String sessionId = (String) parsed.get('sessionId');
        if (String.isBlank(sessionId)) {
            throw new AgentGuardRuntimeException('Agent runtime did not return a sessionId.');
        }
        return sessionId;
    }

    /**
     * @description Executes a single-turn Agentforce invocation natively via Invocable.Action
     *              ('generateAiAgentResponse') with zero Named Credential or OAuth setup required.
     *              In unit tests, delegates to the HTTP mockable session/turn path.
     * @param agentApiName DeveloperName of the target Agentforce BotDefinition.
     * @param utterance User prompt/utterance to send.
     * @return AgentTurnTrace containing response text, latency, and raw trace JSON.
     */
    public static AgentTurnTrace executeSingleTurn(String agentApiName, String utterance) {
        if (Test.isRunningTest()) {
            String sessionId;
            try {
                sessionId = startSession(agentApiName);
                return sendTurn(sessionId, utterance);
            } finally {
                if (String.isNotBlank(sessionId)) {
                    endSession(sessionId);
                }
            }
        }

        AgentTurnTrace trace = new AgentTurnTrace();
        if (String.isBlank(agentApiName)) {
            trace.isError = true;
            trace.errorMessage = 'Target Agent API Name cannot be blank.';
            return trace;
        }

        Long startMs = System.currentTimeMillis();
        try {
            Invocable.Action action = Invocable.Action.createCustomAction('generateAiAgentResponse', agentApiName.trim());
            action.setInvocationParameter('userMessage', utterance != null ? utterance : '');
            List<Invocable.Action.Result> results = action.invoke();
            trace.latencyMs = Integer.valueOf(System.currentTimeMillis() - startMs);
            trace.rawTraceJson = JSON.serialize(results);

            if (results == null || results.isEmpty()) {
                trace.isError = true;
                trace.errorMessage = 'Agent invocable action returned no results.';
                return trace;
            }

            Invocable.Action.Result first = results[0];
            if (!first.isSuccess()) {
                trace.isError = true;
                trace.errorMessage = 'Agent invocation failed: ' + JSON.serialize(first.getErrors());
                return trace;
            }

            Map<String, Object> outParams = first.getOutputParameters();
            if (outParams != null && outParams.containsKey('agentResponse')) {
                String rawResp = String.valueOf(outParams.get('agentResponse'));
                trace.responseText = extractInvocableResponseText(rawResp);
            }
        } catch (Exception ex) {
            trace.latencyMs = Integer.valueOf(System.currentTimeMillis() - startMs);
            trace.isError = true;
            trace.errorMessage = ex.getMessage();
        }
        return trace;
    }

    private static String extractInvocableResponseText(String rawResp) {
        if (String.isBlank(rawResp)) {
            return '';
        }
        try {
            Object parsed = JSON.deserializeUntyped(rawResp);
            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) parsed;
                if (m.get('value') != null) {
                    return String.valueOf(m.get('value'));
                }
                if (m.get('message') != null) {
                    return String.valueOf(m.get('message'));
                }
            }
        } catch (Exception ignored) {
            // Fall through and return raw response string
        }
        return rawResp;
    }

    /**
     * @description Sends a user utterance to an active Agentforce session and returns the parsed trace.
     * @param sessionId Active runtime session ID.
     * @param utterance User prompt/utterance to send.
     * @return AgentTurnTrace containing response text, topic, executed actions, latency, and any error details.
     */
    public static AgentTurnTrace sendTurn(String sessionId, String utterance) {
        AgentTurnTrace trace = new AgentTurnTrace();
        if (String.isBlank(sessionId)) {
            trace.isError = true;
            trace.errorMessage = 'Session ID cannot be blank.';
            return trace;
        }

        String encodedSession = EncodingUtil.urlEncode(sessionId.trim(), 'UTF-8');
        String endpoint = NAMED_CREDENTIAL_PREFIX + '/einstein/ai-agent/v1/sessions/' + encodedSession + '/messages';

        Map<String, Object> messageObj = new Map<String, Object>{
            'sequenceId' => 1,
            'type' => 'Text',
            'text' => utterance != null ? utterance : ''
        };
        Map<String, Object> payload = new Map<String, Object>{
            'message' => messageObj
        };

        HttpRequest req = buildJsonRequest('POST', endpoint, JSON.serialize(payload));
        Long startMs = System.currentTimeMillis();
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException ex) {
            trace.latencyMs = (Integer) (System.currentTimeMillis() - startMs);
            trace.isError = true;
            trace.errorMessage = 'Callout timeout or network error: ' + ex.getMessage();
            return trace;
        }
        trace.latencyMs = (Integer) (System.currentTimeMillis() - startMs);

        Integer statusCode = res.getStatusCode();
        trace.rawTraceJson = res.getBody();

        if (statusCode == 429) {
            trace.isError = true;
            trace.errorMessage = 'Agent runtime rate limit exceeded (HTTP 429).';
            return trace;
        }
        if (statusCode >= 500) {
            trace.isError = true;
            trace.errorMessage = 'Agent runtime server error (HTTP ' + statusCode + ').';
            return trace;
        }
        if (statusCode < 200 || statusCode >= 300) {
            trace.isError = true;
            trace.errorMessage = 'Agent runtime returned HTTP ' + statusCode + ': ' + res.getStatus();
            return trace;
        }

        populateTraceFromResponse(trace, res.getBody());
        return trace;
    }

    /**
     * @description Ends an active Agentforce runtime session. Failures are handled gracefully.
     * @param sessionId Active runtime session ID.
     */
    public static void endSession(String sessionId) {
        if (String.isBlank(sessionId)) {
            return;
        }
        String encodedSession = EncodingUtil.urlEncode(sessionId.trim(), 'UTF-8');
        String endpoint = NAMED_CREDENTIAL_PREFIX + '/einstein/ai-agent/v1/sessions/' + encodedSession;

        HttpRequest req = new HttpRequest();
        req.setMethod('DELETE');
        req.setEndpoint(endpoint);
        req.setHeader('x-session-end-reason', 'UserRequest');
        req.setTimeout(DEFAULT_TIMEOUT_MS);

        try {
            new Http().send(req);
        } catch (CalloutException ex) {
            // Session cleanup is best-effort; do not fail the test run on cleanup timeout.
            System.debug(LoggingLevel.WARN, 'AgentGuardRuntimeClient.endSession warning: ' + ex.getMessage());
        }
    }

    /**
     * @description Resolves an Agentforce agent's DeveloperName to the BotDefinition Id the
     *              Agent API's /agents/{agentId}/sessions endpoint actually requires — the API
     *              404s on the developer name itself.
     */
    private static String resolveAgentId(String agentApiName) {
        List<BotDefinition> bots = [
            SELECT Id
            FROM BotDefinition
            WHERE DeveloperName = :agentApiName
            WITH USER_MODE
            LIMIT 1
        ];
        if (bots.isEmpty()) {
            throw new AgentGuardRuntimeException('No Agentforce agent found with DeveloperName: ' + agentApiName);
        }
        return bots[0].Id;
    }

    private static HttpRequest buildJsonRequest(String method, String endpoint, String body) {
        HttpRequest req = new HttpRequest();
        req.setMethod(method);
        req.setEndpoint(endpoint);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(DEFAULT_TIMEOUT_MS);
        if (body != null) {
            req.setBody(body);
        }
        return req;
    }

    private static Map<String, Object> parseJsonObject(String jsonBody) {
        if (String.isBlank(jsonBody)) {
            return new Map<String, Object>();
        }
        try {
            Object raw = JSON.deserializeUntyped(jsonBody);
            return raw instanceof Map<String, Object> ? (Map<String, Object>) raw : new Map<String, Object>();
        } catch (JSONException ex) {
            return new Map<String, Object>();
        }
    }

    private static void populateTraceFromResponse(AgentTurnTrace trace, String jsonBody) {
        Map<String, Object> root = parseJsonObject(jsonBody);
        if (root.isEmpty()) {
            trace.isError = true;
            trace.errorMessage = 'Empty or invalid JSON response from agent runtime.';
            return;
        }

        // Extract response text from standard Agent API messages array or fallback keys
        List<String> parts = new List<String>();
        List<String> citedRefs = new List<String>();

        if (root.containsKey('messages') && root.get('messages') instanceof List<Object>) {
            for (Object item : (List<Object>) root.get('messages')) {
                if (item instanceof Map<String, Object>) {
                    Map<String, Object> msg = (Map<String, Object>) item;
                    String textVal = extractMessageText(msg);
                    if (String.isNotBlank(textVal)) {
                        parts.add(textVal);
                    }
                    collectCitedReferences(msg.get('citedReferences'), citedRefs);
                }
            }
        }

        if (parts.isEmpty()) {
            String fallbackText = extractMessageText(root);
            if (String.isNotBlank(fallbackText)) {
                parts.add(fallbackText);
            } else if (root.containsKey('responseText') && root.get('responseText') != null) {
                parts.add(String.valueOf(root.get('responseText')));
            }
        }

        collectCitedReferences(root.get('citedReferences'), citedRefs);
        if (!citedRefs.isEmpty()) {
            parts.add('Cited References: ' + String.join(citedRefs, ', '));
        }

        if (!parts.isEmpty()) {
            trace.responseText = String.join(parts, '\n');
        }

        // Extract topic & actions from trace object or top-level keys
        Map<String, Object> traceNode = root.get('trace') instanceof Map<String, Object>
            ? (Map<String, Object>) root.get('trace')
            : root;

        if (traceNode.containsKey('actualTopic')) {
            trace.actualTopic = String.valueOf(traceNode.get('actualTopic'));
        } else if (traceNode.containsKey('topic')) {
            trace.actualTopic = String.valueOf(traceNode.get('topic'));
        }

        Object actionsObj = traceNode.containsKey('executedActions')
            ? traceNode.get('executedActions')
            : traceNode.get('actions');
        if (actionsObj instanceof List<Object>) {
            for (Object act : (List<Object>) actionsObj) {
                if (act instanceof String) {
                    trace.executedActions.add((String) act);
                } else if (act instanceof Map<String, Object>) {
                    Map<String, Object> actMap = (Map<String, Object>) act;
                    Object nameVal = actMap.containsKey('name') ? actMap.get('name') : actMap.get('actionName');
                    if (nameVal != null) {
                        trace.executedActions.add(String.valueOf(nameVal));
                    }
                }
            }
        }
    }

    private static String extractMessageText(Map<String, Object> node) {
        if (node == null) {
            return null;
        }
        if (node.get('message') != null) {
            return String.valueOf(node.get('message'));
        }
        if (node.get('text') != null) {
            return String.valueOf(node.get('text'));
        }
        Object resultObj = node.get('result');
        if (resultObj instanceof String) {
            return (String) resultObj;
        }
        if (resultObj instanceof Map<String, Object>) {
            Map<String, Object> resultMap = (Map<String, Object>) resultObj;
            if (resultMap.get('message') != null) {
                return String.valueOf(resultMap.get('message'));
            }
            if (resultMap.get('text') != null) {
                return String.valueOf(resultMap.get('text'));
            }
            return JSON.serialize(resultMap);
        }
        if (resultObj instanceof List<Object>) {
            return JSON.serialize(resultObj);
        }
        return null;
    }

    private static void collectCitedReferences(Object refsObj, List<String> citedRefs) {
        if (!(refsObj instanceof List<Object>)) {
            return;
        }
        for (Object ref : (List<Object>) refsObj) {
            if (ref instanceof String && String.isNotBlank((String) ref)) {
                citedRefs.add((String) ref);
            } else if (ref instanceof Map<String, Object>) {
                Map<String, Object> refMap = (Map<String, Object>) ref;
                Object label = refMap.containsKey('url')
                    ? refMap.get('url')
                    : (refMap.containsKey('label') ? refMap.get('label') : refMap.get('title'));
                if (label != null && String.isNotBlank(String.valueOf(label))) {
                    citedRefs.add(String.valueOf(label));
                }
            }
        }
    }
}
