
# File Structure

DATACALL/
│
├── CLAUDE.md
│
├── DATACALL_AgedCreditReport/
│   ├── CLAUDE.md
│   ├── dbo.DATACALL_AgedCreditReport.sql
│   ├── dbo.DATACALL_AgedCreditReport_Screenshot.png
│   ├── dbo.DATACALL_AgedCreditReport_UserInstructions.md
│   └── dbo.DATACALL_AgedCreditReport_UserInstructions.pdf
│
├── DATACALL_LedgerReport/
│   ├── CLAUDE.md
│   ├── dbo.DATACALL_LedgerReport.sql
│   ├── dbo.DATACALL_LedgerReport_Screenshot.png
│   ├── dbo.DATACALL_LedgerReport_UserInstructions.md
│   └── dbo.DATACALL_LedgerReport_UserInstructions.pdf

How it works:
- Root CLAUDE.md: instructions that apply to every report.
- Report folder CLAUDE.md: instructions specific to that report.
- SQL file: actual SQL implementation.
- Markdown file: master user documentation.
- PDF: published documentation.
- Screenshot: actual application interface.

# How Claude should interpret your folder structure

Structure establishes a clear hierarchy.

The important principle is that when Claude works on the Aged Credit Report, it should follow:
1. Root DATACALL/CLAUDE.md for general rules.
2. DATACALL_AgedCreditReport/CLAUDE.md for report-specific rules.
3. The SQL file for actual implementation.
4. The screenshot for the actual interface.
5. The Markdown documentation for user-facing instructions.


Claude Code automatically discovers applicable CLAUDE.md files in its directory hierarchy. Opening the DATACALL folder as your project root 
makes the root instructions available, and the nested report instructions apply when working in that report's directory. You can also verify 
what instructions Claude has loaded by asking it to explain its current project instructions.

#. Instruction loading

There is a small but important nuance to how Claude Code handles nested instructions.

When you open DATACALL as the project folder:
- The root CLAUDE.md is loaded at session startup.
- The report-level CLAUDE.md is loaded when Claude accesses files in that report's folder.
- Instructions are combined, not substituted. The report-level instructions supplement the root instructions.

You can verify loaded instructions using /context in Claude Code. 

# Interact with Claude Code

Establish a consistent workflow for every report maintenance request.

Here are some prompts you can use directly.

A. Before making a change

I need to modify this report.

First, review all associated files, including:
- CLAUDE.md
- SQL script
- Screenshot
- User instructions

Do not modify anything yet.

Explain how the report currently works and
identify the areas that may be affected by
the requested change.

Ask questions if anything is unclear.

B. Implementing a change

Implement the requested change.

Preserve existing business logic and report
functionality unless specifically required.

Modify only the necessary files.

After implementation, explain:
- What changed
- Why it changed
- Any potential impact
- Whether documentation needs updating

Do not generate the PDF.

C. Reviewing the completed work

Review all changes made to this report.

Compare the modified SQL against the original.

Look for:
- Unintended changes to business logic
- Missing filters or joins
- Changes to report parameters
- Changes to output columns
- Potential SQL performance problems
- Documentation inconsistencies

Do not make additional changes.

Provide a review of your findings.

These prompts give Claude a repeatable process rather than leaving the scope of work entirely up to its interpretation.

# Notes

Make the documentation standards part of the root CLAUDE.md, and make every report's individual CLAUDE.md explicitly reference those standards.

That way, as you add 10, 20, or 50 reports to DATACALL, Claude has a consistent process for maintaining all of them.