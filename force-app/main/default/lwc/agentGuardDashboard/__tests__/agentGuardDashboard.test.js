import { createElement } from 'lwc';
import AgentGuardDashboard from 'c/agentGuardDashboard';
import getSuites from '@salesforce/apex/AgentGuardDashboardController.getSuites';
import getRunsForSuite from '@salesforce/apex/AgentGuardDashboardController.getRunsForSuite';
import getResultsForRun from '@salesforce/apex/AgentGuardDashboardController.getResultsForRun';
import triggerSuiteRun from '@salesforce/apex/AgentGuardDashboardController.triggerSuiteRun';
import importRedTeamTemplates from '@salesforce/apex/AgentGuardDashboardController.importRedTeamTemplates';

jest.mock(
    '@salesforce/apex/AgentGuardDashboardController.getSuites',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGuardDashboardController.getRunsForSuite',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGuardDashboardController.getResultsForRun',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGuardDashboardController.triggerSuiteRun',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/AgentGuardDashboardController.importRedTeamTemplates',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const MOCK_SUITES = [
    { Id: 'suite-1', Name: 'Core Support Agent Suite', Max_Turns_Per_Run__c: 50 },
    { Id: 'suite-2', Name: 'Sales Concierge Suite', Max_Turns_Per_Run__c: null }
];

const MOCK_RUN_PASSED = [
    {
        Id: 'run-1',
        Name: 'RUN-0001',
        Status__c: 'Passed',
        Total_Tests__c: 10,
        Passed_Tests__c: 9,
        Pass_Rate__c: 90.0,
        Regression_Count__c: 0
    }
];

const MOCK_RESULTS = [
    {
        Id: 'res-1',
        Actual_Topic__c: 'Order_Status',
        Actual_Actions_JSON__c: '[]',
        Agent_Response__c: 'Order is on the way.',
        Deterministic_Pass__c: true,
        LLM_Judge_Pass__c: true,
        Regression_Detected__c: false,
        Failure_Reason__c: null,
        Test_Case__r: {
            Utterance__c: 'Where is my order?',
            Expected_Topic__c: 'Order_Status'
        }
    }
];

const flushPromises = () => Promise.resolve().then(() => Promise.resolve());

describe('c-agent-guard-dashboard', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('loads suites, KPIs, and results on initialization', async () => {
        getSuites.mockResolvedValue(MOCK_SUITES);
        getRunsForSuite.mockResolvedValue(MOCK_RUN_PASSED);
        getResultsForRun.mockResolvedValue(MOCK_RESULTS);

        const element = createElement('c-agent-guard-dashboard', {
            is: AgentGuardDashboard
        });
        document.body.appendChild(element);

        await flushPromises();
        await flushPromises();

        const statusBadge = element.shadowRoot.querySelector('[data-id="kpi-status-badge"]');
        const passRate = element.shadowRoot.querySelector('[data-id="kpi-pass-rate-value"]');
        const totalTests = element.shadowRoot.querySelector('[data-id="kpi-total-tests-value"]');
        const failedTests = element.shadowRoot.querySelector('[data-id="kpi-failed-tests-value"]');
        const regressionsCard = element.shadowRoot.querySelector('[data-id="kpi-regressions-card"]');
        const regressionsValue = element.shadowRoot.querySelector('[data-id="kpi-regressions-value"]');
        const creditCapBadge = element.shadowRoot.querySelector('[data-id="credit-cap-badge"]');
        const datatable = element.shadowRoot.querySelector('[data-id="results-datatable"]');

        expect(statusBadge.label).toBe('Passed');
        expect(passRate.textContent).toBe('90.0%');
        expect(totalTests.textContent).toBe('10');
        expect(failedTests.textContent).toBe('1');
        expect(regressionsValue.textContent).toBe('0');
        expect(regressionsCard.className).toContain('slds-theme_default');
        expect(creditCapBadge).not.toBeNull();
        expect(creditCapBadge.label).toBe('Credit Cap: 50 max turns');
        expect(datatable).not.toBeNull();
        expect(datatable.data).toHaveLength(1);
        expect(datatable.data[0].utterance).toBe('Where is my order?');
        expect(datatable.data[0].regressionLabel).toBe('—');
        expect(datatable.columns.some((col) => col.fieldName === 'regressionLabel')).toBe(true);
    });

    it('triggers suite run, polls every 3s while Running, and stops polling when Passed', async () => {
        jest.useFakeTimers();

        getSuites.mockResolvedValue(MOCK_SUITES);
        getRunsForSuite
            .mockResolvedValueOnce(MOCK_RUN_PASSED)
            .mockResolvedValueOnce([
                { Id: 'run-2', Status__c: 'Running', Total_Tests__c: 10, Passed_Tests__c: 0, Pass_Rate__c: 0 }
            ])
            .mockResolvedValueOnce([
                { Id: 'run-2', Status__c: 'Passed', Total_Tests__c: 10, Passed_Tests__c: 10, Pass_Rate__c: 100 }
            ]);
        getResultsForRun.mockResolvedValue(MOCK_RESULTS);
        triggerSuiteRun.mockResolvedValue('run-2');

        const element = createElement('c-agent-guard-dashboard', {
            is: AgentGuardDashboard
        });
        document.body.appendChild(element);

        await flushPromises();
        await flushPromises();

        const runBtn = element.shadowRoot.querySelector('[data-id="run-suite-button"]');
        runBtn.click();

        await flushPromises();
        await flushPromises();

        expect(triggerSuiteRun).toHaveBeenCalledWith({ suiteId: 'suite-1' });
        let statusBadge = element.shadowRoot.querySelector('[data-id="kpi-status-badge"]');
        expect(statusBadge.label).toBe('Running');

        jest.advanceTimersByTime(3000);
        await flushPromises();
        await flushPromises();

        statusBadge = element.shadowRoot.querySelector('[data-id="kpi-status-badge"]');
        expect(statusBadge.label).toBe('Passed');
        expect(getRunsForSuite).toHaveBeenCalledTimes(3);

        // Advancing another 3s should NOT poll again because status is Passed
        jest.advanceTimersByTime(3000);
        await flushPromises();
        expect(getRunsForSuite).toHaveBeenCalledTimes(3);
    });

    it('imports 25 red-team templates and toggles CSV loader', async () => {
        getSuites.mockResolvedValue(MOCK_SUITES);
        getRunsForSuite.mockResolvedValue(MOCK_RUN_PASSED);
        getResultsForRun.mockResolvedValue(MOCK_RESULTS);
        importRedTeamTemplates.mockResolvedValue(25);

        const element = createElement('c-agent-guard-dashboard', {
            is: AgentGuardDashboard
        });
        document.body.appendChild(element);

        await flushPromises();
        await flushPromises();

        const importBtn = element.shadowRoot.querySelector('[data-id="import-redteam-button"]');
        importBtn.click();
        await flushPromises();

        expect(importRedTeamTemplates).toHaveBeenCalledWith({ suiteId: 'suite-1' });

        expect(element.shadowRoot.querySelector('[data-id="csv-loader"]')).toBeNull();
        const toggleCsvBtn = element.shadowRoot.querySelector('[data-id="toggle-csv-button"]');
        toggleCsvBtn.click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[data-id="csv-loader"]')).not.toBeNull();
    });

    it('opens result inspector when Inspect row action is triggered', async () => {
        getSuites.mockResolvedValue(MOCK_SUITES);
        getRunsForSuite.mockResolvedValue(MOCK_RUN_PASSED);
        getResultsForRun.mockResolvedValue(MOCK_RESULTS);

        const element = createElement('c-agent-guard-dashboard', {
            is: AgentGuardDashboard
        });
        document.body.appendChild(element);

        await flushPromises();
        await flushPromises();

        const datatable = element.shadowRoot.querySelector('[data-id="results-datatable"]');
        datatable.dispatchEvent(
            new CustomEvent('rowaction', {
                detail: {
                    action: { name: 'inspect' },
                    row: datatable.data[0]
                }
            })
        );

        await flushPromises();

        const inspector = element.shadowRoot.querySelector('[data-id="result-inspector"]');
        expect(inspector).not.toBeNull();
        expect(inspector.result.Id).toBe('res-1');

        inspector.dispatchEvent(new CustomEvent('close'));
        await flushPromises();

        expect(element.shadowRoot.querySelector('[data-id="result-inspector"]')).toBeNull();
    });

    it('highlights regressions KPI card, flags regression rows, and updates credit cap on suite change', async () => {
        getSuites.mockResolvedValue(MOCK_SUITES);
        getRunsForSuite
            .mockResolvedValueOnce([
                {
                    Id: 'run-reg',
                    Name: 'RUN-0002',
                    Status__c: 'Failed',
                    Total_Tests__c: 5,
                    Passed_Tests__c: 3,
                    Pass_Rate__c: 60.0,
                    Regression_Count__c: 2
                }
            ])
            .mockResolvedValueOnce([]);
        getResultsForRun.mockResolvedValue([
            {
                Id: 'res-reg-1',
                Actual_Topic__c: 'General_FAQ',
                Previous_Topic__c: 'Order_Status',
                Regression_Detected__c: true,
                Deterministic_Pass__c: false,
                LLM_Judge_Pass__c: false,
                Failure_Reason__c: 'Topic drifted from Order_Status to General_FAQ',
                Test_Case__r: {
                    Utterance__c: 'Track my package',
                    Expected_Topic__c: 'Order_Status'
                }
            }
        ]);

        const element = createElement('c-agent-guard-dashboard', {
            is: AgentGuardDashboard
        });
        document.body.appendChild(element);

        await flushPromises();
        await flushPromises();

        const regressionsCard = element.shadowRoot.querySelector('[data-id="kpi-regressions-card"]');
        const regressionsValue = element.shadowRoot.querySelector('[data-id="kpi-regressions-value"]');
        const datatable = element.shadowRoot.querySelector('[data-id="results-datatable"]');

        expect(regressionsValue.textContent).toBe('2');
        expect(regressionsCard.className).toContain('slds-theme_error');
        expect(datatable.data[0].regressionLabel).toBe('Regression');
        expect(datatable.data[0].regressionIcon).toBe('utility:warning');
        expect(datatable.data[0].regressionCellClass).toContain('slds-text-color_error');

        const suiteCombobox = element.shadowRoot.querySelector('[data-id="suite-combobox"]');
        suiteCombobox.dispatchEvent(
            new CustomEvent('change', {
                detail: { value: 'suite-2' }
            })
        );

        await flushPromises();
        await flushPromises();

        const creditCapBadge = element.shadowRoot.querySelector('[data-id="credit-cap-badge"]');
        expect(creditCapBadge.label).toBe('Credit Cap: Unlimited');
    });
});
