# DATACALL Aged Credit Report

## Associated Files

SQL:
dbo.DATACALL_AgedCreditReport.sql

Screenshot:
dbo.DATACALL_AgedCreditReport_Screenshot.png

User Documentation:
dbo.DATACALL_AgedCreditReport_UserInstructions.md

PDF:
dbo.DATACALL_AgedCreditReport_UserInstructions.pdf

## Report Purpose

This report produces an aged credit report.

## SQL Maintenance

When modifying the SQL script:

1. Review the existing SQL before making changes.
2. Preserve existing business logic unless instructed.
3. Identify changes that affect report output,
   parameters, filters, or user functionality.
4. Review the user instructions for accuracy.
5. Update the Markdown instructions if necessary.
6. Do not generate the PDF unless requested.

## User Documentation

The Markdown file is the master documentation.

Keep the documentation consistent with:
- SQL functionality
- Available report parameters
- Screen layout
- User workflow

Use the existing screenshot as the reference
for the user interface.

## PDF

Generate the PDF only when explicitly requested.

Use the Markdown file as the source and incorporate
the latest screenshot.

## Report Change Checklist

Before completing any requested changes:

- [ ] Existing SQL functionality reviewed.
- [ ] Report parameters reviewed.
- [ ] Existing filters and calculations preserved.
- [ ] Output columns and aliases reviewed.
- [ ] Associated user documentation reviewed.
- [ ] Documentation updated if user functionality changed.
- [ ] Screenshot preserved unless explicitly requested.
- [ ] PDF preserved unless explicitly requested.

## Important

The SQL script is the authoritative source for
report implementation.

The Markdown file is the authoritative source for
user-facing instructions.

The screenshot represents the actual application interface.

Do not assume that changes to one file automatically
require changes to every other file.

## Required Documentation Standard

Follow the Report Documentation Standards defined in the root DATACALL/CLAUDE.md.

This report must maintain consistent documentation across:

1. SQL script header summary.
2. SQL Summary's User instructions section.
3. UserInstructions.md.
4. Published UserInstructions.pdf.

### Documentation Requirements

- The SQL script header must contain a detailed technical summary.
- The User instructions section within that summary is the foundation for the Markdown user guide.
- The Markdown user guide must expand the summary into a complete, organized, user-friendly document.
- Use the actual application screenshot to document the user interface and report workflow.
- Follow the organization and presentation established by the existing Aged Credit Report UserInstructions.md.
- Preserve the existing documentation style, including headings, tables, examples, and FAQs.
- Do not omit important functionality or user-facing behavior when updating documentation.

### When SQL Changes Are Made

Determine whether the change affects the report's parameters, defaults, calculations, filtering, output, or user workflow.

If affected:

1. Update the SQL header summary.
2. Update its User instructions section.
3. Update the Markdown UserInstructions.md.
4. Review the complete Markdown document for accuracy and consistency.

If documentation is unaffected, do not make unnecessary documentation changes.

### PDF

The PDF is generated from the Markdown file only when explicitly requested.

## Documentation Format

Follow the Standard Report Documentation Format defined in the root DATACALL/CLAUDE.md.

Use the following file as the required organizational and formatting example for this report's UserInstructions.md:

`../DATACALL_AgedCreditReport/dbo.DATACALL_AgedCreditReport_UserInstructions.md`

Maintain its heading structure, tables, examples, explanatory detail, FAQs, and user-friendly writing style. Adapt the 
content to this report's actual functionality.

Do not invent a different documentation format or unnecessarily change the established style.