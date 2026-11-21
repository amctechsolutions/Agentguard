import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSuites from '@salesforce/apex/AgentGuardDashboardController.getSuites';
import getRunsForSuite from '@salesforce/apex/AgentGuardDashboardController.getRunsForSuite';
import getResultsForRun from '@salesforce/apex/AgentGuardDashboardController.getResultsForRun';
import triggerSuiteRun from '@salesforce/apex/AgentGuardDashboardController.triggerSuiteRun';
import importRedTeamTemplates from '@salesforce/apex/AgentGuardDashboardController.importRedTeamTemplates';

const POLL_INTERVAL_MS = 3000;
const ACTIVE_STATUSES = new Set(['Queued', 'Running']);

const RESULT_COLUMNS = [
    { label: 'Utterance', fieldName: 'utterance', type: 'text', wrapText: true },
    { label: 'Expected Topic', fieldName: 'expectedTopic', type: 'text' },
    { label: 'Actual Topic', fieldName: 'actualTopic', type: 'text' },
    {
        label: 'Regression',
        fieldName: 'regressionLabel',
        type: 'text',
        initialWidth: 130,
        cellAttributes: {
            class: { fieldName: 'regressionCellClass' },
            iconName: { fieldName: 'regressionIcon' },
            iconAlternativeText: 'Regression status'
        }
    },
    { label: 'Deterministic', fieldName: 'deterministicLabel', type: 'text', initialWidth: 130 },
    { label: 'LLM Judge', fieldName: 'llmJudgeLabel', type: 'text', initialWidth: 120 },
    { label: 'Failure Reason', fieldName: 'failureReason', type: 'text', wrapText: true },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [{ label: 'Inspect', name: 'inspect' }]
        }
    }
];

export default class AgentGuardDashboard extends LightningElement {
    @track suites = [];
    @track runs = [];
    @track results = [];

    selectedSuiteId = '';
    selectedResult = null;
    showCsvLoader = false;
    isLoading = false;
    isActionPending = false;

    pollIntervalId = null;
    isPollInFlight = false;

    columns = RESULT_COLUMNS;

    connectedCallback() {
        this.loadSuites();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    get suiteOptions() {
        return this.suites.map((suite) => ({
            label: suite.Name,
            value: suite.Id
        }));
    }

    get hasSuiteSelected() {
        return Boolean(this.selectedSuiteId);
    }

    get selectedSuite() {
        return this.suites.find((suite) => suite.Id === this.selectedSuiteId) || null;
    }

    get creditCapLabel() {
        if (!this.selectedSuite) {
            return '';
        }
        const maxTurns = this.selectedSuite.Max_Turns_Per_Run__c;
        if (maxTurns !== undefined && maxTurns !== null && maxTurns > 0) {
            return `Credit Cap: ${maxTurns} max turns`;
        }
        return 'Credit Cap: Unlimited';
    }

    get isControlsDisabled() {
        return !this.hasSuiteSelected || this.isActionPending;
    }

    get isRunButtonDisabled() {
        return this.isControlsDisabled || this.isPollingActive;
    }

    get csvButtonVariant() {
        return this.showCsvLoader ? 'brand' : 'neutral';
    }

    get latestRun() {
        return this.runs.length > 0 ? this.runs[0] : null;
    }

    get isPollingActive() {
        return Boolean(this.latestRun && ACTIVE_STATUSES.has(this.latestRun.Status__c));
    }

    get latestRunStatus() {
        return this.latestRun?.Status__c || 'No Runs';
    }

    get latestRunStatusBadgeClass() {
        const status = this.latestRunStatus;
        if (status === 'Passed') {
            return 'slds-theme_success';
        }
        if (status === 'Failed' || status === 'Error') {
            return 'slds-theme_error';
        }
        if (status === 'Running' || status === 'Queued') {
            return 'slds-theme_warning';
        }
        return '';
    }

    get totalTests() {
        return this.latestRun?.Total_Tests__c ?? 0;
    }

    get failedTests() {
        if (!this.latestRun) {
            return 0;
        }
        const total = this.latestRun.Total_Tests__c ?? 0;
        const passed = this.latestRun.Passed_Tests__c ?? 0;
        return Math.max(0, total - passed);
    }

    get regressionCount() {
        return this.latestRun?.Regression_Count__c ?? 0;
    }

    get hasRegressions() {
        return this.regressionCount > 0;
    }

    get regressionCardClass() {
        return this.hasRegressions
            ? 'slds-box slds-theme_error kpi-card'
            : 'slds-box slds-theme_default kpi-card';
    }

    get regressionLabelClass() {
        return this.hasRegressions
            ? 'slds-text-title_caps slds-m-bottom_xx-small'
            : 'slds-text-title_caps slds-text-color_weak slds-m-bottom_xx-small';
    }

    get formattedPassRate() {
        if (!this.latestRun) {
            return '—';
        }
        if (this.latestRun.Pass_Rate__c !== undefined && this.latestRun.Pass_Rate__c !== null) {
            return `${Number(this.latestRun.Pass_Rate__c).toFixed(1)}%`;
        }
        const total = this.latestRun.Total_Tests__c ?? 0;
        if (total === 0) {
            return '0.0%';
        }
        const passed = this.latestRun.Passed_Tests__c ?? 0;
        return `${((passed / total) * 100).toFixed(1)}%`;
    }

    get hasResults() {
        return this.results.length > 0;
    }

    get isInspectorOpen() {
        return Boolean(this.selectedResult);
    }

    async loadSuites() {
        this.isLoading = true;
        try {
            const data = await getSuites();
            this.suites = data || [];
            if (this.suites.length > 0 && !this.selectedSuiteId) {
                this.selectedSuiteId = this.suites[0].Id;
                await this.loadRunsAndResults();
            }
        } catch (err) {
            this.showToast('Error Loading Suites', this.extractErrorMessage(err), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async loadRunsAndResults() {
        if (!this.selectedSuiteId) {
            this.runs = [];
            this.results = [];
            this.stopPolling();
            return;
        }

        try {
            const runList = await getRunsForSuite({ suiteId: this.selectedSuiteId });
            this.runs = runList || [];

            if (this.runs.length > 0) {
                const latest = this.runs[0];
                const rawResults = await getResultsForRun({ runId: latest.Id });
                this.results = this.mapResults(rawResults || []);

                if (ACTIVE_STATUSES.has(latest.Status__c)) {
                    this.startPolling();
                } else {
                    this.stopPolling();
                }
            } else {
                this.results = [];
                this.stopPolling();
            }
        } catch (err) {
            this.stopPolling();
            this.showToast('Error Loading Run Data', this.extractErrorMessage(err), 'error');
        }
    }

    mapResults(rawResults) {
        return rawResults.map((r) => {
            let llmJudgeLabel = 'N/A';
            if (r.LLM_Judge_Pass__c !== undefined && r.LLM_Judge_Pass__c !== null) {
                llmJudgeLabel = r.LLM_Judge_Pass__c ? 'Pass' : 'Fail';
            }
            const isRegression = Boolean(r.Regression_Detected__c);
            return {
                Id: r.Id,
                utterance: r.Test_Case__r?.Utterance__c || '',
                expectedTopic: r.Test_Case__r?.Expected_Topic__c || '',
                actualTopic: r.Actual_Topic__c || '',
                regressionDetected: isRegression,
                regressionLabel: isRegression ? 'Regression' : '—',
                regressionCellClass: isRegression
                    ? 'slds-text-color_error slds-text-title_bold'
                    : 'slds-text-color_weak',
                regressionIcon: isRegression ? 'utility:warning' : '',
                deterministicLabel: r.Deterministic_Pass__c ? 'Pass' : 'Fail',
                llmJudgeLabel,
                failureReason: r.Failure_Reason__c || '',
                rawRecord: r
            };
        });
    }

    startPolling() {
        if (this.pollIntervalId !== null) {
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollIntervalId = setInterval(() => {
            this.pollLatestRun();
        }, POLL_INTERVAL_MS);
    }

    stopPolling() {
        if (this.pollIntervalId !== null) {
            clearInterval(this.pollIntervalId);
            this.pollIntervalId = null;
        }
    }

    async pollLatestRun() {
        if (this.isPollInFlight || !this.selectedSuiteId) {
            return;
        }
        this.isPollInFlight = true;
        try {
            await this.loadRunsAndResults();
        } finally {
            this.isPollInFlight = false;
        }
    }

    async handleSuiteChange(event) {
        this.selectedSuiteId = event.detail.value;
        this.selectedResult = null;
        this.stopPolling();
        this.isLoading = true;
        try {
            await this.loadRunsAndResults();
        } finally {
            this.isLoading = false;
        }
    }

    async handleRunSuite() {
        if (!this.selectedSuiteId) {
            return;
        }
        this.isActionPending = true;
        try {
            await triggerSuiteRun({ suiteId: this.selectedSuiteId });
            this.showToast('Test Run Queued', 'Suite execution has been started.', 'success');
            await this.loadRunsAndResults();
        } catch (err) {
            this.showToast('Failed to Start Run', this.extractErrorMessage(err), 'error');
        } finally {
            this.isActionPending = false;
        }
    }

    async handleImportRedTeam() {
        if (!this.selectedSuiteId) {
            return;
        }
        this.isActionPending = true;
        try {
            await importRedTeamTemplates({ suiteId: this.selectedSuiteId });
            this.showToast(
                'Red-Team Tests Imported',
                '25 Red-Team adversarial test cases were added to the suite.',
                'success'
            );
        } catch (err) {
            this.showToast('Import Failed', this.extractErrorMessage(err), 'error');
        } finally {
            this.isActionPending = false;
        }
    }

    handleToggleCsvLoader() {
        this.showCsvLoader = !this.showCsvLoader;
    }

    handleCloseCsvLoader() {
        this.showCsvLoader = false;
    }

    handleCsvImportSuccess() {
        this.showCsvLoader = false;
    }

    handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;
        if (actionName === 'inspect' && row) {
            this.selectedResult = row.rawRecord || row;
        }
    }

    handleCloseInspector() {
        this.selectedResult = null;
    }

    extractErrorMessage(err) {
        return err?.body?.message || err?.message || 'An unexpected error occurred.';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }
}
