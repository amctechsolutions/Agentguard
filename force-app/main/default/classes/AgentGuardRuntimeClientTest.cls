@isTest
public with sharing class AgentGuardRuntimeClientTest {
    private class RuntimeMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        private Boolean throwTimeout;
        public HttpRequest lastRequest;

        public RuntimeMock(Integer statusCode, String body, Boolean throwTimeout) {
            this.statusCode = statusCode;
            this.body = body;
            this.throwTimeout = throwTimeout;
        }

        public HttpResponse respond(HttpRequest req) {
            this.lastRequest = req;
            if (throwTimeout == true) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setStatus(statusCode == 200 ? 'OK' : 'Error');
            res.setBody(body);
            return res;
        }
    }

    @isTest
    static void testStartSessionSuccess() {
        RuntimeMock mock = new RuntimeMock(200, '{"sessionId":"sess-123"}', false);
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        String sessionId = AgentGuardRuntimeClient.startSession('Support_Agent');
        Test.stopTest();
        Assert.areEqual('sess-123', sessionId, 'Expected parsed sessionId');

        Map<String, Object> sentPayload = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.isTrue(sentPayload.containsKey('instanceConfig'), 'Payload must include instanceConfig');
        Map<String, Object> instCfg = (Map<String, Object>) sentPayload.get('instanceConfig');
        Assert.areEqual(URL.getOrgDomainUrl().toExternalForm(), instCfg.get('endpoint'));
    }

    @isTest
    static void testStartSessionErrors() {
        Boolean threwBlank = false;
        try {
            AgentGuardRuntimeClient.startSession('');
        } catch (AgentGuardRuntimeClient.AgentGuardRuntimeException ex) {
            threwBlank = true;
        }
        Assert.isTrue(threwBlank, 'Blank agent name should throw');

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(429, '{"error":"rate limit"}', false));
        Boolean threw429 = false;
        try {
            AgentGuardRuntimeClient.startSession('Support_Agent');
        } catch (AgentGuardRuntimeClient.AgentGuardRuntimeException ex) {
            threw429 = ex.getMessage().contains('429');
        }
        Assert.isTrue(threw429, '429 should throw rate limit exception');

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(500, 'Server Error', false));
        Boolean threw500 = false;
        try {
            AgentGuardRuntimeClient.startSession('Support_Agent');
        } catch (AgentGuardRuntimeClient.AgentGuardRuntimeException ex) {
            threw500 = ex.getMessage().contains('500');
        }
        Assert.isTrue(threw500, '500 should throw server error');

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(200, '{"noSession":true}', false));
        Boolean threwMissing = false;
        try {
            AgentGuardRuntimeClient.startSession('Support_Agent');
        } catch (AgentGuardRuntimeClient.AgentGuardRuntimeException ex) {
            threwMissing = true;
        }
        Assert.isTrue(threwMissing, 'Missing sessionId should throw');

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(200, '', true));
        Boolean threwTimeout = false;
        try {
            AgentGuardRuntimeClient.startSession('Support_Agent');
        } catch (AgentGuardRuntimeClient.AgentGuardRuntimeException ex) {
            threwTimeout = true;
        }
        Assert.isTrue(threwTimeout, 'Timeout should throw');
    }

    @isTest
    static void testSendTurnSuccess() {
        String payload = '{"messages":[{"message":"Your order is shipped."}],"trace":{"topic":"Order_Status","actions":[{"name":"Get_Order_Status"},"Verify_Identity"]}}';
        Test.setMock(HttpCalloutMock.class, new RuntimeMock(200, payload, false));

        Test.startTest();
        AgentGuardRuntimeClient.AgentTurnTrace trace = AgentGuardRuntimeClient.sendTurn('sess-123', 'Where is my order?');
        Test.stopTest();

        Assert.isFalse(trace.isError, 'Should not be error');
        Assert.areEqual('Order_Status', trace.actualTopic);
        Assert.areEqual(2, trace.executedActions.size());
        Assert.areEqual('Get_Order_Status', trace.executedActions[0]);
        Assert.areEqual('Your order is shipped.', trace.responseText);
        Assert.areEqual(payload, trace.rawTraceJson);

        // Verify fallback extraction for message, result, and citedReferences
        String refPayload = '{"message":"Top-level response","citedReferences":[{"url":"https://help.salesforce.com/kb1"}]}';
        Test.setMock(HttpCalloutMock.class, new RuntimeMock(200, refPayload, false));
        AgentGuardRuntimeClient.AgentTurnTrace refTrace = AgentGuardRuntimeClient.sendTurn('sess-123', 'Help');
        Assert.isTrue(refTrace.responseText.contains('Top-level response'));
        Assert.isTrue(refTrace.responseText.contains('https://help.salesforce.com/kb1'));

        String resultPayload = '{"result":{"text":"Result text payload"}}';
        Test.setMock(HttpCalloutMock.class, new RuntimeMock(200, resultPayload, false));
        AgentGuardRuntimeClient.AgentTurnTrace resultTrace = AgentGuardRuntimeClient.sendTurn('sess-123', 'Status');
        Assert.areEqual('Result text payload', resultTrace.responseText);
    }

    @isTest
    static void testSendTurnErrorsAndTimeouts() {
        AgentGuardRuntimeClient.AgentTurnTrace blankTrace = AgentGuardRuntimeClient.sendTurn('', 'Hi');
        Assert.isTrue(blankTrace.isError, 'Blank sessionId should return error trace');

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(429, '', false));
        AgentGuardRuntimeClient.AgentTurnTrace rateTrace = AgentGuardRuntimeClient.sendTurn('sess-1', 'Hi');
        Assert.isTrue(rateTrace.isError && rateTrace.errorMessage.contains('429'));

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(503, '', false));
        AgentGuardRuntimeClient.AgentTurnTrace serverTrace = AgentGuardRuntimeClient.sendTurn('sess-1', 'Hi');
        Assert.isTrue(serverTrace.isError && serverTrace.errorMessage.contains('503'));

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(400, 'Bad Request', false));
        AgentGuardRuntimeClient.AgentTurnTrace clientTrace = AgentGuardRuntimeClient.sendTurn('sess-1', 'Hi');
        Assert.isTrue(clientTrace.isError && clientTrace.errorMessage.contains('400'));

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(200, 'not-json', false));
        AgentGuardRuntimeClient.AgentTurnTrace badJsonTrace = AgentGuardRuntimeClient.sendTurn('sess-1', 'Hi');
        Assert.isTrue(badJsonTrace.isError);

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(200, '', true));
        AgentGuardRuntimeClient.AgentTurnTrace timeoutTrace = AgentGuardRuntimeClient.sendTurn('sess-1', 'Hi');
        Assert.isTrue(timeoutTrace.isError && timeoutTrace.errorMessage.contains('timeout'));
    }

    @isTest
    static void testEndSession() {
        AgentGuardRuntimeClient.endSession('');
        RuntimeMock mock = new RuntimeMock(204, '', false);
        Test.setMock(HttpCalloutMock.class, mock);
        AgentGuardRuntimeClient.endSession('sess-123');
        Assert.areEqual('DELETE', mock.lastRequest.getMethod());
        Assert.areEqual('UserRequest', mock.lastRequest.getHeader('x-session-end-reason'));

        Test.setMock(HttpCalloutMock.class, new RuntimeMock(204, '', true));
        AgentGuardRuntimeClient.endSession('sess-123');
        Assert.isTrue(true, 'endSession should handle exceptions gracefully');
    }
}
