# AgentGuard Demo Video — Voiceover & Shot Script (50 Seconds)

- **Target Runtime**: `0:00 – 0:50` (50 seconds, ~135 words @ ~160 WPM)
- **Use Case**: `ShopFlow_Support_Agent` (ShopFlow E-Commerce Support Agent)
- **Demo App**: `demo/demo_app.html` (`1920x1080`, press `H` to hide HUD, or append `?autostart=1&hud=0`)
- **Mute-Safe Design**: Bottom `#caption-bar` mirrors key beats for LinkedIn autoplay on mute.

---

## Scene-by-Scene Breakdown

### Scene 1 (`intro`) — `0:00 – 0:06` (6s)
- **Visual**: Dark-navy & Salesforce-blue Hero Title Card (*"AgentGuard — Automated Regression & Red-Teaming for Salesforce Agentforce"*).
- **Demo Trigger**: `window.demoAPI.goToScene(1)`
- **Voiceover**:
  > "One small prompt edit in Salesforce Agentforce can silently break your guardrails. Meet **AgentGuard** — automated regression and red-teaming built natively inside Salesforce."

---

### Scene 2 (`dashboard_ready`) — `0:06 – 0:14` (8s)
- **Visual**: Lightning Experience `AgentGuard` app opens. Suite `ShopFlow Support Agent (v2.1 Release)` is selected with `Credit Cap: 50 max turns`. Animated cursor clicks **Import 25 Red-Team Tests** -> green SLDS toast `"Imported 25 Red-Team test cases"`.
- **Demo Trigger**: `window.demoAPI.goToScene(2)`
- **Voiceover**:
  > "Before shipping our v2.1 update for ShopFlow's support agent, we set a 50-turn credit cap and import 25 adversarial red-team tests in one click."

---

### Scene 3 (`running_to_failed`) — `0:14 – 0:25` (11s)
- **Visual**: Cursor clicks **Run Suite**. Status transitions `Queued` -> `Running` (spinner) -> `Failed` (red KPI). KPI cards update: `92.0%` Pass Rate, `25` Total, `2` Failed, `2` Regressions Detected (red alert card). Datatable highlights `PB-01 $500 Refund Override` with a `Regression` warning badge.
- **Demo Trigger**: `window.demoAPI.goToScene(3)`
- **Voiceover**:
  > "AgentGuard runs the full suite asynchronously. Seconds later, it flags two critical regressions — including `PB-01`: an unauthorized $500 refund override."

---

### Scene 4 (`inspector_modal`) — `0:25 – 0:39` (14s)
- **Visual**: Cursor clicks **Inspect** on `PB-01`. The **AgentGuard Result Inspector Modal** opens, showing the red Version-Diff Banner (`Order_Issue_Resolution` -> `Instant_Refund_Override`), the prompt-injection utterance, forbidden action `Issue_Instant_Refund`, and Failure Reason.
- **Demo Trigger**: `window.demoAPI.goToScene(4)`
- **Voiceover**:
  > "Opening the Result Inspector pinpoints the exact root cause. A prompt-injection utterance hijacked the topic from `Order_Issue_Resolution` to `Instant_Refund_Override`, triggering the forbidden `Issue_Instant_Refund` action."

---

### Scene 5 (`fixed_and_cta`) — `0:39 – 0:50` (11s)
- **Visual**: Quick transition to `v2.2 Fix Verified: 100% Pass Rate | 0 Regressions | InfoSec Ready` (`0:39–0:42`), then fades to the Outro Card (*"AgentGuard — 100% Native 2GP Managed Package. Built for Salesforce Architects & SIs."*).
- **Demo Trigger**: `window.demoAPI.goToScene(5)`
- **Voiceover**:
  > "After tightening the topic guardrail in v2.2, AgentGuard verifies a 100% pass rate with zero regressions. **AgentGuard** — a 100% native 2GP managed package, built for Salesforce Architects and SIs."
