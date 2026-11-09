CREATE PROCEDURE [dbo].[DATACALL_AgedCreditReport]
    @FilterAmount     MONEY   = NULL,
    @FilterAge        INT     = NULL,
    @ShowOverUnderAge VARCHAR(50) = NULL   -- wide so the full passed value can be reported
AS
BEGIN
    SET NOCOUNT ON;

/*
    Aged Credit Report  -  [dbo].[DATACALL_AgedCreditReport]

    Purpose
    -------
    Produces a ranked list of employers whose receipt credits meet the configured
    amount and age criteria. The report calculates original credits, adjustments,
    net credits, and separate totals for credits that are at least or less than
    the configured age threshold.

    Only employers whose current financing method is EXPERIENCERATED or
    BILLEDQUARTERLY, and whose latest enabled liability status is ACTIVE,
    TERMINATED or INACTIVE, are included.


    User instructions
    -----------------
    Type a value in each text box on the report page and click Run Report.
    Any box left blank uses its default.

        +--------------------------------------------------------------------+
        |  Aged Credit Report                                                |
        +--------------------------------------------------------------------+
        |  Minimum Credit Amount ($)  [ 10000.00     ]                       |
        |      An employer is listed only when the total chosen in Credits   |
        |      to Compare is at least this amount.                           |
        |      Digits only, decimal point optional (no $ or commas).         |
        |      Default: 10000.00     Minimum allowed: 1000.00                |
        |                                                                    |
        |  Credit Age (years)         [ 4            ]                       |
        |      Age that separates "over aged" from "under aged" credits.     |
        |      Whole number only.                                            |
        |      Default: 4            Minimum allowed: 0                      |
        |                                                                    |
        |  Credits to Compare         [ C            ]                       |
        |      Which total is compared to the Minimum Credit Amount.         |
        |      One letter only:                                              |
        |        C - All Credits: total credits, any age  (default)          |
        |        O - Over Aged Credits: at least Credit Age old              |
        |        U - Under Aged Credits: newer than Credit Age               |
        |                                                                    |
        |                                              [ Run Report ]        |
        +--------------------------------------------------------------------+

    Text box formats
        Minimum Credit Amount ($)  Digits, with an optional decimal point and
                                   up to 2 decimal places. No $ sign, commas
                                   or spaces. Valid: 10000, 10000.00, 25000.5
        Credit Age (years)         Whole number. No decimal point.
                                   Valid: 0, 2, 4
        Credits to Compare         A single letter: C, O or U (upper or lower
                                   case). Valid: C, o, U

    Field -> parameter mapping
        Minimum Credit Amount ($)  -> @FilterAmount      (blank = 10000.00; below 1000.00 is raised to 1000.00)
        Credit Age (years)         -> @FilterAge         (blank = 4; negative is treated as 0)
        Credits to Compare         -> @ShowOverUnderAge  (C = All Credits, O = Over Aged, U = Under Aged;
                                                          blank or any other letter = C)

    How the fields work together
        The total picked in Credits to Compare is the one compared to the
        Minimum Credit Amount. An employer is listed only when that total is
        at least the Minimum Credit Amount:
            All Credits (C)         Total Credits      >= Minimum Credit Amount
            Over Aged Credits (O)   Over Aged Credits  >= Minimum Credit Amount
            Under Aged Credits (U)  Under Aged Credits >= Minimum Credit Amount
        Credit Age only decides which credits count as over or under aged.

    Sample entries
        1) Employers with $10,000+ in credits (all defaults)
               Minimum Credit Amount ($)  [          ]   (blank -> 10000.00)
               Credit Age (years)         [          ]   (blank -> 4)
               Credits to Compare         [ C        ]
           Title: Credit Report >= $10,000.00
                  Message heading: Total Credits >= $10,000.00

        2) Employers with $10,000+ in credits that are 4 or more years old
               Minimum Credit Amount ($)  [          ]   (blank -> 10000.00)
               Credit Age (years)         [          ]   (blank -> 4)
               Credits to Compare         [ O        ]
           Title: Aged Credit Report >= $10,000.00 that are >= 4 years
                  Message heading: Over Aged Credits (>= 4 years) >= $10,000.00

        3) Employers with $25,000+ in credits that are less than 2 years old
               Minimum Credit Amount ($)  [ 25000    ]
               Credit Age (years)         [ 2        ]
               Credits to Compare         [ U        ]
           Title: Aged Credit Report >= $25,000.00 that are < 2 years
                  Message heading: Under Aged Credits (< 2 years) >= $25,000.00

    The report shows the title on the first row, then a blank row, then
    every qualifying employer, largest qualifying total first, then a blank
    row, a total row (employer count and column totals), a blank row, a
    footer showing the source database, run date, and elapsed time, and one
    row per parameter showing what was passed and what was used.
    The equivalent EXEC calls for these samples appear under Examples below.

    Processing overview
    -------------------
    1. Normalize the credit amount, age, and age-category parameters.
    2. Build a descriptive report title from the normalized parameters.
    3. Resolve the current local and UTC date/time values.
    4. Identify the most recently created allocation for each receipt.
    5. Load receipt credit and adjustment details into
       #EmployerCreditDetailAdjustments.
    6. Aggregate adjustments and calculate net credit amounts in
       #EmployerCreditDetails.
    7. Aggregate credit totals by employer.
    8. Keep every employer that satisfies the selected filter, ranked by
       the selected total (highest first), in #ReportRows.
    9. Keep only employers whose current financing method is
       EXPERIENCERATED or BILLEDQUARTERLY and whose latest enabled liability
       status is ACTIVE, TERMINATED or INACTIVE, in #ReportData (adds
       LegalName, FinMeth and EmployerStatus).
   10. Return the report title row, a blank row, the employer rows, a blank
       row, the report total row, a blank row, the footer row (source
       database, run date, elapsed time), then
       one row per parameter (passed value, used value, override note).

    Parameters
    ----------
    @FilterAmount
        Minimum credit amount. An employer is returned only when the total
        selected by @ShowOverUnderAge is >= @FilterAmount.
        NULL defaults to 10,000.00; values below 1,000.00 are raised to 1,000.00.

    @FilterAge
        Age threshold, in years, used to divide credits into over-age and
        under-age totals. NULL defaults to 4; negative values become 0.

    @ShowOverUnderAge
        Determines which total is compared with @FilterAmount. An employer
        is returned only when that total is >= @FilterAmount:

        'C'  NetCredit          >= @FilterAmount  (all credits, any age).  (default)
        'O'  OverAgeNetCredit   >= @FilterAmount  (credits >= @FilterAge years old).
        'U'  UnderAgeNetCredit  >= @FilterAmount  (credits <  @FilterAge years old).

        NULL or any value other than 'C', 'O' or 'U' defaults to 'C'.
        Case and surrounding spaces are ignored ('o' and ' O ' act as 'O');
        anything else, e.g. 'Over', uses 'C'. The parameter rows below the
        footer show the value passed and note when the default was used.

    Report title examples (title | Message heading on the same row)
    ---------------------
        C: Credit Report >= $10,000.00 | Total Credits >= $10,000.00
        O: Aged Credit Report >= $10,000.00 that are >= 4 years | Over Aged Credits (>= 4 years) >= $10,000.00
        U: Aged Credit Report >= $10,000.00 that are < 4 years  | Under Aged Credits (< 4 years) >= $10,000.00

    Credit calculations
    -------------------
    CreditAmount
        Original receipt allocation credit amount.

    Adjustments
        Sum of adjustment credit amounts. The column name is retained for
        compatibility with the existing report output.

    NetCredit
        CreditAmount minus Adjustments.

    OverAgeNetCredit
        Net credits for receipts whose deposit date is at least @FilterAge
        years before the current local date.

    UnderAgeNetCredit
        Net credits for receipts whose deposit date is less than @FilterAge
        years before the current local date.

    Allocation and action handling
    ------------------------------
    Every receipt has a deposit date (Receipt.DepositDate is NOT NULL in the
    database), so every credit is either over or under aged and
    OverAgeNetCredit + UnderAgeNetCredit = NetCredit.

    Only the most recently created allocation for each receipt is considered.
    Allocation recency is determined by receipt request creation date,
    receipt request ID, allocation creation date, and allocation ID.

    Adjustment records associated with a deleted action are excluded. Credits
    without an adjustment record remain eligible for reporting.

    Temporary tables
    ----------------
    #EmployerCreditDetailAdjustments
        Contains receipt-level credit, adjustment, tax-quarter, and action
        details before aggregation.

    #EmployerCreditDetails
        Contains grouped receipt allocation credits with calculated adjustment
        and net credit totals.

    #ReportRows
        Contains every employer that meets the amount filter, with its rank,
        before the financing method and liability status filters.

    #ReportData
        #ReportRows limited to employers with financing method
        EXPERIENCERATED or BILLEDQUARTERLY and latest enabled liability status
        ACTIVE, TERMINATED or INACTIVE, plus LegalName, FinMeth and
        EmployerStatus. The employer rows and the total row come from this
        table.

    Output
    ------
    Returns a single result set:

        Row 1   Report title in the first (Legal Name) column; Message heading in the
                Message column; all other columns empty.
        Row 2   Blank separator row.
        Row 3+  Every qualifying employer, highest selected total first.
        Then    Blank separator row, then a report total row:
                  Employers: <count> | <sum of each amount column> | <sum of selected total>
                (Shows "Employers: 0" and $0.00 totals when none qualify.)
        Then    Blank separator row, then a footer row:
                  Source: <DATABASE> | Run Date: | <MM-dd-yyyy hh:mm AM/PM> | ... | Elapsed: | <DD:HH:MM:SS.mmm>
                (<DATABASE> = UPPER(DB_NAME()) of the database the procedure
                runs in, e.g. DATAMART; Run Date is local time; Elapsed is
                the procedure's run time, leading 00 = whole days.)
        Then    One row per parameter, showing the value passed and the
                value used, with a note when they differ:
                  @FilterAmount | Passed: | $500.00 | Used: | $1,000.00 | ... | Overridden: below minimum $1,000.00
                (blank) = NULL was passed. "Default:" = a blank was filled
                in; "Overridden:" = a passed value was changed.

    Columns (all returned as text so the title and footer rows can share them;
    NULL values are returned as empty strings '';
    amount columns are formatted as currency, e.g. $12,345.67, negatives ($1,234.56)):

        Legal Name          (Tax_Account.Employer.LegalName; also holds the title,
                             total, footer and parameter labels)
        Employer ID
        Financing Method    (EXPERIENCERATED or BILLEDQUARTERLY)
        Employer Status     (latest enabled liability status: ACTIVE, TERMINATED or INACTIVE)
        Total Credits       (NetCredit = CreditAmount minus Adjustments; the
                             CreditAmount and Adjustments columns are not shown)
        Over Aged Credits   (OverAgeNetCredit)
        Under Aged Credits  (UnderAgeNetCredit)
        Message  Title row: the selected total vs. the threshold, e.g.
                     Over Aged Credits (>= 4 years) >= $10,000.00
                 Employer rows: that employer's selected total, e.g. $1,475,629.62

    Examples
    --------
        EXEC [dbo].[DATACALL_AgedCreditReport];                                   -- Credit Report >= $10,000.00
        EXEC [dbo].[DATACALL_AgedCreditReport] @ShowOverUnderAge = 'C';           -- Credit Report >= $10,000.00 (same as above)
        EXEC [dbo].[DATACALL_AgedCreditReport] @ShowOverUnderAge = 'O';           -- Aged Credit Report >= $10,000.00 that are >= 4 years
        EXEC [dbo].[DATACALL_AgedCreditReport] @FilterAmount = 25000,
                                      @FilterAge    = 2,
                                      @ShowOverUnderAge = 'U';           -- Aged Credit Report >= $25,000.00 that are < 2 years
*/


    -- Start time for the footer's Elapsed value.
    DECLARE @RunStart DATETIME2(7) = SYSDATETIME();

    -- Values as passed, before normalization, for the parameter rows.
    DECLARE @FilterAmountPassed     MONEY   = @FilterAmount;
    DECLARE @FilterAgePassed        INT     = @FilterAge;
    DECLARE @ShowOverUnderAgePassed VARCHAR(50) = @ShowOverUnderAge;

    ---------------------------------------------------------------------------
    -- Normalize parameters.
    ---------------------------------------------------------------------------
    IF @FilterAmount   IS NULL SET @FilterAmount = 10000.00;
    IF @FilterAmount < 1000.00 SET @FilterAmount =  1000.00;

    IF @FilterAge IS NULL SET @FilterAge = 4;
    IF @FilterAge     < 0 SET @FilterAge = 0;

    -- 'C' = all credits, 'O' = over aged, 'U' = under aged (case-insensitive,
    -- surrounding spaces ignored). NULL or any other value defaults to 'C'.
    SET @ShowOverUnderAge = UPPER(LTRIM(RTRIM(@ShowOverUnderAge)));
    IF @ShowOverUnderAge IS NULL OR @ShowOverUnderAge NOT IN ('C', 'O', 'U') SET @ShowOverUnderAge = 'C';

    ---------------------------------------------------------------------------
    -- Build the report title.
    --   C: Credit Report >= $10,000.00                       (age not used to filter)
    --   O: Aged Credit Report >= $10,000.00 that are >= 4 years
    --   U: Aged Credit Report >= $10,000.00 that are < 4 years
    ---------------------------------------------------------------------------
    DECLARE @AgeText VARCHAR(20) =
        CAST(@FilterAge AS VARCHAR(10)) + CASE WHEN @FilterAge = 1 THEN ' year' ELSE ' years' END;

    DECLARE @ReportTitle VARCHAR(200) =
        CASE @ShowOverUnderAge
            WHEN 'O' THEN 'Aged Credit Report >= ' + FORMAT(@FilterAmount, 'C', 'en-US') + ' that are >= ' + @AgeText
            WHEN 'U' THEN 'Aged Credit Report >= ' + FORMAT(@FilterAmount, 'C', 'en-US') + ' that are < '  + @AgeText
            ELSE          'Credit Report >= '      + FORMAT(@FilterAmount, 'C', 'en-US')
        END;

    ---------------------------------------------------------------------------
    -- Message column heading (title row); detail rows show the selected total.
    --   O: Over Aged Credits (>= 4 years) >= $10,000.00
    --   U: Under Aged Credits (< 4 years) >= $10,000.00
    --   C: Total Credits >= $10,000.00
    ---------------------------------------------------------------------------
    DECLARE @MessageTitle NVARCHAR(4000) =
        CASE @ShowOverUnderAge
            WHEN 'O' THEN 'Over Aged Credits (>= ' + @AgeText + ')'
            WHEN 'U' THEN 'Under Aged Credits (< ' + @AgeText + ')'
            ELSE          'Total Credits'
        END
        + ' >= ' + FORMAT(@FilterAmount, 'C', 'en-US');

    ---------------------------------------------------------------------------
    -- Recreate the temporary tables.
    ---------------------------------------------------------------------------
    DROP TABLE IF EXISTS #EmployerCreditDetailAdjustments;
    DROP TABLE IF EXISTS #EmployerCreditDetails;
    DROP TABLE IF EXISTS #ReportRows;
    DROP TABLE IF EXISTS #ReportData;



    ---------------------------------------------------------------------------
    -- Retrieve current local and UTC date/time values.
    ---------------------------------------------------------------------------
    DECLARE @LocalTimeZone        SYSNAME;
    DECLARE @CurrentDateLocal     DATE;
    DECLARE @CurrentDateTimeLocal DATETIME2;
    DECLARE @CurrentDateTimeUTC   DATETIME2;

    SELECT
        @LocalTimeZone        = [LocalTimeZone],
        @CurrentDateTimeLocal = CheckUtcToLocalDateTime,
        @CurrentDateLocal     = CAST(CheckUtcToLocalDateTime AS DATE),
        @CurrentDateTimeUTC   = CheckDateTime
    FROM [dbo].[DateTime_LocalUtcTranslate](GETUTCDATE());

    -- Deposits on or before this date are at least @FilterAge full years old.
    DECLARE @AgeCutoffDate DATE = DATEADD(YEAR, -@FilterAge, @CurrentDateLocal);

    ---------------------------------------------------------------------------
    -- Rank receipt allocations so the most recently created allocation is
    -- selected for each receipt, then load credit / adjustment details.
    ---------------------------------------------------------------------------
    ;WITH rankedAlloc AS
    (
        SELECT
            r.ReceiptID,
            r.EmployerID,
            r.DepositDate,
            rr.CreatedDate AS RequestCreatedDate,
            rr.ReceiptRequestID,
            ra.CreatedDate AS AllocationCreatedDate,
            ra.ReceiptAllocationID,

            ROW_NUMBER() OVER
            (
                PARTITION BY r.ReceiptID
                ORDER BY
                    rr.CreatedDate         DESC,
                    rr.ReceiptRequestID    DESC,
                    ra.CreatedDate         DESC,
                    ra.ReceiptAllocationID DESC
            ) AS AllocRank

        FROM Tax_dbo.Receipt                 AS r
        INNER JOIN Tax_dbo.ReceiptRequest    AS rr ON rr.ReceiptID        = r.ReceiptID
        INNER JOIN Tax_dbo.ReceiptAllocation AS ra ON ra.ReceiptRequestID = rr.ReceiptRequestID
        WHERE r.EmployerID IS NOT NULL
    )
    SELECT
        TT.*
    INTO #EmployerCreditDetailAdjustments
    FROM
    (
        SELECT
            ttReceipts.AllocRank,
            ttReceipts.EmployerID,
            ttReceipts.ReceiptID,
            ttReceipts.DepositDate,
            ttReceipts.ReceiptAllocationID,

            raCr.ReceiptAllocationCreditID,
            raCr.Amount AS CreditAmount,

            txQtr.YEAR,
            txQtr.Quarter,

            ISNULL(adjCr.Amount, 0.00) AS AdjCrAmt,
            adjCr.AdjustmentCreditID   AS AdjCrID,

            adjCr.IsFullAmount,
            adjCr.IsRemaining,

            Action.ActionID,
            Action.ReviewStatusDate AS ActionReviewStatus,
            Action.CreatedDate      AS ActionCreated,
            Action.ModifiedDate     AS ActionModified,

            ActionStatus.Code AS ActionStatus,
            Profile.ProfileID,

            -- Rank actions to identify the most recent action
            -- for each receipt allocation credit.
            ROW_NUMBER() OVER
            (
                PARTITION BY raCr.ReceiptAllocationCreditID
                ORDER BY
                    Action.CreatedDate DESC,
                    Action.ActionID    DESC
            ) AS actionRank

        FROM
        (
            -- Keep only the most recent allocation for each receipt.
            SELECT
                rankedAlloc.ReceiptID,
                rankedAlloc.EmployerID,
                rankedAlloc.DepositDate,

                rankedAlloc.RequestCreatedDate,
                rankedAlloc.ReceiptRequestID,
                rankedAlloc.AllocationCreatedDate,
                rankedAlloc.ReceiptAllocationID,
                rankedAlloc.AllocRank

            FROM rankedAlloc
            WHERE rankedAlloc.AllocRank = 1
        ) AS ttReceipts

        INNER JOIN Tax_dbo.ReceiptAllocationCredit        AS raCr         ON raCr.ReceiptAllocationID         = ttReceipts.ReceiptAllocationID

        LEFT  JOIN Tax_Account.TaxQuarter                 AS txQtr        ON txQtr.TaxQuarterID               = raCr.TaxQuarterID
        LEFT  JOIN Collections_Account.AdjustmentCredit   AS adjCr        ON adjCr.ReceiptAllocationCreditID  = raCr.ReceiptAllocationCreditID

        LEFT  JOIN Collections_Account.Action             AS Action       ON Action.ActionID                  = adjCr.ActionID
        LEFT  JOIN Collections_Configuration.ActionStatus AS ActionStatus ON ActionStatus.ActionStatusID      = Action.ActionStatusID
        LEFT  JOIN Collections_Account.Profile            AS Profile      ON Profile.ProfileID                = Action.ProfileID

        WHERE
            adjCr.AdjustmentCreditID IS NULL
            OR ActionStatus.Code <> 'DELETED'

    ) AS TT;

    ---------------------------------------------------------------------------
    -- Aggregate adjustments per receipt allocation credit.
    ---------------------------------------------------------------------------
    SELECT
        EmployerID,
        ReceiptID,
        DepositDate,

        YEAR,
        Quarter,

        CreditAmount,

        ReceiptAllocationID,
        ReceiptAllocationCreditID,
        AllocRank,
        SUM(AdjCrAmt)                AS Adjustments,
        CreditAmount - SUM(AdjCrAmt) AS NetCredit,
        CASE WHEN CreditAmount < SUM(AdjCrAmt) THEN 'Over Adjustment' ELSE '' END AS AdjustmentMessage

    INTO #EmployerCreditDetails
    FROM #EmployerCreditDetailAdjustments
    GROUP BY
        EmployerID,
        ReceiptID,
        DepositDate,
        YEAR,
        Quarter,
        CreditAmount,
        ReceiptAllocationID,
        ReceiptAllocationCreditID,
        AllocRank;

    ---------------------------------------------------------------------------
    -- Sum #EmployerCreditDetails per employer and keep every qualifying row.
    ---------------------------------------------------------------------------
    SELECT 
        ROW_NUMBER() OVER
        (
            ORDER BY
                CASE @ShowOverUnderAge
                    WHEN 'O' THEN OverAgeNetCredit
                    WHEN 'U' THEN UnderAgeNetCredit
                    ELSE          NetCredit
                END DESC,
                EmployerID
        ) AS ReportRank,

        EmployerID,
        CreditAmount,
        Adjustments,
        NetCredit,
        OverAgeNetCredit,
        UnderAgeNetCredit,

        -- The selected total; the description is on the title row.
        FORMAT(CASE @ShowOverUnderAge
                   WHEN 'O' THEN OverAgeNetCredit
                   WHEN 'U' THEN UnderAgeNetCredit
                   ELSE          NetCredit
               END, 'C', 'en-US') AS [Message]

    INTO #ReportRows
    FROM
    (
        SELECT
            EmployerID,

            SUM(CreditAmount) AS CreditAmount,
            SUM(Adjustments)  AS Adjustments,
            SUM(NetCredit)    AS NetCredit,

            -- Full years: a credit is over-aged once its deposit date is on or
            -- before the same calendar date @FilterAge years ago.
            -- Receipt.DepositDate is NOT NULL in the database, so every credit
            -- lands in one bucket: OverAgeNetCredit + UnderAgeNetCredit = NetCredit.
            SUM(CASE WHEN CAST(DepositDate AS DATE) <= @AgeCutoffDate THEN NetCredit ELSE 0.00 END) AS OverAgeNetCredit,
            SUM(CASE WHEN CAST(DepositDate AS DATE) >  @AgeCutoffDate THEN NetCredit ELSE 0.00 END) AS UnderAgeNetCredit

        FROM #EmployerCreditDetails
        GROUP BY EmployerID
    ) AS ttTEMP
    WHERE
        CASE @ShowOverUnderAge
            WHEN 'O' THEN OverAgeNetCredit
            WHEN 'U' THEN UnderAgeNetCredit
            ELSE          NetCredit
        END >= @FilterAmount
    ORDER BY
        CASE @ShowOverUnderAge
            WHEN 'O' THEN OverAgeNetCredit
            WHEN 'U' THEN UnderAgeNetCredit
            ELSE          NetCredit
        END DESC,
        EmployerID;

    ---------------------------------------------------------------------------
    -- Keep only employers with financing method EXPERIENCERATED or
    -- BILLEDQUARTERLY whose latest enabled liability status is ACTIVE,
    -- TERMINATED or INACTIVE; add legal name, financing method and status.
    ---------------------------------------------------------------------------
    SELECT
      #ReportRows.*,
      e.LegalName,
      fm.Code as FinMeth,
      ls.Code as EmployerStatus
    INTO #ReportData
    FROM #ReportRows
    JOIN Tax_Account.Employer              AS e  ON e.EmployerID         = #ReportRows.EmployerID
    JOIN Tax_Configuration.FinancingMethod AS fm ON fm.FinancingMethodID = e.CurrentFinancingMethodID 
    OUTER APPLY
            (
                SELECT TOP (1)
                     s.StatusDeterminationID
                    ,s.LiabilityStatusID
                    ,s.EffectiveDate
                    ,s.CreatedDate
                FROM Tax_Account.StatusDetermination s
                WHERE s.EmployerID = #ReportRows.EmployerID
                  AND s.IsEnabled = 1
                ORDER BY
                     s.EffectiveDate DESC
                    ,s.CreatedDate DESC
                    ,s.StatusDeterminationID DESC
            ) sd   
    JOIN Tax_Configuration.LiabilityStatus ls
                ON ls.LiabilityStatusID = sd.LiabilityStatusID
               AND ls.IsEnabled = 1
    WHERE 1=1
      AND ls.Code IN ('ACTIVE', 'TERMINATED', 'INACTIVE')
      AND fm.Code IN ('EXPERIENCERATED', 'BILLEDQUARTERLY')
    ORDER BY
        CASE @ShowOverUnderAge
            WHEN 'O' THEN OverAgeNetCredit
            WHEN 'U' THEN UnderAgeNetCredit
            ELSE          NetCredit
        END DESC,
        EmployerID;


    ---------------------------------------------------------------------------
    -- Build the footer values.
    --   Source: DATAMART | Run Date: | 11-06-2026 02:15 PM | | | Elapsed: | 00:00:00:01.234
    -- Elapsed is DD:HH:MM:SS.mmm (leading 00 = whole days).
    ---------------------------------------------------------------------------
    DECLARE @FooterSource  VARCHAR(200) = 'Source: ' + UPPER(DB_NAME());
    DECLARE @FooterRunDate VARCHAR(30)  = FORMAT(@CurrentDateTimeLocal, 'MM-dd-yyyy hh:mm tt', 'en-US');

    DECLARE @ElapsedMs BIGINT = DATEDIFF_BIG(MILLISECOND, @RunStart, SYSDATETIME());
    DECLARE @FooterElapsed VARCHAR(30) =
        RIGHT('00' + CAST(@ElapsedMs / 86400000 AS VARCHAR(10)), 2) + ':'
        + CAST(CAST(DATEADD(MILLISECOND, CAST(@ElapsedMs % 86400000 AS INT), CAST('00:00' AS TIME(3))) AS TIME(3)) AS VARCHAR(12));

    ---------------------------------------------------------------------------
    -- Build the parameter rows (one per parameter, after the footer).
    --   @FilterAmount | Passed: | $500.00 | Used: | $1,000.00 | | Overridden: below minimum $1,000.00
    -- Passed shows (blank) for NULL. Note is "Default: ..." when a blank
    -- value was filled in, "Overridden: ..." when a passed value was changed.
    ---------------------------------------------------------------------------
    DECLARE @ParamRows TABLE
    (
        ParamOrder INT,
        ParamName  VARCHAR(30),
        Passed     VARCHAR(60),
        Used       VARCHAR(50),
        Note       VARCHAR(200)
    );

    INSERT INTO @ParamRows (ParamOrder, ParamName, Passed, Used, Note)
    VALUES
    (
        1,
        '@FilterAmount',
        ISNULL(FORMAT(@FilterAmountPassed, 'C', 'en-US'), '(blank)'),
        FORMAT(@FilterAmount, 'C', 'en-US'),
        CASE
            WHEN @FilterAmountPassed IS NULL     THEN 'Default: blank uses $10,000.00'
            WHEN @FilterAmountPassed < 1000.00   THEN 'Overridden: below minimum $1,000.00'
            ELSE ''
        END
    ),
    (
        2,
        '@FilterAge',
        ISNULL(CAST(@FilterAgePassed AS VARCHAR(10)), '(blank)'),
        CAST(@FilterAge AS VARCHAR(10)),
        CASE
            WHEN @FilterAgePassed IS NULL THEN 'Default: blank uses 4'
            WHEN @FilterAgePassed < 0     THEN 'Overridden: negative treated as 0'
            ELSE ''
        END
    ),
    (
        3,
        '@ShowOverUnderAge',
        ISNULL('''' + @ShowOverUnderAgePassed + '''', '(blank)'),
        CASE @ShowOverUnderAge
            WHEN 'O' THEN 'O - Over Aged Credits'
            WHEN 'U' THEN 'U - Under Aged Credits'
            ELSE          'C - All Credits'
        END,
        CASE
            WHEN @ShowOverUnderAgePassed IS NULL
                THEN 'Default: blank uses C - All Credits'
            WHEN UPPER(LTRIM(RTRIM(@ShowOverUnderAgePassed))) NOT IN ('C', 'O', 'U')
                THEN 'Overridden: not C, O or U, uses C - All Credits'
            ELSE ''
        END
    );

    ---------------------------------------------------------------------------
    -- Return the report:
    --   Row 1   report title (in the first column)
    --   Row 2   blank separator
    --   Row 3+  employer data, ranked highest first
    --   Then    blank separator, report total row (employer count, column sums)
    --   Then    blank separator, footer row (source, run date, elapsed)
    --   Then    one row per parameter (passed, used, override note)
    -- All columns are returned as text so the title and footer can share
    -- them with the employer data.
    ---------------------------------------------------------------------------
    -- NULLs are returned as empty strings.
    SELECT
        ISNULL(rpt.[LegalName],          '') AS [Legal Name],
        ISNULL(rpt.[EmployerID],         '') AS [Employer ID],
        ISNULL(rpt.[FinMeth],            '') AS [Financing Method],
        ISNULL(rpt.[EmployerStatus],     '') AS [Employer Status],
        ISNULL(rpt.[NetCredit],          '') AS [Total Credits],
        ISNULL(rpt.[OverAgeNetCredit],   '') AS [Over Aged Credits],
        ISNULL(rpt.[UnderAgeNetCredit],  '') AS [Under Aged Credits],
        ISNULL(rpt.[Message],            '') AS [Message]
    FROM
    (
        -- Title row.
        SELECT
            1                           AS RowGroup,
            0                           AS ReportRank,
            CAST(@ReportTitle AS NVARCHAR(400)) AS [LegalName],   -- first column also holds title / labels
            CAST(NULL AS VARCHAR(200))  AS [EmployerID],
            CAST(NULL AS VARCHAR(100))  AS [FinMeth],
            CAST(NULL AS VARCHAR(100))  AS [EmployerStatus],
            CAST(NULL AS VARCHAR(30))   AS [NetCredit],
            CAST(NULL AS VARCHAR(30))   AS [OverAgeNetCredit],
            CAST(NULL AS VARCHAR(30))   AS [UnderAgeNetCredit],
            @MessageTitle               AS [Message]

        UNION ALL

        -- Blank separator row.
        SELECT 2, 0, '', NULL, NULL, NULL, NULL, NULL, NULL, ''

        UNION ALL

        -- Employer data rows.
        SELECT
            3,
            ReportRank,
            LegalName,
            CAST(EmployerID AS VARCHAR(200)),
            FinMeth,
            EmployerStatus,
            FORMAT(NetCredit,         'C', 'en-US'),
            FORMAT(OverAgeNetCredit,  'C', 'en-US'),
            FORMAT(UnderAgeNetCredit, 'C', 'en-US'),
            [Message]
        FROM #ReportData

        UNION ALL

        -- Blank separator row.
        SELECT 4, 0, '', NULL, NULL, NULL, NULL, NULL, NULL, ''

        UNION ALL

        -- Report total row: employer count and the sum of each amount column.
        -- (An aggregate with no GROUP BY always returns one row, so this shows
        -- "Employers: 0" and $0.00 totals when no employer qualifies.)
        SELECT
            5,
            0,
            'Employers: ' + CAST(COUNT(*) AS VARCHAR(10)),
            NULL,
            NULL,
            NULL,
            FORMAT(ISNULL(SUM(NetCredit),         0), 'C', 'en-US'),
            FORMAT(ISNULL(SUM(OverAgeNetCredit),  0), 'C', 'en-US'),
            FORMAT(ISNULL(SUM(UnderAgeNetCredit), 0), 'C', 'en-US'),
            FORMAT(ISNULL(SUM(CASE @ShowOverUnderAge
                                  WHEN 'O' THEN OverAgeNetCredit
                                  WHEN 'U' THEN UnderAgeNetCredit
                                  ELSE          NetCredit
                              END), 0), 'C', 'en-US')
        FROM #ReportData

        UNION ALL

        -- Blank separator row.
        SELECT 6, 0, '', NULL, NULL, NULL, NULL, NULL, NULL, ''

        UNION ALL

        -- Footer row (labels and values sit left; Elapsed stays at the right).
        SELECT
            7,
            0,
            @FooterSource,
            'Run Date:',
            @FooterRunDate,
            NULL,
            NULL,
            NULL,
            'Elapsed:',
            @FooterElapsed

        UNION ALL

        -- Parameter rows: what was passed, what was used, and why it changed.
        SELECT
            8,
            ParamOrder,
            ParamName,
            'Passed:',
            Passed,
            'Used:',
            Used,
            NULL,
            NULL,
            Note
        FROM @ParamRows
    ) AS rpt
    ORDER BY
        rpt.RowGroup,
        rpt.ReportRank;
END;
GO
