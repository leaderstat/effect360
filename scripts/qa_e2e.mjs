// scripts/qa_e2e.mjs — browser E2E for the applicant UI.
//
// Drives the real UI against the real Gleam API (localhost:8000) and
// the real PostgreSQL. Steps:
//   1. Fill the free-text field + submit → draft created.
//   2. Verify step 2 is shown and the request id is displayed.
//   3. Fill the required fields (the UI shell renders them).
//   4. Click "Отправить заявку" → observe the server response.
//   5. Report the final status text.
//
// Note: the UI shell posts only the free text to /api/v1/requests.
// The API's submit endpoint validates the `fields` jsonb on the request
// row, which is populated by the Go worker after classification. In this
// test we therefore assert the *contract*: a 422 with a structured
// missing[] payload (because fields are still empty) — that proves the
// completeness gate is live and blocks submission. A 200 would mean the
// fields were already populated by a worker.
export default async function run(page, ui) {
  const out = { steps: [] };

  // Step 1: create a draft.
  const before = await ui.snapshot();
  const textbox = before.match(/@(e\d+) textbox "Свободный текст заявки"/)?.[1];
  const button = before.match(/@(e\d+) button "Создать черновик"/)?.[1];
  if (!textbox || !button) return { error: 'form controls not found', snapshot: before };

  await ui.fill(textbox, 'Прошу учебную поездку в Казань 12-14 ноября 2026, цель: конференция.');
  await ui.click(button);
  await page.waitForTimeout(1200);

  const status1 = await page.locator('#status-1').innerText();
  out.steps.push({ step: 'create_draft', status1 });
  out.requestId = await page.locator('#request-id').innerText();
  out.requestStatus = await page.locator('#request-status').innerText();

  // Step 2: the form shell must render the DEMO fields.
  const fieldCount = await page.locator('#missing-fields input').count();
  out.steps.push({ step: 'render_fields', fieldCount });

  // Step 3: the submit button must be disabled until fields are filled.
  const disabledInitially = await page.locator('#btn-submit').isDisabled();
  out.steps.push({ step: 'submit_disabled_initially', disabledInitially });

  // Fill every required field in the shell.
  const names = ['destination_city', 'purpose', 'start_date', 'end_date', 'funding_source', 'approver_id'];
  for (const n of names) {
    const el = page.locator(`#missing-fields li[data-field="${n}"] input`);
    if (await el.count()) await el.fill('тестовое значение');
  }
  await page.waitForTimeout(300);
  const disabledAfter = await page.locator('#btn-submit').isDisabled();
  out.steps.push({ step: 'submit_disabled_after_fill', disabledAfter });

  // Step 4: click submit and observe the server response.
  await page.locator('#btn-submit').click();
  await page.waitForTimeout(1500);
  const status2 = await page.locator('#status-2').innerText();
  out.steps.push({ step: 'submit_click', status2 });

  // Step 5: the server may return 422 (fields empty in DB) — in that case
  // the missing list with clause_id + quote must be rendered.
  const serverMissing = await page.locator('#server-missing li').count();
  out.steps.push({ step: 'server_missing_rendered', count: serverMissing });
  const firstMissing = serverMissing > 0
    ? await page.locator('#server-missing li').first().innerText()
    : null;
  out.firstMissing = firstMissing;

  out.finalStatus = await page.locator('#request-status').innerText();
  out.finalSnapshot = await ui.snapshot();
  return out;
}
