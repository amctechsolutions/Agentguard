import { LightningElement, api } from 'lwc';

export default class AgentGuardResultInspector extends LightningElement {
    @api result;

    get hasResult() {
        return Boolean(this.result);
    }

    get testCaseName() {
        return this.result?.Test_Case__r?.Name || this.result?.Name || 'Test Result';
    }

    get category() {
        return this.result?.Test_Case__r?.Category__c || '';
    }

    get utterance() {
        return this.result?.Test_Case__r?.Utterance__c || '—';
    }

    get expectedTopic() {
        return this.result?.Test_Case__r?.Expected_Topic__c || '—';
    }

    get actualTopic() {
        return this.result?.Actual_Topic__c || '—';
    }

    get expectedAction() {
        return this.result?.Test_Case__r?.Expected_Action__c || '—';
    }

    get forbiddenAction() {
        return this.result?.Test_Case__r?.Forbidden_Action__c || '—';
    }

    get formattedActionsJson() {
        const raw = this.result?.Actual_Actions_JSON__c;
        if (!raw) {
            return '[]';
        }
        try {
            const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
            return JSON.stringify(parsed, null, 2);
        } catch {
            return String(raw);
        }
    }

    get agentResponse() {
        return this.result?.Agent_Response__c || '—';
    }

    get isDeterministicPass() {
        return Boolean(this.result?.Deterministic_Pass__c);
    }

    get deterministicBadgeLabel() {
        return this.isDeterministicPass ? 'Deterministic: Pass' : 'Deterministic: Fail';
    }

    get deterministicBadgeClass() {
        return this.isDeterministicPass
            ? 'slds-theme_success slds-m-right_x-small'
            : 'slds-theme_error slds-m-right_x-small';
    }

    get hasLlmJudgeValue() {
        return (
            this.result?.LLM_Judge_Pass__c !== undefined &&
            this.result?.LLM_Judge_Pass__c !== null
        );
    }

    get llmJudgeBadgeLabel() {
        if (!this.hasLlmJudgeValue) {
            return 'LLM Judge: N/A';
        }
        return this.result.LLM_Judge_Pass__c ? 'LLM Judge: Pass' : 'LLM Judge: Fail';
    }

    get llmJudgeBadgeClass() {
        if (!this.hasLlmJudgeValue) {
            return 'slds-m-right_x-small';
        }
        return this.result.LLM_Judge_Pass__c
            ? 'slds-theme_success slds-m-right_x-small'
            : 'slds-theme_error slds-m-right_x-small';
    }

    get hasLatency() {
        return (
            this.result?.Latency_Ms__c !== undefined &&
            this.result?.Latency_Ms__c !== null
        );
    }

    get latencyLabel() {
        return `Latency: ${this.result.Latency_Ms__c} ms`;
    }

    get hasFailureReason() {
        return Boolean(this.result?.Failure_Reason__c);
    }

    get failureReason() {
        return this.result?.Failure_Reason__c || '';
    }

    get isRegressionDetected() {
        return Boolean(this.result?.Regression_Detected__c);
    }

    get hasPreviousTopic() {
        return Boolean(this.result?.Previous_Topic__c);
    }

    get showVersionDiff() {
        return this.isRegressionDetected || this.hasPreviousTopic;
    }

    get previousTopic() {
        return this.result?.Previous_Topic__c || '—';
    }

    get versionDiffTitle() {
        return this.isRegressionDetected
            ? 'Version-Diff Regression Detected'
            : 'Version-Diff Comparison';
    }

    get versionDiffBannerClass() {
        return this.isRegressionDetected
            ? 'slds-box slds-theme_warning slds-m-bottom_medium'
            : 'slds-box slds-theme_shade slds-m-bottom_medium';
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
