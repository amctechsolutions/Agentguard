import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import importCsvTestCases from '@salesforce/apex/AgentGuardDashboardController.importCsvTestCases';

const REQUIRED_HEADERS = [
    'Utterance',
    'ExpectedTopic',
    'ExpectedAction',
    'ForbiddenAction',
    'ForbiddenRegex',
    'Category'
];

const PREVIEW_COLUMNS = [
    { label: 'Utterance', fieldName: 'Utterance', type: 'text', wrapText: true },
    { label: 'Expected Topic', fieldName: 'ExpectedTopic', type: 'text' },
    { label: 'Expected Action', fieldName: 'ExpectedAction', type: 'text' },
    { label: 'Forbidden Action', fieldName: 'ForbiddenAction', type: 'text' },
    { label: 'Forbidden Regex', fieldName: 'ForbiddenRegex', type: 'text' },
    { label: 'Category', fieldName: 'Category', type: 'text' }
];

export function parseCsvLine(line) {
    const fields = [];
    let current = '';
    let inQuotes = false;

    for (let i = 0; i < line.length; i++) {
        const char = line[i];
        if (inQuotes) {
            if (char === '"') {
                if (i + 1 < line.length && line[i + 1] === '"') {
                    current += '"';
                    i++;
                } else {
                    inQuotes = false;
                }
            } else {
                current += char;
            }
        } else if (char === '"') {
            inQuotes = true;
        } else if (char === ',') {
            fields.push(current.trim());
            current = '';
        } else {
            current += char;
        }
    }
    fields.push(current.trim());
    return fields;
}

export function parseCsvContent(csvText) {
    if (!csvText || !csvText.trim()) {
        return { error: 'CSV content is empty.', rows: [] };
    }

    const lines = csvText
        .replace(/^\uFEFF/, '')
        .split(/\r?\n/)
        .filter((line) => line.trim().length > 0);

    if (lines.length < 2) {
        return {
            error: 'CSV must include a header row and at least one data row.',
            rows: []
        };
    }

    const headers = parseCsvLine(lines[0]);
    const missingHeaders = REQUIRED_HEADERS.filter((req) => !headers.includes(req));
    if (missingHeaders.length > 0) {
        return {
            error: `Missing required CSV headers: ${missingHeaders.join(', ')}.`,
            rows: []
        };
    }

    const headerIndexMap = {};
    REQUIRED_HEADERS.forEach((h) => {
        headerIndexMap[h] = headers.indexOf(h);
    });

    const rows = [];
    for (let i = 1; i < lines.length; i++) {
        const values = parseCsvLine(lines[i]);
        const row = {
            rowKey: `csv-row-${i}`,
            Utterance: values[headerIndexMap.Utterance] || '',
            ExpectedTopic: values[headerIndexMap.ExpectedTopic] || '',
            ExpectedAction: values[headerIndexMap.ExpectedAction] || '',
            ForbiddenAction: values[headerIndexMap.ForbiddenAction] || '',
            ForbiddenRegex: values[headerIndexMap.ForbiddenRegex] || '',
            Category: values[headerIndexMap.Category] || ''
        };

        if (!row.Utterance) {
            return {
                error: `Row ${i} is missing a required Utterance value.`,
                rows: []
            };
        }
        rows.push(row);
    }

    return { error: null, rows };
}

export default class AgentGuardCsvLoader extends LightningElement {
    @api suiteId;

    @track parsedRows = [];
    fileName = '';
    errorMessage = '';
    isImporting = false;

    previewColumns = PREVIEW_COLUMNS;

    get hasParsedRows() {
        return this.parsedRows.length > 0;
    }

    get isImportDisabled() {
        return !this.suiteId || !this.hasParsedRows || Boolean(this.errorMessage) || this.isImporting;
    }

    get requiredHeadersLabel() {
        return REQUIRED_HEADERS.join(', ');
    }

    get parsedCountLabel() {
        return `${this.parsedRows.length} test case(s) ready to import`;
    }

    handleFileChange(event) {
        const files = event.target.files;
        if (!files || files.length === 0) {
            return;
        }
        const file = files[0];
        this.fileName = file.name;
        this.errorMessage = '';
        this.parsedRows = [];

        const reader = new FileReader();
        reader.onload = () => {
            this.processCsvText(reader.result);
        };
        reader.onerror = () => {
            this.errorMessage = 'Failed to read the selected CSV file.';
        };
        reader.readAsText(file);
    }

    processCsvText(csvText) {
        const { error, rows } = parseCsvContent(csvText);
        if (error) {
            this.errorMessage = error;
            this.parsedRows = [];
            return;
        }
        this.errorMessage = '';
        this.parsedRows = rows;
    }

    async handleImport() {
        if (this.isImportDisabled) {
            return;
        }
        this.isImporting = true;
        this.errorMessage = '';

        const payloadRows = this.parsedRows.map((row) => ({
            Utterance: row.Utterance,
            ExpectedTopic: row.ExpectedTopic,
            ExpectedAction: row.ExpectedAction,
            ForbiddenAction: row.ForbiddenAction,
            ForbiddenRegex: row.ForbiddenRegex,
            Category: row.Category
        }));

        try {
            await importCsvTestCases({ suiteId: this.suiteId, rows: payloadRows });
            const importedCount = payloadRows.length;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'CSV Imported',
                    message: `Successfully imported ${importedCount} test case(s).`,
                    variant: 'success'
                })
            );
            this.parsedRows = [];
            this.fileName = '';
            this.dispatchEvent(
                new CustomEvent('importsuccess', {
                    detail: { count: importedCount }
                })
            );
        } catch (err) {
            const msg = err?.body?.message || err?.message || 'Failed to import CSV test cases.';
            this.errorMessage = msg;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Import Failed',
                    message: msg,
                    variant: 'error'
                })
            );
        } finally {
            this.isImporting = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
