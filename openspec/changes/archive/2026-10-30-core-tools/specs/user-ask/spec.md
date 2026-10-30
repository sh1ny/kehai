# Spec Delta

## Purpose

Lets the model ask the user a structured question and receive a typed answer. It defines the one answerer channel that permission prompts also use, so a client can serve both.

## ADDED Requirements

### Requirement: Structured question
`ask` SHALL take a question, 0–10 distinct non-empty choices, and whether free text is allowed. Free text defaults to allowed when there are no choices and to not allowed otherwise. The answer is stored and composed as JSON: `{"choice":"<choice>"}` or `{"text":"<text>"}`.

#### Scenario: Choice answered
- **WHEN** the model asks `Which shell?` with choices `bash` and `pwsh`, and the user picks `pwsh`
- **THEN** the call settles `ok` and its result is exactly `{"choice":"pwsh"}`

#### Scenario: Invalid question
- **WHEN** `ask` is called with 11 choices, two equal choices, or no choices with free text disallowed
- **THEN** argument validation rejects it naming the violated rule, and no question reaches the user

### Requirement: Answerer channel
The engine SHALL deliver each question and each permission prompt to at most one attached answerer. Each item carries its call key, and the answerer replies by that key. An answer that does not fit the question is refused back to the answerer, and the question stays open. Without an answerer, `ask` settles `error` with `no user attached`.

#### Scenario: Answer outside the choices
- **WHEN** a question offers `a` and `b` without free text and the answerer replies `c`
- **THEN** the reply is refused with `answer must be one of: a, b`, the call stays `running`, and a later reply `a` settles it

#### Scenario: Headless session
- **WHEN** `ask` is called while no answerer is attached
- **THEN** the call settles `error` with `no user attached` without waiting

#### Scenario: Question cancelled
- **WHEN** the turn is cancelled while a question is open
- **THEN** the call becomes `cancelled` with reason `user`, the answerer is told the question was withdrawn, and a later reply for it is refused with `question withdrawn`
