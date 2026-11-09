# Aged Credit Report — User Instructions

## What this report shows

The Aged Credit Report lists employers that hold credits of at least the amount you choose. Employers with the largest credits are listed first.

You choose which credits count, using **Credits to Compare**: all of an employer's credits, only credits older than an age you choose, or only newer ones. That total is what's compared to your **Minimum Credit Amount**.

**Who is included.** An employer appears only when both of these are true:

- Their financing method is **Experience Rated** or **Billed Quarterly**.
- Their current status is **Active**, **Terminated** or **Inactive**.

---

## Running the report

The report is run from the **DataCalls** site.

1. Open **DataCalls** and click **Reporting** in the top menu.
2. Under **Download Data**, set **Area** to **Accounting**.
3. Set **Data Call** to **Aged Credit Report**.
4. Under **Parameters**, type a value in each of the three text boxes. Any box you leave blank uses its default.
5. Download the report.

The report page looks like this:

![The DataCalls Reporting page with Area set to Accounting, Data Call set to Aged Credit Report, and the three Parameters text boxes: Minimum credit amount, Credit age and Credits to compare](CreditReport__ScreenShot.png)

If the page shows **"You lack permissions to download the file"** under the Parameters, as in this screenshot, your account can't download the report yet. Ask your administrator for access.

| Text box | What it does | Default | What to type |
|---|---|---|---|
| **Minimum Credit Amount ($)** | An employer is listed only when the total chosen in **Credits to Compare** is at least this amount. | 10000.00 | A dollar amount of **1000 or more**, using **digits only**, with an optional decimal point and up to 2 decimal places. **Don't type a $ sign, commas or spaces.** |
| **Credit Age (years)** | Splits credits into "over aged" (this many years old or more) and "under aged" (newer). | 4 | A **whole number, 0 or more**. No decimal point. |
| **Credits to Compare** | Which total is compared to the **Minimum Credit Amount**. | C | **One letter**: `C`, `O` or `U`. Upper or lower case both work. |

### Entry examples

| Text box | Correct | Incorrect |
|---|---|---|
| Minimum Credit Amount ($) | `10000`   `10000.00`   `25000.5` | `$10,000.00`   `10,000`   `10 000` |
| Credit Age (years) | `0`   `2`   `4` | `2.5`   `four`   `4 years` |
| Credits to Compare | `C`   `o`   `U` | `All`   `Over`   `OU` |

### Credits to Compare letters

| Letter | Choice | Total compared to the Minimum Credit Amount |
|---|---|---|
| `C` | All Credits (default) | Total Credits: all credits, any age |
| `O` | Over Aged Credits | Credits at least Credit Age years old |
| `U` | Under Aged Credits | Credits newer than Credit Age years |

### How Credits to Compare and Minimum Credit Amount work together

The total you choose by typing a letter in **Credits to Compare** is the one compared to the **Minimum Credit Amount**. An employer is listed only when that total is at least the Minimum Credit Amount. Their other totals don't affect whether they're listed.

| Credits to Compare | An employer is listed when... |
|---|---|
| `C` All Credits (default) | **Total Credits** (all credits, any age) ≥ Minimum Credit Amount |
| `O` Over Aged Credits | **Over Aged Credits** (at least Credit Age years old) ≥ Minimum Credit Amount |
| `U` Under Aged Credits | **Under Aged Credits** (newer than Credit Age years) ≥ Minimum Credit Amount |

For example, with a Minimum Credit Amount of `10000` and Credits to Compare `O`, an employer with $50,000.00 in Total Credits but only $6,000.00 Over Aged is **not** listed. An employer with $12,000.00 Over Aged is listed.

The same total is also used to order the list, largest first, and is shown in the **Message** column.

### How a credit's age is measured

A credit's age is counted from its deposit date. It counts as over aged once that date is on or before the same calendar date Credit Age years ago.

For example, with Credit Age 4 and a run date of 11-06-2026, a credit deposited on or before 11-06-2022 is over aged. A credit deposited after that date is under aged.

### If a value is out of range

The report doesn't fail when a value is out of range. It adjusts the value, runs, and shows the adjustment at the bottom of the report (see [Parameter lines](#parameter-lines)).

| You enter | The report uses |
|---|---|
| A Minimum Credit Amount below 1000 | 1000.00 |
| A negative Credit Age | 0 |
| A Credits to Compare letter other than C, O or U | C (All Credits) |
| A blank text box | That box's default |

---

## Sample runs

**1. Employers with $10,000 or more in credits** (all defaults)

| Text box | Type |
|---|---|
| Minimum Credit Amount ($) | *(leave blank)* |
| Credit Age (years) | *(leave blank)* |
| Credits to Compare | `C` |

Title: `Credit Report >= $10,000.00`

**2. Employers with $10,000 or more in credits that are 4 or more years old**

| Text box | Type |
|---|---|
| Minimum Credit Amount ($) | *(leave blank)* |
| Credit Age (years) | *(leave blank)* |
| Credits to Compare | `O` |

Title: `Aged Credit Report >= $10,000.00 that are >= 4 years`

**3. Employers with $25,000 or more in credits that are less than 2 years old**

| Text box | Type |
|---|---|
| Minimum Credit Amount ($) | `25000` |
| Credit Age (years) | `2` |
| Credits to Compare | `U` |

Title: `Aged Credit Report >= $25,000.00 that are < 2 years`

---

## Reading the report

The report is laid out from top to bottom like this:

1. **Title line**
2. *(blank line)*
3. **One line per employer**, largest credits first
4. *(blank line)*
5. **Total line**
6. *(blank line)*
7. **Footer line**
8. **Parameter lines**

### Title line

The first column shows the report title, which repeats your Minimum Credit Amount:

| Credits to Compare | Title (example) |
|---|---|
| `C` All Credits | `Credit Report >= $10,000.00` (age isn't used to choose employers, so the title doesn't mention it) |
| `O` Over Aged Credits | `Aged Credit Report >= $10,000.00 that are >= 4 years` |
| `U` Under Aged Credits | `Aged Credit Report >= $10,000.00 that are < 4 years` |

The **Message** column shows which total was compared to the Minimum Credit Amount:

| Credits to Compare | Message heading (example) |
|---|---|
| All Credits | `Total Credits >= $10,000.00` |
| Over Aged Credits | `Over Aged Credits (>= 4 years) >= $10,000.00` |
| Under Aged Credits | `Under Aged Credits (< 4 years) >= $10,000.00` |

### Employer lines

| Column | What it shows |
|---|---|
| **Legal Name** | The employer's legal name. |
| **Employer ID** | The employer's account number. |
| **Financing Method** | EXPERIENCERATED or BILLEDQUARTERLY. |
| **Employer Status** | ACTIVE, TERMINATED or INACTIVE. |
| **Total Credits** | All of the employer's credits, after adjustments, of any age. |
| **Over Aged Credits** | The part of Total Credits that is at least Credit Age years old. |
| **Under Aged Credits** | The part of Total Credits that is newer than Credit Age years. |
| **Message** | The amount that was compared to your Minimum Credit Amount. This matches Total, Over Aged or Under Aged Credits, depending on your Credits to Compare choice. |

Amounts are shown in dollars, e.g. `$12,345.67`. A negative amount is shown in parentheses, e.g. `($1,234.56)`. This can happen when adjustments are larger than the credit.

Over Aged Credits plus Under Aged Credits always equals Total Credits.

### Total line

The first column shows how many employers are listed, e.g. `Employers: 4`. Each amount column shows the total for all listed employers.

If no employer qualifies, the line reads `Employers: 0` with `$0.00` totals.

### Footer line

| Item | Meaning |
|---|---|
| **Source** | The database the report ran against, e.g. `DATAMART`. |
| **Run Date** | The date and time the report was run (local time), e.g. `11-06-2026 05:06 PM`. |
| **Elapsed** | How long the report took to run, as days:hours:minutes:seconds, e.g. `00:00:00:05.536`. |

### Parameter lines

One line for each Parameters text box on the report page, showing:

- **Passed:** what you entered. `(blank)` means the text box was left empty.
- **Used:** the value the report actually used.
- **Note** (last column): explains any difference.
  - `Default: ...` means the text box was blank, so the default was used.
  - `Overridden: ...` means the value you entered was changed, e.g. an amount below the minimum.
  - No note means your entry was used as is.

**Example 1: All Credits (C).** Every text box was left blank except Credits to Compare.

This run lists every employer whose total credits, of any age, are $10,000.00 or more. The blank amount and age boxes were filled in with their defaults.

| | | | | | |
|---|---|---|---|---|---|
| Minimum Credit Amount | Passed: | (blank) | Used: | $10,000.00 | Default: blank uses $10,000.00 |
| Credit Age | Passed: | (blank) | Used: | 4 | Default: blank uses 4 |
| Credits to Compare | Passed: | 'C' | Used: | C - All Credits | |

**Example 2: Over Aged Credits (O).** The amount entered was below the minimum, so it was raised.

This run lists every employer whose credits that are 4 or more years old total $1,000.00 or more. The $500.00 entered is below the $1,000.00 minimum, so the report used $1,000.00 instead.

| | | | | | |
|---|---|---|---|---|---|
| Minimum Credit Amount | Passed: | $500.00 | Used: | $1,000.00 | Overridden: below minimum $1,000.00 |
| Credit Age | Passed: | (blank) | Used: | 4 | Default: blank uses 4 |
| Credits to Compare | Passed: | 'O' | Used: | O - Over Aged Credits | |

**Example 3: Under Aged Credits (U).** Every value entered was used as is, so there are no notes.

This run lists every employer whose credits that are less than 2 years old total $25,000.00 or more. All three values were valid, so the report used them exactly as entered.

| | | | | | |
|---|---|---|---|---|---|
| Minimum Credit Amount | Passed: | $25,000.00 | Used: | $25,000.00 | |
| Credit Age | Passed: | 2 | Used: | 2 | |
| Credits to Compare | Passed: | 'U' | Used: | U - Under Aged Credits | |

On the report itself, these lines are labeled with the system names `@FilterAmount` (Minimum Credit Amount), `@FilterAge` (Credit Age) and `@ShowOverUnderAge` (Credits to Compare).

---

## Questions

**Why isn't an employer I expected on the report?**
Check the following:

- **Amount:** their compared total may be below your Minimum Credit Amount.
- **Credits to Compare:** you may have chosen Over Aged or Under Aged, and their credits are on the other side of the Credit Age.
- **Financing method:** it must be Experience Rated or Billed Quarterly.
- **Status:** it must be Active, Terminated or Inactive.

**Do Over Aged Credits and Under Aged Credits always add up to Total Credits?**
Yes. Every credit has a deposit date, so every credit is either over aged or under aged. The two columns always add up to Total Credits, on each employer line and on the total line.

**What do the parameter lines at the bottom mean?**
They're a record of how the report was run, so a printed or saved copy shows exactly which settings produced it. See [Parameter lines](#parameter-lines).
