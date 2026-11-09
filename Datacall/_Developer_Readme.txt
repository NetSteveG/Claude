# File Structure

DATACALL/
│
├── Claude.md
│
├── [dbo].[DATACALL_AgedCreditReport]/
│   ├── Claude.md
│   ├── [dbo].[DATACALL_AgedCreditReport].sql
│   ├── [dbo].[DATACALL_AgedCreditReport]_Screenshot.png
│   ├── [dbo].[DATACALL_AgedCreditReport]_UserInstructions.md
│   └── [dbo].[DATACALL_AgedCreditReport]_UserInstructions.pdf
│
└── [dbo].[DATACALL_Ledger_FundActivity]/
    └── [dbo].[DATACALL_Ledger_FundActivity].sql

Report folders normally contain the following artifacts:

- A report-level Claude.md instruction file.
- The SQL implementation.
- A screenshot of the user interface.
- Markdown user instructions.
- A published PDF of the user instructions.

Existing reports may omit an artifact when it is not applicable. Missing artifacts should not be created unless explicitly requested.

## How the Files Work

- The root `Claude.md` contains instructions that apply to every report.
- A report-level `Claude.md`, when present, contains report-specific instructions.
- The SQL file is the authoritative source for report implementation and business logic.
- The Markdown file is the authoritative source for user-facing documentation.
- The PDF is the published version of the Markdown documentation.
- The screenshot represents the actual application interface and available controls.

## How Claude Should Interpret the Folder Structure

When working on a report:

1. Apply the general rules in the root `Claude.md`.
2. Apply the report-specific rules in the report folder's `Claude.md`, when present.
3. Review the SQL file to understand the implementation, parameters, filters, calculations, and output.
4. Review the Markdown user instructions for user-facing behavior and documentation.
5. Use the screenshot as a reference for the actual application interface.
6. Treat the PDF as the published documentation, not as the master document.

Claude Code automatically discovers applicable Claude instruction files in its directory hierarchy. Opening the `DATACALL` folder as the project root makes the root instructions available, and nested report instructions apply when working in the relevant report folder.

## Instruction Loading

When `DATACALL` is opened as the project folder:

- The root `Claude.md` is loaded at session startup.
- A report-level `Claude.md` is loaded when Claude accesses files in that report's folder.
- Instructions are combined, not substituted. Report-level instructions supplement the root instructions.

You can verify loaded instructions using `/context` in Claude Code.

## Interact with Claude Code

Establish a consistent workflow for every report maintenance request.

### A. Before Making a Change

I need to modify this report.

First, review all associated files, including:

- The applicable root and report-level `Claude.md` instruction files.
- The SQL script.
- The screenshot, when present.
- The Markdown user instructions, when present.
- The PDF, when present.

Do not modify anything yet.

Explain how the report currently works and identify the areas that may be affected by the requested change.

Ask questions if anything is unclear.

### B. Implementing a Change

Implement the requested change.

- Preserve existing business logic and report functionality unless specifically required.
- Modify only the necessary files.
- Do not execute SQL or perform SQL testing against any database environment.
- Update documentation only when report behavior or user operation changes.
- Do not generate or replace the PDF unless explicitly requested.

After implementation, explain:

- What changed.
- Why it changed.
- Any potential impact.
- Whether documentation needs updating.
- What validation was performed.
- Any assumptions or unresolved questions.

### C. Reviewing Completed Work

Review all changes made to the report.

Compare the modified SQL against the original and review related documentation for consistency.

Look for:

- Unintended changes to business logic.
- Missing filters or joins.
- Changes to report parameters.
- Changes to output columns, aliases, data types, or ordering.
- Potential SQL performance problems.
- Documentation inconsistencies.
- Unrelated or temporary files.

Do not make additional changes.

Provide a review of your findings.

These prompts provide a repeatable workflow for report maintenance.

## Notes

Documentation standards are defined in the root `Claude.md`. Each report-level `Claude.md` should explicitly reference those standards.

This structure allows additional reports to be added while maintaining consistent maintenance and documentation practices.