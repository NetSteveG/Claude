# SQL Report Maintenance Project

## Purpose
This project contains SQL scripts used by our
application for reporting and data processing.

Each SQL report has its own folder containing:
- SQL script
- Screenshot of the user interface
- Markdown user instructions
- PDF user instructions

## General Rules

1. Preserve existing SQL functionality unless
   explicitly instructed otherwise.
2. Do not make assumptions about business rules.
3. Ask questions when requirements are unclear.
4. Maintain existing SQL formatting and conventions.
5. Review the associated documentation whenever
   SQL changes affect report behavior.
6. Do not update screenshots unless explicitly asked.

## Documentation Rules

The Markdown UserInstructions file is the
authoritative source for user documentation.

The PDF is generated from the Markdown file.

When updating documentation:
- Keep instructions accurate to the current SQL
  and user interface.
- Use the existing screenshot when appropriate.
- Do not invent interface options or functionality.
- Preserve existing formatting and organization.

## PDF Generation

Only generate or replace PDFs when explicitly
requested.

The PDF must be generated from the Markdown file
with the appropriate screenshot incorporated.

Never treat the PDF as the master document.

## SQL Safety and Change Control

1. Never execute SQL against a production database.
2. Never modify database objects directly.
3. Treat SQL scripts as source code, not commands to execute.
4. Do not change stored procedure parameters, result
   columns, aliases, or data types without explicit approval.
5. Preserve existing report output and business logic
   unless the requested change requires otherwise.
6. Do not remove existing filters, joins, calculations,
   or validation logic without explaining the impact.
7. Identify potential performance implications of SQL changes.
8. Do not assume that a successful SQL syntax review
   proves the report produces correct results.

## Change Review

Before modifying a SQL file:

1. Read the existing SQL.
2. Read the associated report CLAUDE.md.
3. Review the associated user documentation.
4. Identify the requested change and affected functionality.
5. Explain the proposed changes before implementation
   when the change is substantial.

After modifying a SQL file:

1. Summarize the changes.
2. Identify affected parameters and output columns.
3. Identify any changes to report behavior.
4. Identify documentation updates that are necessary.
5. Report any validation that was performed.
6. Identify anything that still requires manual testing.

## Report Documentation Standards

Every report must maintain three complementary documentation components:

1. **SQL Summary:** A detailed technical summary maintained in the SQL script header.
2. **User Instructions:** A complete, user-friendly Markdown document based on the SQL Summary's User instructions section.
3. **PDF:** The published version generated from the Markdown document.

### SQL Summary Requirements

The SQL script header must contain a well-organized summary documenting:

- Report purpose and eligibility requirements.
- User instructions.
- Report parameters, defaults, validation, and normalization.
- Field-to-parameter mapping.
- How parameters work together.
- Sample entries and expected report titles.
- Processing overview.
- Important business rules and calculations.
- Data selection, filtering, and allocation logic.
- Temporary tables and their purposes.
- Report output layout and column descriptions.
- Example EXEC statements.

The User instructions section within the SQL summary must describe the report parameters, their purpose, accepted values, defaults, 
and how the user operates the report.

Maintain this section whenever SQL changes affect report functionality or user-facing behavior.

### Markdown User Instructions Requirements

The Markdown UserInstructions file is the master user-facing document.

It must be developed from the SQL Summary's User instructions section and expanded as necessary to provide complete, understandable 
instructions for report users.

Follow a consistent organization and presentation:

1. What this report shows
2. Running the report
3. Screenshot of the actual application interface
4. Parameter descriptions, defaults, and entry requirements
5. Correct and incorrect entry examples
6. Explanation of how parameters work together
7. Important business rules affecting report results
8. Sample runs with expected report titles
9. How to read and interpret the report output
10. Explanation of totals, footer, and parameter information
11. Frequently asked questions and troubleshooting

Not every section must appear if it is not relevant to a particular report.

### Documentation Accuracy

- Base all documentation on actual SQL functionality and verified application behavior.
- Use the SQL Summary's User instructions section as the starting point for the Markdown document.
- Use the actual application screenshot as the reference for screen layout and available controls.
- Do not invent application navigation, parameters, options, or functionality.
- Explain technical behavior in language appropriate for report users.
- Include practical examples wherever they help users understand how to operate the report.
- Ensure examples and expected results agree with the actual SQL implementation.
- Preserve existing documentation organization and formatting conventions.
- When SQL functionality changes, review both the SQL Summary and Markdown documentation for consistency.

### Documentation Maintenance Workflow

When a report is modified:

1. Review the existing SQL Summary.
2. Determine whether the change affects documented report behavior.
3. Update the SQL Summary, including its User instructions section, when necessary.
4. Update the Markdown UserInstructions file to reflect the changes.
5. Review the entire Markdown document for consistency, completeness, and accuracy.
6. Preserve the existing screenshot unless the application interface has changed and an updated screenshot is explicitly requested.
7. Do not generate or replace the PDF unless explicitly requested.

### PDF Publishing

- Generate the PDF exclusively from the Markdown UserInstructions file.
- Incorporate the appropriate report screenshot.
- Preserve the Markdown document's organization, tables, examples, and formatting.
- Never edit the PDF independently of the Markdown source.

## Standard Report Documentation Format

The **Aged Credit Report UserInstructions.md** is the master example for the organization, formatting, writing style, and level of 
detail expected in user documentation for all DATACALL reports.

When creating or updating documentation for any report:

- Use the Aged Credit Report UserInstructions.md as the required formatting and organizational template.
- Follow its overall structure, heading hierarchy, tables, examples, explanations, FAQs, and user-friendly writing style.
- Maintain a consistent appearance and organization across all report documentation.
- Adapt sections to the functionality of the individual report. Not every report will require every section.
- Do not create a new documentation format or substantially change the established style without explicit direction.
- Do not copy report-specific content, parameters, or business rules from the Aged Credit Report into other reports.
- Preserve the established style while accurately documenting each report's unique functionality.

Before creating a new report's UserInstructions.md, review the Aged Credit Report UserInstructions.md and use it as the starting 
point for the document's organization and presentation.

## Required User Documentation Template

The Aged Credit Report UserInstructions.md is the standard reference and formatting template for all DATACALL report user documentation.

Before creating or substantially revising a report's UserInstructions.md:

1. Read the Aged Credit Report UserInstructions.md:
   `DATACALL_AgedCreditReport/dbo.DATACALL_AgedCreditReport_UserInstructions.md`
2. Use it as the reference for document organization, heading structure, formatting, tables, examples, explanations, and FAQs.
3. Maintain a consistent writing style and presentation across all reports.
4. Adapt the structure as appropriate for the functionality of the individual report.
5. Do not invent a different documentation style or substantially change the established format without explicit direction.

The Aged Credit Report document is a formatting and organizational template, not a source of business rules or report-specific 
functionality. All report-specific content must be based on the corresponding SQL implementation and verified application behavior.