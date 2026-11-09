


/* =====================================================================================================
   PROCEDURE : dbo.DATACALL_Ledger_FundActivity
   DATABASE  : Datamart

   PURPOSE
       Returns a formatted, ready-to-display Fund Activity report (one result set) for the fund
       accounts listed in #FundAccounts. Every cell is returned as text: amounts are already
       formatted as currency, and the report includes its own title, blank spacer rows, total
       rows and a run-info footer. The consumer displays or exports the rows in the order returned.

   PARAMETERS
       @ParamDate    DATE     Any date inside the period to report on.
                              NULL = yesterday, in the server's local time zone.
       @ParamPeriod  CHAR(1)  'F' = Fiscal year   (default; also used for NULL or any unknown value)
                              'Q' = Fiscal quarter
                              'M' = Calendar month
                              Case-insensitive ('m' = 'M').
       @BypassTotal  BIT      0 = include total rows (default; NULL is treated as 0)
                              1 = omit total rows (and the blank row that goes with each)

   REPORTS
       Fiscal  (F) : grid. Rows = account measures; columns = FY Q1..Q4 + FY Total.
       Quarter (Q) : grid. Rows = account measures; columns = the 3 months of the fiscal quarter + Quarter Total.
       Month   (M) : list. One row per account per day (with day totals), then one row per account
                     for the whole month (with a month TOTAL).
       Every report starts with a title row and a blank row, and ends with a footer row:
           Source: <DATABASE> | Run Date: | <MM-dd-yyyy hh:mm AM/PM> | ... | Elapsed: | <00:HH:MM:SS.mmm>
           (<DATABASE> = UPPER(DB_NAME()) of the database the procedure runs in, e.g. DATAMART)

   MEASURES (from Tax_dbo.LedgerDailyAccountRunningBalance, one row per account per day)
       Prior Balance, Running Balance : point-in-time. For a period, Prior Balance is taken from the
                                        first day in the period that has data, Running Balance from the last.
       New, Existing, Disbursements,
       Net Movement                   : flows. Summed over the period.
       Prior / Running Balance are shown only for accounts with ShowBalance = 1, and Disbursements only
       for accounts with ShowDisbursement = 1 (see #FundAccounts). Hidden measures have no line on the
       grid reports and print blank on the Month report; they are never included in totals.

   ERROR HANDLING (intentional - do not change to THROW)
       Errors are NOT re-raised. The CATCH block returns a two-column result set (Variable, Value) with
       the procedure name, the @Step that failed, the parameters and the error details. The consumer
       recognises an error by that result set's shape and handles it. Errors this procedure raises itself:
           50001  Local time zone could not be resolved.
           50002  Grid report SQL could not be built (would otherwise return nothing silently).

   DEPENDENCIES
       Tax_dbo.LedgerDailyAccountRunningBalance   source data (populated nightly by
                                                  Tax_dbo.Ledger_NightlyDailyAccountRunningBalance)
       dbo.DateTime_LocalUtcTranslate             returns the server's local time zone name

   HOW THE CODE IS ORGANISED
       Declarations    : every variable and named constant, with no logic that can fail.
       Setup           : #FundAccounts, local time, parameter defaults, fiscal calendar, report window.
       Phase 1 - Load  : #Daily (all reports), then for grid reports #Cols -> #AcctCol -> #Lines.
       Phase 2 - Time  : elapsed time for the footer (measured here, so it excludes the final SELECT).
       Phase 3 - Output: grid reports via dynamic SQL (column names depend on the period),
                         Month report via a static SELECT.

   COMMON CHANGES
       Add / remove / reorder an account : edit the #FundAccounts VALUES list (FundOrder sets the order).
       Change the fiscal year start      : @FiscalYearStartMonth (must be 2-12; see the note there).
       Change the money format           : @MoneyFormat / @MoneyCulture (used by every report).
       Change the footer text            : @FooterSource / @FooterRunDate / @FooterElapsed.
       Change row order / spacing        : the @Sec_*, @Row_* and @Line_* constants.

   EXAMPLES
       EXEC dbo.DATACALL_Ledger_FundActivity;                                   -- current fiscal year to date
       EXEC dbo.DATACALL_Ledger_FundActivity @ParamDate = '2026-01-15', @ParamPeriod = 'Q';
       EXEC dbo.DATACALL_Ledger_FundActivity @ParamDate = '2025-11-30', @ParamPeriod = 'M', @BypassTotal = 1;
   ===================================================================================================== */
--CREATE PROCEDURE [dbo].[DATACALL_Ledger_FundActivity]
--(
--   @ParamDate             DATE      = NULL,   -- any date in the period to report; NULL = yesterday (local time)
--   @ParamPeriod           CHAR(1)   = NULL,   -- 'F' fiscal year (default), 'Q' fiscal quarter, 'M' calendar month
--   @BypassTotal           BIT       = 0       -- 1 = Report omits total lines (all report types)
--)
--AS
BEGIN
    SET NOCOUNT ON;     -- no "n rows affected" messages; the consumer expects only the report result set
    SET XACT_ABORT ON;  -- any run-time error goes straight to CATCH and dooms an open transaction,
                        -- instead of continuing with the next statement

   -- Testing
   DECLARE @ParamDate             DATE      = NULL;   -- any date in the period to report; NULL = yesterday (local time)
   DECLARE @ParamPeriod           CHAR(1)   = NULL;   -- 'F' fiscal year (default), 'Q' fiscal quarter, 'M' calendar month
   DECLARE @BypassTotal           BIT       = 0;       -- 1 = Report omits total lines (all report types)

   -- Testing
   -- Drop any leftover temp tables (e.g. from an earlier run of the test script in the same session)
   DROP TABLE IF EXISTS #FundAccounts;
   DROP TABLE IF EXISTS #Daily;
   DROP TABLE IF EXISTS #Cols;
   DROP TABLE IF EXISTS #AcctCol;
   DROP TABLE IF EXISTS #Lines;


    -- =================================================================================================
    -- DECLARATIONS
    -- No logic that can fail here: all values that depend on data or parameters are set inside TRY,
    -- so any failure is reported through the CATCH result set.
    -- =================================================================================================
    DECLARE @Step               varchar(100) = 'Initialize';   -- name of the current step; reported by CATCH.
                                                                -- Set @Step at the start of every new step.

    DECLARE @LocalTimeZone      sysname;                        -- e.g. 'Eastern Standard Time'
    DECLARE @DateTimeLocal      datetime2;                      -- "now" in local time
    DECLARE @DateTimeLocalPrint varchar(30);                    -- "now" formatted for the Run Date footer

    -- Valid @ParamPeriod codes
    DECLARE @ParamPeriod_Fiscal   CHAR(1) = 'F'; -- Fiscal year
    DECLARE @ParamPeriod_Quarter  CHAR(1) = 'Q'; -- Fiscal quarter
    DECLARE @ParamPeriod_Month    CHAR(1) = 'M'; -- Calendar month

    -- Elapsed-time tracking for the report footer
    DECLARE @StartTime  DATETIME2(3) = SYSDATETIME();
    DECLARE @ElapsedStr VARCHAR(20);                            -- DD:HH:MM:SS.mmm (DD is always 00; runs are < 24h)

    -- First month of the fiscal year (10 = October, so Oct 2025 - Sep 2026 is FY 2026).
    -- Must be 2-12: the fiscal year is named by the calendar year it ENDS in, and the formula used for
    -- that (see "Fiscal / quarter calendar values") would mislabel the year if the FY started in January.
    DECLARE @FiscalYearStartMonth int = 10;

    -- Run info footer text (all reports): Source | Run Date: | <date> | ... | Elapsed: | <elapsed>
    -- @FooterSource names the database the procedure runs in (e.g. 'Source: DATAMART'), uppercased to
    -- match the original fixed text. nvarchar(140) = 'Source: ' + the longest database name (128).
    DECLARE @FooterSource   nvarchar(140) = N'Source: ' + UPPER(DB_NAME());
    DECLARE @FooterRunDate  nvarchar(30) = N'Run Date:';
    DECLARE @FooterElapsed  nvarchar(30) = N'Elapsed:';

    -- Money format for every amount cell on every report (.NET format string + culture used by FORMAT())
    DECLARE @MoneyFormat  nvarchar(10) = N'C';
    DECLARE @MoneyCulture nvarchar(10) = N'en-US';

    -- -------------------------------------------------------------------------------------------------
    -- Named sort / layout constants
    -- The report is returned as an ordered list of rows. Each row carries a section (Sec) and a row or
    -- line number within that section; the final ORDER BY uses them. Only the relative order of the
    -- values matters, so they can be renumbered freely as long as the order is kept.
    -- -------------------------------------------------------------------------------------------------
    -- Report sections (all reports): header, then detail, then month summary (Month only), then footer
    DECLARE @Sec_Header   int = 0;
    DECLARE @Sec_Detail   int = 1;
    DECLARE @Sec_Summary  int = 2;
    DECLARE @Sec_Footer   int = 3;

    -- Header rows (all reports)
    DECLARE @Row_Title       int = 0;   -- 'Fiscal Fund Activity 2026' etc.
    DECLARE @Row_TitleBlank  int = 1;   -- blank line under the title

    -- Footer rows (all reports)
    DECLARE @Row_Footer      int = 0;   -- run info line (Source / Run Date / Elapsed)

    -- Fiscal / Quarter: measure lines within each account block (display order)
    DECLARE @Line_PriorBalance   int = 1;
    DECLARE @Line_New            int = 2;
    DECLARE @Line_Existing       int = 3;
    DECLARE @Line_Disbursement   int = 4;
    DECLARE @Line_NetMovement    int = 5;
    DECLARE @Line_RunningBalance int = 6;
    DECLARE @Line_Spacer         int = 99;  -- blank line after each account block (must sort after every measure)

    -- Fiscal / Quarter: total column and TOTAL block sort keys
    DECLARE @Col_Total      int = 999;          -- ColOrder of the period-total column (after every period column)
    DECLARE @TotalFundOrder int = 2147483647;   -- FundOrder of the TOTAL block (int max: after every account)

    -- Month: rows within each day (Sec_Detail; rows are grouped by date first)
    DECLARE @Row_DayAccount      int = 0;   -- one row per account
    DECLARE @Row_DayBlankBefore  int = 1;   -- blank above the day total (dropped when bypassing totals)
    DECLARE @Row_DayTotal        int = 2;   -- 'YYYY-MM-DD Total'
    DECLARE @Row_DayBlankAfter   int = 3;   -- blank after the day (always kept, so days stay separated)

    -- Month: rows within the month summary (Sec_Summary)
    DECLARE @Row_SumBlankTop         int = 0;   -- separator from the daily section
    DECLARE @Row_SumAccount          int = 1;   -- one row per account for the month
    DECLARE @Row_SumBlankBeforeTotal int = 2;   -- blank above the month TOTAL (dropped when bypassing totals)
    DECLARE @Row_SumTotal            int = 3;   -- month TOTAL
    DECLARE @Row_SumBlankEnd1        int = 4;   -- two blank lines before the footer
    DECLARE @Row_SumBlankEnd2        int = 5;

    -- -------------------------------------------------------------------------------------------------
    -- Fiscal calendar values derived from @ParamDate
    -- -------------------------------------------------------------------------------------------------
    DECLARE @reportFiscalYear INT;                              -- FY number (FY is named by the year it ends in)
    DECLARE @ReportFY_YYYY    varchar(4);                       -- same, as text for headers
    DECLARE @fiscalStart      DATE;                             -- first day of the fiscal year
    DECLARE @monthsIntoFY     int;                              -- 0-11, months since @fiscalStart
    DECLARE @QuarterIdx       int;                              -- fiscal quarter 1-4
    DECLARE @QuarterStart     DATE;                             -- first day of the fiscal quarter
    DECLARE @QuarterTitle     nvarchar(20);                     -- e.g. 'FY 2026-Q2'

    -- Report date window [@reportStart, @reportEnd) - start is inclusive, end is exclusive
    DECLARE @reportStart  DATE;
    DECLARE @reportEnd    DATE;

    -- Report title line (first row of every report)
    DECLARE @ReportHeader nvarchar(100);                        -- e.g. 'Fiscal Fund Activity 2026'

    -- Fiscal / Quarter grid layout (NULL for the Month report)
    DECLARE @ColCount     int;                                  -- period columns: 4 quarters (Fiscal) or 3 months (Quarter); max 4 (see #Cols)
    DECLARE @ColMonths    int;                                  -- months per period column: 3 (Fiscal) or 1 (Quarter)
    DECLARE @GridTitle    nvarchar(50);                         -- first column header: 'Fiscal 2026' / 'FY 2026-Q2'
    DECLARE @TotalColName nvarchar(50);                         -- last column header:  'FY 2026 Total' / 'FY 2026-Q2 Total'
    DECLARE @cols nvarchar(max), @colNames nvarchar(max), @sql nvarchar(max);   -- dynamic SQL pieces (Phase 3)
    DECLARE @BlankCells nvarchar(max), @FooterGap nvarchar(max);               -- blank-cell padding (Phase 3)

    -- Month report (NULL for the grid reports)
    DECLARE @MonthLabel   varchar(10);                          -- e.g. 2025-NOV

    -- =================================================================================================

    BEGIN TRY

        -- =============================================================================================
        -- FUND ACCOUNTS ON THE REPORT
        -- To add, remove or reorder an account, edit this list.
        --     AccountCode      : Tax_dbo.LedgerDailyAccountRunningBalance.Account
        --     Description      : shown after the code, e.g. '53A: ESA'
        --     FundOrder        : display order (ascending); keep values unique
        --     ShowBalance      : 1 = show Prior Balance / Running Balance
        --     ShowDisbursement : 1 = show Disbursements
        -- =============================================================================================
        CREATE TABLE #FundAccounts
        (
            AccountCode       varchar(10)  NOT NULL,
            Description       nvarchar(30) NOT NULL,
            FundOrder         int          NOT NULL,   -- display order of the account
            ShowBalance       bit          NOT NULL,   -- 1 = report shows Prior Balance / Running Balance for this account
            ShowDisbursement  bit          NOT NULL    -- 1 = report shows Disbursements for this account
        );

        INSERT INTO #FundAccounts (AccountCode, Description, FundOrder, ShowBalance, ShowDisbursement)
        VALUES
            --('7',   N'Clearing - Regions Bank', 99,  0, 0),   -- excluded from the report
            ('52',  N'Accts Payable',            100, 1, 0),
            ('42',  N'UC Contr',                 200, 0, 0),
            ('42A', N'UC Contr:AR',              300, 0, 0),
            ('42B', N'UC Contr:LR',              400, 0, 0),
            ('42C', N'UC Contr:NR',              500, 0, 0),
            ('50A', N'Pen & Int',                600, 1, 1),
            ('53A', N'ESA',                      700, 1, 1),
            ('5',   N'NSF',                      800, 0, 0);

        -- =============================================================================================
        -- LOCAL TIME
        -- "Now" in the server's local time zone: used for the Run Date footer and the @ParamDate default.
        -- =============================================================================================
        SET @Step = 'Resolve local time zone';

        SELECT @LocalTimeZone = LocalTimeZone FROM dbo.DateTime_LocalUtcTranslate(GETDATE());

        IF @LocalTimeZone IS NULL
            THROW 50001, 'Could not resolve local time zone from dbo.DateTime_LocalUtcTranslate.', 1;

        -- AT TIME ZONE returns datetimeoffset; assigning it to datetime2 keeps the local clock time
        SET @DateTimeLocal      = GETUTCDATE() AT TIME ZONE 'UTC' AT TIME ZONE @LocalTimeZone;
        SET @DateTimeLocalPrint = FORMAT(@DateTimeLocal, 'MM-dd-yyyy hh:mm tt');

        -- =============================================================================================
        -- PARAMETERS
        -- Defaults are applied silently (no error) so the procedure always returns a report.
        -- =============================================================================================
        SET @Step = 'Validate parameters';

        IF @ParamDate   IS NULL SET @ParamDate = DATEADD(DAY, -1, @DateTimeLocal);   -- yesterday (local)

        SET @ParamPeriod = UPPER(@ParamPeriod);       -- 'm' works the same as 'M', whatever the collation

        IF @ParamPeriod IS NULL OR @ParamPeriod NOT IN (@ParamPeriod_Fiscal, @ParamPeriod_Quarter, @ParamPeriod_Month)
            SET @ParamPeriod = @ParamPeriod_Fiscal;   -- NULL or unknown code -> Fiscal

        SET @BypassTotal = ISNULL(@BypassTotal, 0);   -- an explicit NULL means "show totals"

        -- =============================================================================================
        -- FISCAL / QUARTER CALENDAR VALUES
        -- Calculated for every report (cheap); the Month report only uses @reportStart / @reportEnd.
        -- =============================================================================================
        SET @Step = 'Calculate fiscal calendar';

        -- Fiscal year is named by the calendar year it ends in (Oct 2025 -> FY 2026)
        SET @reportFiscalYear =
            CASE WHEN MONTH(@ParamDate) >= @FiscalYearStartMonth THEN YEAR(@ParamDate) + 1 ELSE YEAR(@ParamDate) END;
        SET @ReportFY_YYYY = CAST(@reportFiscalYear AS varchar(4));

        SET @fiscalStart  = DATEFROMPARTS(@reportFiscalYear - 1, @FiscalYearStartMonth, 1);
        SET @monthsIntoFY = (MONTH(@ParamDate) - @FiscalYearStartMonth + 12) % 12;  -- +12 keeps it non-negative
        SET @QuarterIdx   = @monthsIntoFY / 3 + 1;                         -- 1-4
        SET @QuarterStart = DATEADD(MONTH, (@QuarterIdx - 1) * 3, @fiscalStart);
        SET @QuarterTitle = N'FY ' + @ReportFY_YYYY + N'-Q' + CAST(@QuarterIdx AS nvarchar(1));

        -- Report window, title, and (Fiscal / Quarter only) the grid layout
        IF @ParamPeriod = @ParamPeriod_Fiscal
        BEGIN
            SET @reportStart  = @fiscalStart;
            SET @reportEnd    = DATEADD(YEAR, 1, @reportStart);
            SET @ColCount     = 4;                                         -- Q1..Q4
            SET @ColMonths    = 3;
            SET @GridTitle    = N'Fiscal ' + @ReportFY_YYYY;
            SET @TotalColName = N'FY ' + @ReportFY_YYYY + N' Total';
            SET @ReportHeader = N'Fiscal Fund Activity ' + @ReportFY_YYYY;                                  -- Fiscal Fund Activity 2026
        END
        ELSE IF @ParamPeriod = @ParamPeriod_Quarter
        BEGIN
            SET @reportStart  = @QuarterStart;
            SET @reportEnd    = DATEADD(MONTH, 3, @reportStart);
            SET @ColCount     = 3;                                         -- the three months of the quarter
            SET @ColMonths    = 1;
            SET @GridTitle    = @QuarterTitle;
            SET @TotalColName = @QuarterTitle + N' Total';
            SET @ReportHeader = N'Quarterly Fund Activity ' + @ReportFY_YYYY + N'-Q' + CAST(@QuarterIdx AS nvarchar(1)); -- Quarterly Fund Activity 2026-Q1
        END
        ELSE -- Month (calendar month, not fiscal)
        BEGIN
            SET @reportStart  = DATEFROMPARTS(YEAR(@ParamDate), MONTH(@ParamDate), 1);
            SET @reportEnd    = DATEADD(MONTH, 1, @reportStart);
            SET @MonthLabel   = UPPER(FORMAT(@reportStart, 'yyyy-MMM', 'en-US'));                         -- 2026-JAN (same case as the grid month columns)
            SET @ReportHeader = N'Monthly Fund Activity ' + @MonthLabel;                                     -- Monthly Fund Activity 2026-JAN
        END

        -- =============================================================================================
        -- PHASE 1: LOAD DATA
        -- =============================================================================================

        -- ---------------------------------------------------------------------------------------------
        -- #Daily: one row per account per day in the report window (all reports read this table)
        --
        -- ASSUMPTION: the source has at most one row per (Account, AsOfDate). The balance logic picks
        -- "the row on the first / last date"; duplicate rows on those dates would be summed.
        --
        -- Show rules are applied here, once, for every report:
        --     Prior Balance / Running Balance only for #FundAccounts.ShowBalance = 1      (52, 50A, 53A)
        --     Disbursements                   only for #FundAccounts.ShowDisbursement = 1 (50A, 53A)
        -- A hidden measure is NULL; every shown measure is ISNULL'd to 0, so NULL always means "hidden".
        -- Later steps rely on that:
        --     Grid  : NULL measures produce no report line
        --     Month : NULL cells print blank and SUM() leaves them out of the totals
        -- ---------------------------------------------------------------------------------------------
        SET @Step = 'Load daily detail';

        SELECT
            l.AsOfDate,
            Account          = fa.AccountCode,
            AccountDisplay   = CAST(l.Account + ': ' + fa.Description AS nvarchar(50)),   -- e.g. '53A: ESA'
            fa.FundOrder,
            PriorBalance     = CASE WHEN fa.ShowBalance = 1
                                    THEN CAST(ISNULL(l.PriorBalance,   0) AS decimal(19,2)) END,
            RcptsAmtNew      = CAST(ISNULL(l.RcptsAmtNew,      0) AS decimal(19,2)),
            RcptsAmtExisting = CAST(ISNULL(l.RcptsAmtExisting, 0) AS decimal(19,2)),
            Disbursements    = CASE WHEN fa.ShowDisbursement = 1
                                    THEN CAST(ISNULL(l.Disbursements,  0) AS decimal(19,2)) END,
            NetMovement      = CAST(ISNULL(l.NetMovement,      0) AS decimal(19,2)),
            RunningBalance   = CASE WHEN fa.ShowBalance = 1
                                    THEN CAST(ISNULL(l.RunningBalance, 0) AS decimal(19,2)) END
        INTO #Daily
        FROM Tax_dbo.LedgerDailyAccountRunningBalance l
        JOIN #FundAccounts fa ON fa.AccountCode = l.Account
        WHERE l.AsOfDate >= @reportStart
          AND l.AsOfDate <  @reportEnd;

        -- ---------------------------------------------------------------------------------------------
        -- FISCAL / QUARTER (grid) REPORT - build the report lines
        --     Fiscal  : columns = Q1..Q4 of the fiscal year containing @ParamDate + FY Total
        --     Quarter : columns = the 3 months of the fiscal quarter containing @ParamDate + Quarter Total
        --     Header  : '<Fiscal|Quarterly> Fund Activity ...', blank
        --     Lines   : per account (in FundOrder) - [Prior Balance], New, Existing, [Disbursement],
        --               Net Movement, [Running Balance], blank;
        --               then report totals (New - Total, Existing - Total, Net Movement - Total,
        --               summed across all accounts), blank;
        --               run info footer
        --               (hidden measures - see the show rules above #Daily - have no line)
        --     @BypassTotal = 1 omits the report totals (and the blank line after them)
        --     Balances: Prior Balance = first day with data in the column, Running Balance = last day;
        --               flows (New / Existing / Disbursement / Net Movement) are summed
        --
        -- Pipeline:  #Cols (columns)  ->  #AcctCol (account x column)  ->  #Lines (account x column x measure)
        -- #Lines stays "long" (one row per cell); Phase 3 pivots it into the column layout.
        -- ---------------------------------------------------------------------------------------------
        IF @ParamPeriod IN (@ParamPeriod_Fiscal, @ParamPeriod_Quarter)
        BEGIN
            /* ---------- 1. Report columns: one per period + the total column ---------- */
            SET @Step = 'Build report columns';

            -- Columns come from the calendar (not from the data), so every column appears
            -- even when a period has no rows yet (e.g. future quarters of the current fiscal year).
            -- LIMIT: the VALUES list below supplies at most 4 period columns (n = 0..3).
            --        A layout with @ColCount > 4 must add more rows here, or its extra columns are silently dropped.
            SELECT ColOrder  = n.n,
                   ColName   = CAST(CASE WHEN @ParamPeriod = @ParamPeriod_Fiscal
                                         THEN N'FY ' + @ReportFY_YYYY + N'-Q' + CAST(n.n + 1 AS nvarchar(1))       -- FY 2026-Q1
                                         ELSE UPPER(FORMAT(DATEADD(MONTH, n.n * @ColMonths, @reportStart), 'yyyy-MMM', 'en-US')) -- 2025-OCT
                                    END AS nvarchar(50)),
                   StartDate = DATEADD(MONTH,  n.n      * @ColMonths, @reportStart),   -- inclusive
                   EndDate   = DATEADD(MONTH, (n.n + 1) * @ColMonths, @reportStart)    -- exclusive
            INTO #Cols
            FROM (VALUES (0), (1), (2), (3)) n(n)
            WHERE n.n < @ColCount
            UNION ALL
            -- Total column spans the whole report window
            SELECT @Col_Total, @TotalColName, @reportStart, @reportEnd;

            /* ---------- 2. Roll up to account x column ---------- */
            -- Each day matches two columns (its period and the total), so the total column
            -- is aggregated by exactly the same rules as the period columns.
            SET @Step = 'Aggregate columns';

            -- Same pattern as the month report: first / last day per account and column, then conditional SUM
            ;WITH d AS (
                SELECT r.*, c.ColOrder,
                       AcctFirstDate = MIN(r.AsOfDate) OVER (PARTITION BY r.Account, c.ColOrder),
                       AcctLastDate  = MAX(r.AsOfDate) OVER (PARTITION BY r.Account, c.ColOrder)
                FROM #Daily r
                JOIN #Cols  c ON r.AsOfDate >= c.StartDate AND r.AsOfDate < c.EndDate
            )
            -- Balances are point-in-time (first / last day of the column), flows are summed.
            -- Hidden measures stay NULL here because SUM of only NULLs is NULL.
            SELECT FundOrder, Account, AccountDisplay, ColOrder,
                   PriorBalance     = SUM(CASE WHEN AsOfDate = AcctFirstDate THEN PriorBalance   END),
                   RcptsAmtNew      = SUM(RcptsAmtNew),
                   RcptsAmtExisting = SUM(RcptsAmtExisting),
                   Disbursements    = SUM(Disbursements),
                   NetMovement      = SUM(NetMovement),
                   RunningBalance   = SUM(CASE WHEN AsOfDate = AcctLastDate  THEN RunningBalance END)
            INTO #AcctCol
            FROM d
            GROUP BY FundOrder, Account, AccountDisplay, ColOrder;

            /* ---------- 3. Unpivot measures into report lines (one row per account x column x measure) ---------- */
            -- To add a measure: add a @Line_* constant, a column to #Daily / #AcctCol, and a row to this VALUES list.
            SET @Step = 'Build report lines';

            SELECT a.FundOrder, a.Account, a.ColOrder, v.LineOrder, v.Measure,
                   LineLabel = a.AccountDisplay + N' - ' + v.Measure,          -- e.g. '53A: ESA - New'
                   v.Amount
            INTO #Lines
            FROM #AcctCol a
            CROSS APPLY (VALUES
                (@Line_PriorBalance,   N'Prior Balance',   a.PriorBalance),
                (@Line_New,            N'New',             a.RcptsAmtNew),
                (@Line_Existing,       N'Existing',        a.RcptsAmtExisting),
                (@Line_Disbursement,   N'Disbursement',    a.Disbursements),
                (@Line_NetMovement,    N'Net Movement',    a.NetMovement),
                (@Line_RunningBalance, N'Running Balance', a.RunningBalance)
            ) v(LineOrder, Measure, Amount)
            WHERE v.Amount IS NOT NULL      -- NULL = measure hidden for this account (show rules on #Daily)
            UNION ALL
            -- blank spacer line after each account block (ColOrder 0 is arbitrary: the Amount is NULL)
            SELECT DISTINCT FundOrder, Account, 0, @Line_Spacer, N'', N'', NULL
            FROM #AcctCol;

            /* ---------- 3b. Report totals: New, Existing, Net Movement summed across all accounts ---------- */
            -- Balances and Disbursements are not totalled: they are only shown for some accounts.
            IF @BypassTotal = 0
            BEGIN
                SET @Step = 'Build total lines';

                INSERT #Lines (FundOrder, Account, ColOrder, LineOrder, Measure, LineLabel, Amount)
                SELECT @TotalFundOrder, 'TOTAL', l.ColOrder, l.LineOrder, l.Measure,
                       l.Measure + N' - Total',         -- e.g. 'New - Total'
                       SUM(l.Amount)
                FROM #Lines l
                WHERE l.LineOrder IN (@Line_New, @Line_Existing, @Line_NetMovement)
                GROUP BY l.ColOrder, l.LineOrder, l.Measure
                UNION ALL
                -- blank spacer line after the TOTAL block
                SELECT @TotalFundOrder, 'TOTAL', 0, @Line_Spacer, N'', N'', NULL;
            END
        END

        -- (Month report needs no further loading: it reads #Daily directly in Phase 3.)

        -- =============================================================================================
        -- PHASE 2: ELAPSED TIME (DD:HH:MM:SS.mmm) for the footer - all data work is done.
        -- Measured before the final SELECT, so it does not include the output formatting time.
        -- Style 114 gives hh:mi:ss:mmm; STUFF swaps the last ':' for '.'. The day part is always 00.
        -- =============================================================================================
        SET @Step = 'Calculate elapsed time';

        SET @ElapsedStr = '00:' + STUFF(CONVERT(varchar(12),
                              DATEADD(MILLISECOND, DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()), CAST('00:00' AS time(3))),
                              114), 9, 1, '.');

        -- =============================================================================================
        -- PHASE 3: RETURN REPORT (exactly one result set)
        -- =============================================================================================
        IF @ParamPeriod IN (@ParamPeriod_Fiscal, @ParamPeriod_Quarter)
        BEGIN
            -- -----------------------------------------------------------------------------------------
            -- GRID OUTPUT: pivot #Lines into columns, add header and footer rows.
            -- Dynamic SQL is needed because the column names depend on the period
            -- (e.g. [FY 2026-Q1] or [2025-OCT]). Everything that is a value (title, footer text,
            -- formats, sort constants) is passed as a parameter, not concatenated into the string;
            -- only column names (via QUOTENAME) and blank-cell padding are built into the SQL text.
            --
            -- Output columns: <GridTitle> | <period columns...> | <TotalColName>
            -- -----------------------------------------------------------------------------------------
            SET @Step = 'Return grid report';

            -- One formatted, pivoted column per #Cols row, in column order:
            --     ISNULL(FORMAT(SUM(CASE WHEN l.ColOrder = <n> THEN l.Amount END), @MoneyFormat, @MoneyCulture), N'') AS [<name>]
            SELECT
                @cols = STRING_AGG(CAST(
                           N'ISNULL(FORMAT(SUM(CASE WHEN l.ColOrder = ' + CAST(c.ColOrder AS nvarchar(10)) +
                           N' THEN l.Amount END), @MoneyFormat, @MoneyCulture), N'''') AS ' +
                           QUOTENAME(c.ColName)
                        AS nvarchar(max)), N',' + CHAR(10)) WITHIN GROUP (ORDER BY c.ColOrder),
                @colNames = STRING_AGG(CAST(QUOTENAME(c.ColName) AS nvarchar(max)), N', ')
                            WITHIN GROUP (ORDER BY c.ColOrder)
            FROM #Cols c;

            -- Every UNION branch below must return the same number of columns:
            --     4 sort columns + the label column + (@ColCount + 1) data columns.
            -- Blank cells for the header rows: one per data column (period columns + total)
            SET @BlankCells = REPLICATE(CAST(N', N''''' AS nvarchar(max)), @ColCount + 1);
            -- Footer fills 4 data columns (Run Date: | <date> | Elapsed: | <elapsed>); pad the rest in the middle.
            -- Needs @ColCount >= 3: a negative count makes REPLICATE return NULL (caught by the check below).
            SET @FooterGap  = REPLICATE(CAST(N', N''''' AS nvarchar(max)), @ColCount + 1 - 4);

            SET @sql = N'
            SELECT ' + QUOTENAME(@GridTitle) + N', ' + @colNames + N'
            FROM (
                -- Detail lines (accounts in FundOrder, then the TOTAL block last)
                SELECT Sec = @SecDetail, l.FundOrder, l.Account, l.LineOrder,
                       ' + QUOTENAME(@GridTitle) + N' = l.LineLabel,
                       ' + @cols + N'
                FROM #Lines l
                GROUP BY l.FundOrder, l.Account, l.LineOrder, l.LineLabel

                UNION ALL

                -- Report header: title line, then a blank line
                SELECT @SecHeader, NULL, NULL, @RowTitle,      @Header' + @BlankCells + N'
                UNION ALL
                SELECT @SecHeader, NULL, NULL, @RowTitleBlank, N''''' + @BlankCells + N'

                UNION ALL

                -- Run info footer: Source | Run Date: | <date> | [blank...] | Elapsed: | <elapsed>
                SELECT @SecFooter, NULL, NULL, @RowFooter,
                       @FooterSource, @FooterRunDate, @RunDate' + @FooterGap + N', @FooterElapsed, @Elapsed
            ) r
            ORDER BY r.Sec, r.FundOrder, r.Account, r.LineOrder;';

            -- Any NULL piece (e.g. a negative REPLICATE count, or no #Cols rows) makes the whole
            -- string NULL, and sp_executesql would then run nothing without an error.
            IF @sql IS NULL
                THROW 50002, 'Grid report SQL could not be built (check @ColCount and #Cols).', 1;

            -- The dynamic SQL runs in a child scope, so it can read #Lines; temp tables created
            -- in this procedure are visible to it.
            EXEC sys.sp_executesql @sql,
                 N'@Header nvarchar(100), @RunDate nvarchar(30), @Elapsed nvarchar(20),
                   @MoneyFormat nvarchar(10), @MoneyCulture nvarchar(10),
                   @FooterSource nvarchar(140), @FooterRunDate nvarchar(30), @FooterElapsed nvarchar(30),
                   @SecHeader int, @SecDetail int, @SecFooter int, @RowTitle int, @RowTitleBlank int, @RowFooter int',
                 @MoneyFormat   = @MoneyFormat,
                 @MoneyCulture  = @MoneyCulture,
                 @FooterSource  = @FooterSource,
                 @FooterRunDate = @FooterRunDate,
                 @FooterElapsed = @FooterElapsed,
                 @Header        = @ReportHeader,
                 @RunDate       = @DateTimeLocalPrint,
                 @Elapsed       = @ElapsedStr,
                 @SecHeader     = @Sec_Header,
                 @SecDetail     = @Sec_Detail,
                 @SecFooter     = @Sec_Footer,
                 @RowTitle      = @Row_Title,
                 @RowTitleBlank = @Row_TitleBlank,
                 @RowFooter     = @Row_Footer;
        END
        -- ---------------------------------------------------------------------------------------------
        -- MONTH OUTPUT: daily detail for the calendar month containing @ParamDate
        --     Sec_Header  : report title ('Monthly Fund Activity YYYY-MMM'), blank
        --     Sec_Detail  : each day's rows per account (FundOrder), blank, day total, blank
        --     Sec_Summary : month line per account (labelled YYYY-MMM), blank, month TOTAL, two blanks
        --     Sec_Footer  : run info footer (source, run date, elapsed)
        --
        -- Output columns (fixed): As Of Date | Account | Prior Balance | Rcpts New | Rcpts Existing |
        --                         Disbursements | Net Movement | Running Balance
        --
        -- @BypassTotal = 1 omits the 'YYYY-MM-DD Total' lines and the month TOTAL line
        -- (and the blank line directly above each), leaving one blank line between days.
        --
        -- Hidden measures (show rules above #Daily) print blank and are left out of the totals.
        --
        -- Totals:
        --     Day total     : every column summed across accounts for that day
        --     Month/account : PriorBalance = first day with data in the month, RunningBalance = last day,
        --                     RcptsAmtNew / RcptsAmtExisting / Disbursements / NetMovement summed
        --     Month TOTAL   : the month/account lines summed
        --
        -- Days with no rows in #Daily do not appear. If the month has no data at all, the report still
        -- returns the title, the month TOTAL line (blank amounts) and the footer.
        -- ---------------------------------------------------------------------------------------------
        ELSE
        BEGIN
            SET @Step = 'Return Month report';

            ;WITH DayTotal AS (         -- one total per day; SUM ignores the NULL (hidden) values
                SELECT AsOfDate,
                       PriorBalance     = SUM(PriorBalance),
                       RcptsAmtNew      = SUM(RcptsAmtNew),
                       RcptsAmtExisting = SUM(RcptsAmtExisting),
                       Disbursements    = SUM(Disbursements),
                       RunningBalance   = SUM(RunningBalance),
                       NetMovement      = SUM(NetMovement)
                FROM   #Daily
                GROUP BY AsOfDate
            ),
            AcctDays AS (               -- first / last day each account has data, for the month balances
                SELECT d.*,
                       AcctFirstDate = MIN(d.AsOfDate) OVER (PARTITION BY d.Account),
                       AcctLastDate  = MAX(d.AsOfDate) OVER (PARTITION BY d.Account)
                FROM   #Daily d
            ),
            MonthAcct AS (              -- one line per account for the month
                -- no ELSE 0 on the balances: hidden balances stay NULL (blank) instead of $0.00
                SELECT AccountDisplay, FundOrder,
                       PriorBalance     = SUM(CASE WHEN AsOfDate = AcctFirstDate THEN PriorBalance   END),
                       RcptsAmtNew      = SUM(RcptsAmtNew),
                       RcptsAmtExisting = SUM(RcptsAmtExisting),
                       Disbursements    = SUM(Disbursements),
                       RunningBalance   = SUM(CASE WHEN AsOfDate = AcctLastDate  THEN RunningBalance END),
                       NetMovement      = SUM(NetMovement)
                FROM   AcctDays
                GROUP BY AccountDisplay, FundOrder
            ),
            Report AS (
                -- Every row of the report, unformatted, with its sort keys:
                --     Sec, SortDate (Sec_Detail only), RowType, FundOrderSort
                -- RowKind: 'D' = data/blank row, 'F' = run info footer (its cells are filled in the final SELECT)

                /* ---------- Detail: daily rows + day totals ---------- */
                -- first branch sets the column names / types for the UNION
                SELECT Sec              = @Sec_Detail,
                       SortDate         = AsOfDate,
                       RowType          = @Row_DayAccount,
                       FundOrderSort    = FundOrder,
                       Label            = CAST(CONVERT(varchar(10), AsOfDate, 23) AS varchar(40)),   -- yyyy-mm-dd
                       Acct             = CAST(AccountDisplay AS nvarchar(50)),
                       PriorBal         = PriorBalance,
                       New              = RcptsAmtNew,
                       Existing         = RcptsAmtExisting,
                       Disb             = Disbursements,
                       RunBal           = RunningBalance,
                       NetMov           = NetMovement,
                       RowKind          = CAST('D' AS char(1))
                FROM   #Daily

                /* ---------- Header ---------- */
                UNION ALL
                SELECT @Sec_Header, NULL, @Row_Title,      NULL, @ReportHeader, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'D'
                UNION ALL
                SELECT @Sec_Header, NULL, @Row_TitleBlank, NULL, '',            NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'D'

                UNION ALL   -- blank before and after each day total; only the 'after' blank when bypassing
                SELECT @Sec_Detail, d.AsOfDate, b.RowType, NULL, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'D'
                FROM   DayTotal d CROSS JOIN (VALUES (@Row_DayBlankBefore), (@Row_DayBlankAfter)) b(RowType)
                WHERE  b.RowType = @Row_DayBlankAfter OR @BypassTotal = 0

                UNION ALL   -- day total
                SELECT @Sec_Detail, AsOfDate, @Row_DayTotal, NULL, CONVERT(varchar(10), AsOfDate, 23) + ' Total', NULL,
                       PriorBalance, RcptsAmtNew, RcptsAmtExisting, Disbursements, RunningBalance, NetMovement, 'D'
                FROM   DayTotal
                WHERE  @BypassTotal = 0

                /* ---------- Summary: month by account ---------- */
                UNION ALL   -- blanks (the one above the month TOTAL is dropped when bypassing)
                SELECT @Sec_Summary, NULL, b.RowType, NULL, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'D'
                FROM   (VALUES (@Row_SumBlankTop), (@Row_SumBlankBeforeTotal), (@Row_SumBlankEnd1), (@Row_SumBlankEnd2)) b(RowType)
                WHERE  b.RowType <> @Row_SumBlankBeforeTotal OR @BypassTotal = 0

                UNION ALL   -- one line per account
                SELECT @Sec_Summary, NULL, @Row_SumAccount, FundOrder, @MonthLabel, AccountDisplay,
                       PriorBalance, RcptsAmtNew, RcptsAmtExisting, Disbursements, RunningBalance, NetMovement, 'D'
                FROM   MonthAcct

                UNION ALL   -- month TOTAL (HAVING, not WHERE: a scalar aggregate always returns a row)
                SELECT @Sec_Summary, NULL, @Row_SumTotal, NULL, @MonthLabel, N'TOTAL',
                       SUM(PriorBalance), SUM(RcptsAmtNew), SUM(RcptsAmtExisting),
                       SUM(Disbursements), SUM(RunningBalance), SUM(NetMovement), 'D'
                FROM   MonthAcct
                HAVING @BypassTotal = 0

                /* ---------- Footer (the summary already ends with blank lines) ---------- */
                UNION ALL
                SELECT @Sec_Footer, NULL, @Row_Footer, NULL, @FooterSource, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'F'
            )
            -- Format every cell as text. Footer row ('F') reads left to right:
            --     Source: <DATABASE> | Run Date: | <date> | | | | Elapsed: | <elapsed>
            SELECT
                [As Of Date]      = Label,
                [Account]         = CASE RowKind WHEN 'F' THEN @FooterRunDate ELSE ISNULL(Acct, N'') END,
                [Prior Balance]   = CASE RowKind WHEN 'F' THEN CAST(@DateTimeLocalPrint AS nvarchar(30))
                                                 ELSE ISNULL(FORMAT(PriorBal, @MoneyFormat, @MoneyCulture), N'') END,
                [Rcpts New]       = CASE RowKind WHEN 'F' THEN N'' ELSE ISNULL(FORMAT(New,      @MoneyFormat, @MoneyCulture), N'') END,
                [Rcpts Existing]  = CASE RowKind WHEN 'F' THEN N'' ELSE ISNULL(FORMAT(Existing, @MoneyFormat, @MoneyCulture), N'') END,
                [Disbursements]   = CASE RowKind WHEN 'F' THEN N'' ELSE ISNULL(FORMAT(Disb,     @MoneyFormat, @MoneyCulture), N'') END,
                -- Net Movement before Running Balance, same order as the Fiscal / Quarter reports.
                [Net Movement]    = CASE RowKind WHEN 'F' THEN @FooterElapsed
                                                 ELSE ISNULL(FORMAT(NetMov,   @MoneyFormat, @MoneyCulture), N'') END,
                [Running Balance] = CASE RowKind WHEN 'F' THEN CAST(@ElapsedStr AS nvarchar(20))
                                                 ELSE ISNULL(FORMAT(RunBal,   @MoneyFormat, @MoneyCulture), N'') END
            FROM Report
            ORDER BY Sec,
                     CASE WHEN Sec = @Sec_Detail THEN SortDate END,  -- group each day's rows together
                     RowType,
                     FundOrderSort;                                  -- accounts in display order (sort key only; not output)
        END

    END TRY
    BEGIN CATCH

        -- =============================================================================================
        -- ERROR RESULT SET (intentional: the consumer reads this instead of an exception)
        -- Shape: two columns (Variable, Value), one row per item below, in this order.
        -- If you add or reorder rows, tell the consumer's owner: it may read them by position.
        -- =============================================================================================

        -- Capture error details first, before any other statement resets them
        DECLARE @ErrNumber   int            = ERROR_NUMBER();
        DECLARE @ErrSeverity int            = ERROR_SEVERITY();
        DECLARE @ErrState    int            = ERROR_STATE();
        DECLARE @ErrLine     int            = ERROR_LINE();
        DECLARE @ErrProc     nvarchar(128)  = ISNULL(ERROR_PROCEDURE(), OBJECT_NAME(@@PROCID));
        DECLARE @ErrMessage  nvarchar(2048) = ERROR_MESSAGE();

        -- Return the error details as a result set instead of re-raising.
        -- Temp tables are dropped automatically when the proc exits.
        -- If the caller owns a transaction, it is left for the caller to roll back
        -- (with XACT_ABORT ON it is already doomed and can only be rolled back).
        SELECT
            v.Variable,
            v.Value
        FROM (VALUES
            (1, N'@ErrProc',     CAST(@ErrProc     AS nvarchar(2048))),
            (2, N'@Step',        CAST(@Step        AS nvarchar(2048))),
            (3, N'@ParamDate',   CONVERT(nvarchar(2048), @ParamDate, 120)),
            (4, N'@ParamPeriod', CAST(@ParamPeriod AS nvarchar(2048))),
            (5, N'@BypassTotal', CAST(@BypassTotal AS nvarchar(2048))),
            (6, N'@ErrNumber',   CAST(@ErrNumber   AS nvarchar(2048))),
            (7, N'@ErrSeverity', CAST(@ErrSeverity AS nvarchar(2048))),
            (8, N'@ErrState',    CAST(@ErrState    AS nvarchar(2048))),
            (9, N'@ErrLine',     CAST(@ErrLine     AS nvarchar(2048))),
            (10, N'@ErrMessage', CAST(@ErrMessage  AS nvarchar(2048)))
        ) AS v(Ord, Variable, Value)
        ORDER BY v.Ord;

    END CATCH
END
GO
