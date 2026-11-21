# AgentGuard — Static Security Scan & Pre-Audit Report (AG-401)

**Date:** 2026-11-14  
**Scope:** `force-app/main/default/classes/`, `force-app/main/default/lwc/`, `force-app/main/default/customMetadata/`  
**Salesforce API Version:** 62.0

---

## 1. Tooling Availability Check

| Check | Command | Result |
| :--- | :--- | :--- |
| Salesforce CLI | `sf --version` | `@salesforce/cli/2.153.5 darwin-x64 node-v24.21.0` |
| SF Scanner / Code Analyzer | `sf plugins` | `code-analyzer 5.16.0` listed as **Uninstalled JIT Plugin** (not installed locally) |
| LWC ESLint | `npm run lint` (`eslint **/lwc/**`) | Not installed (`sh: eslint: command not found`) |
| Prettier Check | `npm run prettier:verify` | Failed on XML/Apex files (`No parser could be inferred` for `.cls`/`.xml` in current config) |
| LWC Jest Unit Tests | `npm run test:unit` | **PASS** — 3 test suites, 17 tests passed (0 failed) |

Because `sf code-analyzer` and `eslint` are not installed in this environment, a comprehensive automated + manual static security audit was executed across all Apex classes, LWC components, and Custom Metadata records.

---

## 2. Apex Security Audit (`force-app/main/default/classes/`)

All 10 Apex classes (5 production + 5 test classes) were audited.

### 2.1 Sharing Model (`with sharing`)
**Result:** **PASS (10/10 classes)**

- `AgentGuardDashboardController.cls` — `public with sharing class`
- `AgentGuardDashboardControllerTest.cls` — `public with sharing class`
- `AgentGuardEvaluatorService.cls` — `public with sharing class`
- `AgentGuardEvaluatorServiceTest.cls` — `public with sharing class`
- `AgentGuardRunnerQueueable.cls` — `public with sharing class`
- `AgentGuardRunnerQueueableTest.cls` — `public with sharing class`
- `AgentGuardRuntimeClient.cls` — `public with sharing class`
- `AgentGuardRuntimeClientTest.cls` — `public with sharing class`
- `AgentGuard_RunSuiteAction.cls` — `public with sharing class`
- `AgentGuard_RunSuiteActionTest.cls` — `public with sharing class`

Zero occurrences of `without sharing` or omitted sharing keywords.

### 2.2 SOQL CRUD/FLS Enforcement (`WITH USER_MODE`)
**Result:** **PASS (11/11 SOQL queries)**

Every SOQL query in production and test classes uses `WITH USER_MODE`:
- `AgentGuardDashboardController.cls`: lines 19, 43, 70, 124 (4 queries, all `WITH USER_MODE`)
- `AgentGuardRunnerQueueable.cls`: lines 27, 100 (2 queries, all `WITH USER_MODE`)
- `AgentGuardRunnerQueueableTest.cls`: lines 77, 88, 126, 155 (4 queries, all `WITH USER_MODE`)
- `AgentGuard_RunSuiteActionTest.cls`: line 34 (1 query, `WITH USER_MODE`)

### 2.3 DML CRUD/FLS Enforcement (`AccessLevel.USER_MODE`)
**Result:** **PASS (21/21 DML statements)**

Every DML operation uses `Database.insert(..., AccessLevel.USER_MODE)` or `Database.update(..., AccessLevel.USER_MODE)`:
- `AgentGuardDashboardController.cls`: lines 153, 221
- `AgentGuardDashboardControllerTest.cls`: lines 19, 26, 35, 43, 69
- `AgentGuardRunnerQueueable.cls`: lines 78, 85, 94, 172
- `AgentGuardRunnerQueueableTest.cls`: lines 47, 61, 67, 105, 107, 119, 143, 149
- `AgentGuard_RunSuiteAction.cls`: line 50
- `AgentGuard_RunSuiteActionTest.cls`: line 18

### 2.4 Dynamic SOQL & Session ID Exposure
**Result:** **PASS (0 occurrences)**

- `Database.query` / unescaped dynamic SOQL: **0 occurrences**
- `UserInfo.getSessionId()`: **0 occurrences** (runtime and LLM Judge callouts authenticate exclusively via Named Credential `callout:Self_Agent_Runtime_NC` backed by `Self_Agent_Runtime_EC`)
- URL path parameters in `AgentGuardRuntimeClient.cls` (`agentApiName`, `sessionId`) are sanitized with `EncodingUtil.urlEncode(..., 'UTF-8')`.

### 2.5 Named Credential & Permission Set Access (`AgentGuard_Admin`)
**Result:** **PASS**

- `AgentGuard_Admin.permissionset-meta.xml` explicitly grants `<externalCredentialPrincipalAccesses>` (`enabled = true`) for `Self_Agent_Runtime_EC-AgentRuntimePrincipal`, ensuring least-privilege External Credential principal access for runtime and LLM Judge callouts.

---

## 3. LWC Security Audit (`force-app/main/default/lwc/`)

All 3 LWC bundles (`agentGuardDashboard`, `agentGuardCsvLoader`, `agentGuardResultInspector`) were audited.

| Check | Result |
| :--- | :--- |
| `innerHTML` / `outerHTML` | **PASS** — 0 occurrences |
| `lwc:dom="manual"` | **PASS** — 0 occurrences |
| `eval()` / `document.write` | **PASS** — 0 occurrences |
| Template rendering | **PASS** — Uses standard Lightning base components (`lightning-combobox`, `lightning-datatable`, `lightning-button`, `lightning-badge`, `lightning-input`) and auto-escaped LWC data bindings |

---

## 4. Red-Team Custom Metadata Regex Audit (`RedTeam_Template__mdt`)

All 25 `RedTeam_Template.*.md-meta.xml` records were parsed and checked for `Forbidden_Regex__c` length and catastrophic backtracking (ReDoS) patterns:

- **Templates Checked:** 25
- **Max `Forbidden_Regex__c` Length:** 94 characters (well below the 255-character limit; `AgentGuardEvaluatorService.cls` also enforces `MAX_REGEX_LENGTH = 255` at runtime)
- **ReDoS Scan Cap:** 10,000-character response scan cap to bound regex evaluation against catastrophic backtracking / ReDoS on large agent responses
- **Nested Quantifier / ReDoS Patterns:** 0 detected

---

## 5. Findings Summary

- **Critical / High Issues:** 0
- **Medium Issues:** 0
- **Pending Verification (Scratch Org / CLI Setup):**
  - Live Scratch Org payload capture to verify the `AgentGuardRuntimeClient` sync trace shape against a live Agentforce runtime endpoint.
  - `sf code-analyzer run` execution once the `code-analyzer` JIT CLI plugin is installed in CI or locally.
- **Status:** **READY FOR 2GP PACKAGING & SCRATCH ORG VERIFICATION** (complete live Scratch Org payload capture and `sf code-analyzer run` prior to formal AppExchange Security Review submission).
