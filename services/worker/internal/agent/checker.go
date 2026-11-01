package agent

import (
	"fmt"
	"sort"
	"strings"
)

// Requirement mirrors one row of the `requirements` table.
//
// It is the SAME contract as `completeness.Requirement` in Gleam, so the
// agent and the API check a request against exactly the same rules.
type Requirement struct {
	FieldName string `json:"field_name"`
	Required  bool   `json:"required"`
	// Condition is the raw jsonb of the condition. The supported grammar
	// is "required if <field> == '<literal>'"; anything else is treated
	// conservatively as "the requirement applies" — the same conservative
	// default the Gleam engine uses.
	Condition string `json:"condition"`
	ClauseID  string `json:"clause_id"`
	Quote     string `json:"quote"`
}

// RequestSnapshot is the data the agent checks.
//
// It is loaded through the Gleam API (or read from the database by the
// API) so the agent always works on the CURRENT state of the request, not
// on a stale copy from the event payload.
type RequestSnapshot struct {
	ID           string            `json:"id"`
	Status       string            `json:"status"`
	RequestType  string            `json:"request_type"`
	RawText      string            `json:"raw_text"`
	Fields       map[string]string `json:"fields"`
	Requirements []Requirement     `json:"requirements"`
	// The due date of the request, if any.
	DueAt string `json:"due_at"`
	// Recheck marks an EXPLICIT re-run requested by a moderator. It widens
	// the set of statuses the checker may examine — never the set of
	// actions the agent may take.
	Recheck bool `json:"-"`
}

// Checker performs the DETERMINISTIC part of the digital moderator's work.
//
// Everything here is a pure function of the snapshot: no LLM, no clock, no
// network. The result is reproducible and auditable.
//
// The LLM is only used to EXPLAIN a decision that has already been made
// and to DRAFT clarifying questions — never to decide.
type Checker struct{}

// NewChecker builds a checker.
func NewChecker() *Checker { return &Checker{} }

// Check runs the deterministic check over a request.
//
// The checks are:
//
// 1. "request_exists"        — the request could be loaded at all.
//  2. "status_processable"    — the request is in a status the agent may
//     process (`submitted`).
//  3. "fields_present"        — every required field is filled.
//  4. "conditions_respected"  — conditional requirements are satisfied.
//  5. "data_consistent"       — the filled fields do not contradict each
//     other (e.g. end date before start date).
//  6. "documents_present"     — the required documents (fields of the
//     `documents` group) are attached.
//
// The outcome is one of:
//   - ResultPassed     — everything is in order;
//   - ResultNeedsInfo  — required data is missing (a clarification request
//     is prepared);
//   - ResultAmbiguous  — a contradiction was found (a human decides).
func (c *Checker) Check(snap RequestSnapshot) Decision {
	start := nowMillis()

	checks := []CheckItem{}
	problems := []Problem{}

	if snap.ID == "" {
		return Decision{
			Result:   ResultError,
			Checks:   []CheckItem{{Name: "request_exists", OK: false, Detail: "заявка не найдена"}},
			Reason:   "Заявка не найдена.",
			RuleCode: RuleLlmFailure,
		}
	}
	checks = append(checks, CheckItem{Name: "request_exists", OK: true, Detail: snap.ID})

	// 2. The status must be one the agent may process.
	//
	// An explicit re-run (a moderator asked for it) may also examine a
	// request that is back with the applicant: the applicant answered, so
	// the check has to be repeated on the current data.
	processable := IsProcessableStatus(snap.Status)
	if !processable && snap.Recheck {
		processable = IsRecheckStatus(snap.Status)
	}
	if !processable {
		checks = append(checks, CheckItem{
			Name:   "status_processable",
			OK:     true,
			Detail: fmt.Sprintf("статус %s — обработка не требуется", snap.Status),
		})
		return Decision{
			Result:   ResultSkipped,
			Checks:   checks,
			Reason:   "Заявка не в статусе «Отправлена» — повторная обработка не выполняется.",
			RuleCode: RuleModeBlocked,
		}
	}
	checks = append(checks, CheckItem{Name: "status_processable", OK: true, Detail: snap.Status})

	fields := snap.Fields
	if fields == nil {
		fields = map[string]string{}
	}

	// 3 + 4. Required and conditional fields.
	missingRequired := []string{}
	unsatisfiedCondition := []string{}
	for _, req := range snap.Requirements {
		value := strings.TrimSpace(fields[req.FieldName])
		present := value != ""

		if present {
			continue
		}
		if !req.Required && strings.TrimSpace(req.Condition) == "" {
			// Neither required nor conditional: satisfied trivially.
			continue
		}
		if strings.TrimSpace(req.Condition) != "" {
			applies := evaluateCondition(req.Condition, fields)
			if !applies {
				// The condition does not apply: satisfied trivially.
				continue
			}
			unsatisfiedCondition = append(unsatisfiedCondition, req.FieldName)
			problems = append(problems, Problem{
				FieldName: req.FieldName,
				Reason:    "conditional_unmet",
				Message:   fmt.Sprintf("Не выполнено условие для поля «%s».", req.FieldName),
				ClauseID:  req.ClauseID,
				Quote:     req.Quote,
			})
			continue
		}
		missingRequired = append(missingRequired, req.FieldName)
		problems = append(problems, Problem{
			FieldName: req.FieldName,
			Reason:    "required_field_absent",
			Message:   fmt.Sprintf("Не заполнено обязательное поле «%s».", req.FieldName),
			ClauseID:  req.ClauseID,
			Quote:     req.Quote,
		})
	}
	sort.Strings(missingRequired)
	sort.Strings(unsatisfiedCondition)

	fieldsOK := len(missingRequired) == 0 && len(unsatisfiedCondition) == 0
	if fieldsOK {
		checks = append(checks, CheckItem{
			Name:   "fields_present",
			OK:     true,
			Detail: "все обязательные поля заполнены",
		})
		checks = append(checks, CheckItem{
			Name:   "conditions_respected",
			OK:     true,
			Detail: "условия требований выполнены",
		})
	} else {
		checks = append(checks, CheckItem{
			Name:   "fields_present",
			OK:     false,
			Detail: fmt.Sprintf("не заполнено: %s", strings.Join(missingRequired, ", ")),
		})
		checks = append(checks, CheckItem{
			Name:   "conditions_respected",
			OK:     false,
			Detail: fmt.Sprintf("не выполнено: %s", strings.Join(unsatisfiedCondition, ", ")),
		})
	}

	// 5. Consistency of the filled data.
	contradictions := findContradictions(fields)
	for _, p := range contradictions {
		problems = append(problems, p)
	}
	if len(contradictions) == 0 {
		checks = append(checks, CheckItem{
			Name:   "data_consistent",
			OK:     true,
			Detail: "противоречий не обнаружено",
		})
	} else {
		checks = append(checks, CheckItem{
			Name:   "data_consistent",
			OK:     false,
			Detail: fmt.Sprintf("противоречий: %d", len(contradictions)),
		})
	}

	// 6. Documents.
	missingDocs := findMissingDocuments(fields)
	for _, name := range missingDocs {
		problems = append(problems, Problem{
			FieldName: name,
			Reason:    "document_absent",
			Message:   fmt.Sprintf("Не приложен документ «%s».", name),
		})
	}
	if len(missingDocs) == 0 {
		checks = append(checks, CheckItem{
			Name:   "documents_present",
			OK:     true,
			Detail: "документы приложены",
		})
	} else {
		checks = append(checks, CheckItem{
			Name:   "documents_present",
			OK:     false,
			Detail: fmt.Sprintf("не приложено: %s", strings.Join(missingDocs, ", ")),
		})
	}

	result := ResultPassed
	reason := "Все обязательные поля заполнены, противоречий не обнаружено."
	switch {
	case len(contradictions) > 0:
		// A contradiction is an ambiguity: a human must decide. It has
		// priority over every other finding, because it is a fact about
		// the data that was actually filled in.
		result = ResultAmbiguous
		reason = "Обнаружено противоречие или неопределённость в данных заявки."
	case len(snap.Requirements) == 0:
		// Without a request type the server cannot tell WHICH requirements
		// apply, so completeness cannot be confirmed. A vacuous pass here
		// would let an unchecked request move on, so it becomes a request
		// for information instead.
		result = ResultNeedsInfo
		reason = "Не определён тип заявки: состав обязательных полей неизвестен, проверить полноту невозможно."
		problems = append(problems, Problem{
			FieldName: "request_type_id",
			Reason:    "request_type_unknown",
			Message:   "Не выбран тип заявки, поэтому состав обязательных полей неизвестен.",
		})
	case !fieldsOK || len(missingDocs) > 0:
		// Missing data — either a required field or a required document.
		result = ResultNeedsInfo
		reason = fmt.Sprintf("Не заполнены обязательные поля: %d.", len(problems))
	}

	decision := Decision{
		Result:   result,
		Checks:   checks,
		Problems: problems,
		Reason:   reason,
		RuleCode: RuleForResult(result),
	}
	if result == ResultNeedsInfo {
		decision.ClarificationRequest = BuildClarificationRequest(problems)
	}
	decision.DurationMillis = nowMillis() - start
	return decision
}

// findContradictions looks for pairs of fields that cannot both be true.
//
// The checks are deliberately conservative and factual — they look at
// well-known field names only, and they never guess a legal meaning.
func findContradictions(fields map[string]string) []Problem {
	var out []Problem

	start := strings.TrimSpace(fields["start_date"])
	end := strings.TrimSpace(fields["end_date"])
	if start != "" && end != "" {
		// Compare only when both values look like "day month" or "day.month".
		sd, sok := parseDayMonth(start)
		ed, eok := parseDayMonth(end)
		if sok && eok && ed < sd {
			out = append(out, Problem{
				FieldName: "end_date",
				Reason:    "date_range_inverted",
				Message:   "Дата окончания раньше даты начала.",
			})
		}
	}

	// A trip with a budget source must have a funding source, and a grant
	// without a number is contradictory.
	funding := strings.ToLower(strings.TrimSpace(fields["funding_source"]))
	if funding == "grant" && strings.TrimSpace(fields["grant_number"]) == "" {
		out = append(out, Problem{
			FieldName: "grant_number",
			Reason:    "grant_without_number",
			Message:   "Указан грант, но не указан номер гранта.",
		})
	}
	if funding != "" && funding != "grant" && funding != "budget" {
		out = append(out, Problem{
			FieldName: "funding_source",
			Reason:    "unknown_funding_source",
			Message:   fmt.Sprintf("Неизвестный источник финансирования «%s».", funding),
		})
	}

	return out
}

// findMissingDocuments returns the names of the required documents that are
// not attached.
//
// A document is a field whose name starts with `document_` or that ends
// with `_attachment`. The check is factual: either the field is filled or
// the document is missing.
func findMissingDocuments(fields map[string]string) []string {
	var missing []string
	for name, value := range fields {
		lower := strings.ToLower(name)
		isDocument := strings.HasPrefix(lower, "document_") ||
			strings.HasSuffix(lower, "_attachment")
		if !isDocument {
			continue
		}
		if strings.TrimSpace(value) == "" {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	return missing
}

// evaluateCondition evaluates the supported condition grammar:
//
//	"required if <field> == '<literal>'"
//
// Anything else is treated conservatively as "the requirement applies" —
// the same safe default as in `completeness.gleam`.
func evaluateCondition(condition string, fields map[string]string) bool {
	expr := strings.TrimSpace(condition)
	prefix := "required if "
	idx := strings.Index(expr, prefix)
	if idx < 0 {
		return true
	}
	rest := strings.TrimSpace(expr[idx+len(prefix):])
	parts := strings.Split(rest, " == ")
	if len(parts) != 2 {
		return true
	}
	field := strings.TrimSpace(parts[0])
	literal := strings.TrimSpace(parts[1])
	literal = strings.TrimPrefix(literal, "'")
	literal = strings.TrimSuffix(literal, "'")
	actual, ok := fields[field]
	if !ok {
		// The predicate cannot be proven — be conservative.
		return true
	}
	return strings.TrimSpace(actual) == literal
}

// BuildClarificationRequest builds the text of the clarification request.
//
// It is deterministic and built from the actual missing fields — the agent
// never invents a legal basis.
func BuildClarificationRequest(problems []Problem) string {
	if len(problems) == 0 {
		return "Для продолжения рассмотрения нужны дополнительные сведения."
	}
	seen := map[string]bool{}
	var names []string
	for _, p := range problems {
		if p.FieldName == "" || seen[p.FieldName] {
			continue
		}
		seen[p.FieldName] = true
		names = append(names, p.FieldName)
	}
	sort.Strings(names)
	if len(names) == 0 {
		return "Для продолжения рассмотрения нужны дополнительные сведения."
	}
	return "Для продолжения рассмотрения уточните, пожалуйста: " +
		strings.Join(names, ", ") +
		". Заявка вернётся в работу сразу после уточнения."
}

// parseDayMonth parses a "day month" or "day.month" value into a sortable
// number. The second return value reports whether the parse succeeded.
func parseDayMonth(value string) (int, bool) {
	v := strings.TrimSpace(strings.ToLower(value))
	if v == "" {
		return 0, false
	}
	months := map[string]int{
		"января": 1, "январь": 1,
		"февраля": 2, "февраль": 2,
		"марта": 3, "март": 3,
		"апреля": 4, "апрель": 4,
		"мая": 5, "май": 5,
		"июня": 6, "июнь": 6,
		"июля": 7, "июль": 7,
		"августа": 8, "август": 8,
		"сентября": 9, "сентябрь": 9,
		"октября": 10, "октябрь": 10,
		"ноября": 11, "ноябрь": 11,
		"декабря": 12, "декабрь": 12,
	}
	// "12.11" / "12-11"
	for _, sep := range []string{".", "-"} {
		parts := strings.Split(v, sep)
		if len(parts) == 2 {
			day, ok1 := atoi(parts[0])
			month, ok2 := atoi(parts[1])
			if ok1 && ok2 && day >= 1 && day <= 31 && month >= 1 && month <= 12 {
				return month*100 + day, true
			}
		}
	}
	// "12 ноября"
	fields := strings.Fields(v)
	if len(fields) == 2 {
		day, ok1 := atoi(fields[0])
		month, ok2 := months[fields[1]]
		if ok1 && ok2 {
			return month*100 + day, true
		}
	}
	return 0, false
}

// atoi parses a small non-negative integer.
func atoi(s string) (int, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, false
	}
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, false
		}
		n = n*10 + int(r-'0')
	}
	return n, true
}
