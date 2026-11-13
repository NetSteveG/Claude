
--CREATE OR ALTER PROCEDURE [Account].[TaxRateExpAnchorReserveCalcRun]
--    @ParamFiscalYear      SMALLINT, -- Always passed a value
--    @ParamEmployerID      INT       -- Always passed a value
--WITH RECOMPILE
--AS --- STORED PROCEDURE
BEGIN

SET NOCOUNT ON; 

/* ====================================================================================================
   PROCEDURE : [Account].[TaxRateExpAnchorReserveCalcRun]

   PURPOSE
   -------
   Builds the experience-rating data for one ANCHOR employer (the employer being rated) for one Fiscal
   (rate) Year, including the experience of the employers it acquired (UC86 / SUTAFULL / SUTAPARTIAL).
   The procedure:
     - Gets the acquisition chain and the employers to process from [Account].[TaxRateExpAcqEmployers]
     - Refreshes the [Account].[TaxRateExp*] work tables (MERGE: insert / update / delete) for the Anchor
     - Calculates a PROVISIONAL, ANCHOR-ONLY reserve, reserve ratio and Rate Type
       (Max-Rate / New-Rate / Rated / Undetermined)
     - Returns result sets that are consumed in a FIXED ORDER (see OUTPUT RESULT SETS)

   PROCEDURE vs. APPLICATION (who calculates the FINAL figures)
   ------------------------------------------------------------
   The procedure builds and returns the data; the APPLICATION does the final combining.
     - The [Account].[TaxRateExpReserveCalc] row (written by step 9 / 10; result set #3 returns its
       RateTypeDetermined) is the ANCHOR-ONLY starting point. Its
       Reserve, ReserveRatio and RateTypeDetermined cover the Anchor's own taxes, benefits, payroll and
       adjustments only - no predecessor experience.
     - Result sets #1 / #2 carry the acquisition experience: predecessor totals, quarterly payroll and
       PercentTransfer. The application uses them to calculate the FINAL Reserve, ReserveRatio and rate.
     - PercentTransfer is an INPUT to the application; the application decides how to apply it to
       PARTIAL predecessors. The procedure does not scale anything by PercentTransfer.
     - The application RE-DECIDES the Rate Type after adding the acquisition experience. This applies to
       the normal ReserveCalc row AND to the step 10 fallback row ('Max-Rate :No Reserve Calc').
   So: changes to the provisional Reserve / ReserveRatio / RateTypeDetermined logic here affect the
   final rate only through what the application reuses. Values the application takes directly
   (result sets #1 / #2 and the Anchor's base amounts) flow straight into the final rate.

   PARAMETERS
   ----------
   @ParamFiscalYear  SMALLINT  Fiscal (rate) year being calculated             -> @FiscalYear
   @ParamEmployerID  INT       Anchor EmployerID (NULL is treated as -1)       -> @AnchorEmployerID
   Both are passed unchanged to [Account].[TaxRateExpAcqEmployers].

   SCRIPT MODE vs. PROCEDURE MODE
   ------------------------------
   The file can run as an ad-hoc script or be deployed as the stored procedure.
     Script mode (current)   : CREATE OR ALTER PROCEDURE ... AS is commented out at the top of the file,
                               and @ParamFiscalYear / @ParamEmployerID are DECLAREd below with test values.
     Procedure mode (deploy) : Uncomment the CREATE OR ALTER PROCEDURE ... AS lines, comment out the
                               DECLARE @ParamFiscalYear / DECLARE @ParamEmployerID lines, and set
                               @Show_Debug_Data to 'N'.
   The BEGIN / END that wrap the body are used in both modes.

   KEY SETTINGS (declared at top of script)
   ----------------------------------------
   @Show_Debug_Data            'Y' appends debug result sets at the end (set to 'N' for deploy)
   @NumberOfYears              Payroll years used for the 3-year average (3)
   @min/@maxReserveRatio       Reserve Ratio is clamped to +/- 9999.9999
   @FebMailingDateCutoff       Feb bill-statement mailing cutoff for FY   (dbo.GetFebBillStatementMailingCutoffDate)
   @FebMailingDateCutoffPrior  Feb bill-statement mailing cutoff for FY-1
   @LocalTimeZone              From dbo.DateTime_LocalUtcTranslate; local cutoffs are converted to UTC
   @ReptTypeQWR / QWRA / OAF   [Configuration].[ReportType] IDs (enabled rows only)
   @RateType*                  Rate Type labels written to [RateTypeDetermined] (max length 100)

   TERMINOLOGY
   -----------
   Anchor       The employer being rated (@AnchorEmployerID)
   Successor    The employer that acquired another employer's experience
   Predecessor  The employer whose experience was acquired
   FULL         All experience transfers to the Successor             ([IsPartial] = 0)
   PARTIAL      Only acquisition-year experience is transferred        ([IsPartial] = 1)
                FirstYearFy = YEAR(AcquisitionDate) + 1 for partial transfers, else @FiscalYear
   Anchor row   The #ttAcqEmployers row for the Anchor itself: AcquisitionID / AcquisitionDate NULL,
                IsPartial = 0, PredecessorEmployerID = Anchor
   Base Period  The first 4 of the prior 5 quarters, for each quarter of the calendar year before
                the rate year (#BasePeriod)

   PROCESSING FLOW
   ---------------
    1. SETUP
       - Drop session temp tables; start step timing (@ProcStart)
       - Resolve local time zone, Feb mailing cutoffs, Rate Type labels and Report Type IDs

    2. ACQUISITIONS AND EMPLOYERS TO PROCESS  (EXEC [Account].[TaxRateExpAcqEmployers])
       - This procedure CREATEs #ttAcquistions and #ttAcqEmployers; the sub-procedure fills them
       - The sub-procedure handles: valid / partial transfer types, the acquisition-chain walk
         (NavPath / NavLevel), current liability-status filters, latest Process Status per acquisition
         (APPROVED / PENDING / PENDINGUI / PENDINGER), SUTAFULL SutaCutoffYear, the Anchor row, and the
         per-row processing parameters (FirstYearFy, Feb cutoffs, receipt / benefit / tax-quarter UTC cutoffs)

    3. RESULT SET #0: acquisitions  (#ttAcquistions where ProcStatRank = 1)

    4. BASE PERIODS  (#BasePeriod)
       - 4 base periods (one per quarter of FY-1) x first 4 of the prior 5 quarters = 16 rows

    5. MERGE [Account].[TaxRateExpTaxesPaid]  (every employer in #ttAcqEmployers)
       - Tax payments (ReceiptAllocation -> Receivable: TAXCOMPUTED / TAXSHAREDCOST / TAXOTHERSTATE)
         per employer / year / quarter / acquisition
       - TaxesPaid      = tax year FY-1 (PARTIAL: acquisition year)
         TaxesPaidPrior = earlier tax years
       - Limited by RcptEffCutoffDate (Jan 31 of FY) and RcptCreatedCutoffUtc (Feb mailing cutoff)

    6. MERGE [Account].[TaxRateExpBenChg]  (every employer in #ttAcqEmployers)
       - Benefit charges and reliefs (ChargeStatementCharge), split by CreatedDate:
           Client      : created in the year before FirstYearFy
           ClientPrior : created before that

    7. LATE / MISSING REPORT CHECK  (#EmplStatDet -> #TaxQuartersQwrQwraLateStatus -> @AnyLateMissingReports)
       - #EmplStatDet: Anchor status row in effect at end of Dec 31 of FY-1 (= beginning of Jan 01 of FY) ([Account].[fn_StatusDeterminationFlattened_ForEmployer])
       - Every Anchor tax quarter from that row's LiabilityDate through FY-1 in which it was
         ACTIVE / REACTIVATED needs a QWR / QWRA received by @FebMailingDateCutoff (or TaxRateTimely = 1)
       - A late report is treated the same as a missing report
       - This is the ONLY late / missing report check. (The former [IsLate] / [SUM_IsLate] in the
         ReserveCalc build (9d / 9e) was always 0 - 9b keeps only timely reports - and was removed.)

    8. MERGE [Account].[TaxRateExpPayRoll]  (every employer in #ttAcqEmployers)
       - Latest QWR / QWRA / OAF report per tax quarter for FY-3..FY-1, received by the Feb cutoff
         (or TaxRateTimely = 1): Taxable / Total payroll, plus "Timely" versions
       - Only quarters with a non-zero amount are kept

    9. MERGE [Account].[TaxRateExpReserveCalc]  (ANCHOR row only) - built in steps:
       (PROVISIONAL, ANCHOR-ONLY figures - the application calculates the final ones; see PROCEDURE vs. APPLICATION)
       9a #ttRC_StatDet        Anchor status-determination timeline (EffDt / EffEndDt / LiabilityDate)
       9b #ttRC_TaxQtr         Latest timely QWR / QWRA per tax quarter, FY-1 and earlier; timely wages
       9c #ttRC_QtrStatus      Tax quarter x status overlap (LiabilityDate, begin/end status, active count)
       9d #ttRC_QtrFlags       Per-quarter / base-period flags (NonZeroWage, NotRateable)
                               NOTE: SELECT DISTINCT over the full column list - do not add / remove columns
       9e #ttRC_BasePeriodSum  Flags rolled up per employer (MAX_ / SUM_)
       9f #ttRC_Money          Totals from TaxRateExpTaxesPaid / BenChg / PayRoll
       9g #ttRC_Adjust         [Account].[RunningReserve] adjustments in one pass (6 buckets)
       9h #ttRC_Source         PriorReserve, Reserve, ReserveRatio (clamped), RateTypeDetermined
       9i MERGE [Account].[TaxRateExpReserveCalc] USING #ttRC_Source
       Logic quirks deliberately kept unchanged are marked "-- KEPT AS-IS (QUIRK n)" in the code.
       - What counts toward the Anchor's ReserveCalc row - the ANCHOR's own data only:
           TaxesPaid / TaxesPaidPrior  Anchor only (EmployerID = Anchor, IsPartial = 0)
           Benefit charges             Anchor only (EmployerID = Anchor, IsPartial = 0)
           Payroll (ratio denominator) Anchor only (EmployerID = Anchor, IsPartial = 0)
           Adjustments (9g)            Anchor only
         Predecessor experience (FULL and PARTIAL) is NOT added here; it is returned in result sets #1 / #2
         (TransferExperience, with PercentTransfer) and combined by the application code.
       - Adjustments come from [Account].[RunningReserve]: PAYMENTADJUST adds, BENEFITADJUST subtracts
           PriorReserve = (TaxesPaidPrior - BenefitsTotalClientPrior) + adjustments for YEAR <= FY-2
           Reserve      = PriorReserve + (TaxesPaid - BenefitsTotalClient)
                          + adjustments for YEAR = FY-1 (current cutoffs)
                          (includes the PriorReserve adjustments - changed from the original, which left them out)
           ReserveRatio = ROUND(Reserve / TaxablePayRollTimely3YrAvg, 4)
                          (numerator = Reserve - changed from the original, which used YEAR <= FY-1
                           adjustments with the current cutoffs for every year)
                          NULL when TaxablePayRollTimely3YrAvg <= 0; 0.00 when the numerator = 0;
                          clamped to +/- 9999.9999
       - RateTypeDetermined (first match wins):
           Max-Rate :Late Report                       @AnyLateMissingReports (step 7)
           New-Rate / Max-Rate :Inactive / Not liable  4 non-rateable quarters in any base period
                                                       (New when Reserve >= 0)
           New-Rate / Max-Rate :$0.00 Report / ...     a base period with no non-zero timely-wage quarter
                                                       (New when Reserve >= 0)
           Max-Rate :Timely Wages <= 0.00              ReserveRatio IS NULL
           Rated :                                     non-zero timely wages in all 4 base periods
           Undetermined :                              anything else

   10. MISSING ANCHOR ROW  (#MissingIds)
       - If the MERGE produced no ReserveCalc row for the Anchor, insert one from the TaxRateExp* totals
         with ReserveRatio NULL and 'Max-Rate :No Reserve Calc'
       - Provisional: the application re-decides the Rate Type for this row after adding acquisition experience

   11. TRANSFER EXPERIENCE  (#ttTransExp, #ttTransExpPayroll) -> result sets #1 / #2
       - The acquisition experience the APPLICATION adds to the Anchor-only ReserveCalc row to get the final
         Reserve, ReserveRatio and rate. Values here flow straight into the final rate.
       - #ttTransExp: one row per Anchor / FULL Predecessor and per PARTIAL Predecessor, totals from TaxRateExp*
           FULL / Anchor : Year1 = FY-1, Year2 = FY-2, Year3 = FY-3
           PARTIAL       : Year1 = YEAR(AcquisitionDate), Year2 = -1, Year3 = -2
           (NOTE: the opposite order to TaxRateExpReserveCalc, where Year1 = FY-3)
       - Zero rows are added for acquisitions that have no data
       - *Adjust columns are 0.00; Reserve = TaxesPaid - BenefitsTotalClient;
         PriorReserve = TaxesPaidPrior - BenefitsTotalClientPrior
       - ClientTaxablePayroll from [Account].[TransferExperienceClientPayroll] (PARTIAL only)
       - PercentTransfer: FULL = 1.00; PARTIAL = ClientTaxablePayroll / TaxablePayRoll (capped 0..1)
         An INPUT for the application, which decides how to apply it to PARTIAL predecessors; nothing in
         this procedure is scaled by it.
       - #ttTransExpPayroll: quarterly TaxRateExpPayRoll rows for the Anchor / FULL Predecessors

   OUTPUT RESULT SETS  (*** KEEP IN ORDER - the caller reads these by position ***)
   ----------------------------------------------------------------------------------
     #0  Acquisitions                #ttAcquistions where ProcStatRank = 1
     #1  TransferExperience          #ttTransExp - acquisition experience + PercentTransfer (used by the app)
     #2  TransferExperiencePayroll   #ttTransExpPayroll (Anchor / FULL rows) (used by the app)
     #3  RateTypeDetermined          Anchor row from [Account].[TaxRateExpReserveCalc] + FebMailingDateCutoff
                                     (PROVISIONAL, Anchor-only - the app re-decides the Rate Type)
     #4  StatDetLiability            Flattened Status Determination with LiabilityDate (all employers in #ttAcqEmployers)
     #5  TaxRateHawaii               [Account].[TaxRateHawaii] rows for the Anchor / Successors / Predecessors
                                     (FiscalYear = FY, or = YEAR(AcquisitionDate) for acquisition rows)
     --  Debug (@Show_Debug_Data = 'Y' only): #ttTransExp reserve check, TaxRateExpTaxesPaid detail

   TABLES WRITTEN
   --------------
     [Account].[TaxRateExpTaxesPaid]     MERGE; deletes rows for this Anchor / FY whose EmployerID is in
                                         #ttAcqEmployers but is no longer in the source
     [Account].[TaxRateExpBenChg]        MERGE; same delete rule
     [Account].[TaxRateExpPayRoll]       MERGE; same delete rule, but only for IsPartial = 0 rows
     [Account].[TaxRateExpReserveCalc]   MERGE + INSERT (Anchor row only)

   OBJECTS READ / CALLED
   ---------------------
     [Account].[TaxRateExpAcqEmployers]                    fills #ttAcquistions / #ttAcqEmployers
     [Account].[fn_StatusDeterminationFlattened_ForEmployer], [Account].[vw_EmployerStatusDetFromToLiability]
     [dbo].[DateTime_LocalUtcTranslate], [dbo].[GetFebBillStatementMailingCutoffDate]
     [Account].[RunningReserve], [Account].[TransferExperience*], [Account].[TaxRateHawaii]
     Receipt / Receivable, ChargeStatement, TaxQuarter / TaxQuarterReports, StatusDetermination tables

   MAINTENANCE NOTES
   -----------------
   - Temp tables are marked "-- ==== TEMP TABLE NO LONGER UTILIZED" after their last use.
     "** EXCEPT FOR DEBUG **" means the table is used again only in the @Show_Debug_Data block.
   - Temp tables created here are dropped at the start and the end. The end list also drops
     #ValidTransferTypes, #PartialTransferTypes and #EmpolyerSD, which belong to the sub-procedure
     (harmless if they don't exist).
   - #ttAcquistions / #ttAcqEmployers must be CREATEd here before the EXEC; their columns must match what
     [Account].[TaxRateExpAcqEmployers] inserts.
   - Step timing: each step is wrapped with SET @StepStart = SYSDATETIME() ... SET @StepRows = @@ROWCOUNT
     and PRINTs "<step>: <ms> ms, <rows> rows"; a TOTAL elapsed line prints after result set #5.
     Keep SET @StepRows = @@ROWCOUNT IMMEDIATELY after the step's statement (any statement in between resets it).
     Exceptions: the #BasePeriod loop and the #ttAcquistions / #ttAcqEmployers counts use SELECT COUNT(*).

   CHANGE HISTORY
   --------------
   Date        Author          Description
   ----------  --------------  ------------------------------------------------------------

==================================================================================================== */

DECLARE @Show_Debug_Data      CHAR = 'N' -- 'Y' TO APPEND DEBUG RESULTS SET

DECLARE @ParamFiscalYear      SMALLINT     = 2026;
DECLARE @ParamEmployerID      INT          = 2110212048 -- 284477044 --  213373310 284476289

-- Session temp tables: drop if they exist from a prior run in this session
DROP TABLE IF EXISTS #ttAcquistions
DROP TABLE IF EXISTS #ttAcqEmployers

DROP TABLE IF EXISTS #BasePeriod;
DROP TABLE IF EXISTS #EmplStatDet;
DROP TABLE IF EXISTS #TaxQuartersQwrQwraLateStatus;
DROP TABLE IF EXISTS #MissingIds;
DROP TABLE IF EXISTS #ttTransExp;
DROP TABLE IF EXISTS #ttTransExpPayroll;

DROP TABLE IF EXISTS #ttRC_StatDet;
DROP TABLE IF EXISTS #ttRC_TaxQtr;
DROP TABLE IF EXISTS #ttRC_QtrStatus;
DROP TABLE IF EXISTS #ttRC_QtrFlags;
DROP TABLE IF EXISTS #ttRC_BasePeriodSum;
DROP TABLE IF EXISTS #ttRC_Money;
DROP TABLE IF EXISTS #ttRC_Adjust;
DROP TABLE IF EXISTS #ttRC_Source;

-- Step timing: each step sets @StepStart before it runs, captures @@ROWCOUNT immediately after it, and PRINTs the elapsed time
DECLARE @ProcStart                           DATETIME2(7) = SYSDATETIME()
DECLARE @StepStart                           DATETIME2(7)
DECLARE @StepRows                            INT

-- ====================================================================================================

-- SELECT [Code] FROM [Configuration].[TransferType]

SET @StepStart = SYSDATETIME()

-- Partial Transfer Type

DECLARE @LocalTimeZone       SYSNAME -- = 'Hawaiian Standard Time'
DECLARE @CurrentDateLocal     DATE;
DECLARE @CurrentDateTimeLocal DATETIME2;
DECLARE @CurrentDateTimeUTC   DATETIME2;

SELECT 
    @LocalTimeZone        = [LocalTimeZone],
    @CurrentDateTimeLocal = CheckUtcToLocalDateTime,
    @CurrentDateLocal     = CAST(CheckUtcToLocalDateTime AS DATE),
    @CurrentDateTimeUTC   = CheckDateTime
FROM [dbo].[DateTime_LocalUtcTranslate](GETUTCDATE())

-- ====================================================================================================

-- @AnchorEmployerID will alsays have a value.
DECLARE @AnchorEmployerID     INT      = case when @ParamEmployerID is null then -1 else @ParamEmployerID end
DECLARE @FiscalYear           SMALLINT = @ParamFiscalYear

-- ====================================================================================================

DECLARE @FebMailingDateCutoff      DATE = [dbo].[GetFebBillStatementMailingCutoffDate](@FiscalYear);
DECLARE @FebMailingDateCutoffPrior DATE = [dbo].[GetFebBillStatementMailingCutoffDate](@FiscalYear -1);

DECLARE @NumberOfYears     INT   = 3;

DECLARE @maxReserveRatio DECIMAL(19, 4) =  9999.9999;
DECLARE @minReserveRatio DECIMAL(19, 4) = -9999.9999;

-- ====================================================================================================

-- MAX LENGTH 100                              --123456789012345678901234567890123456789012345678900123456789001234567890123456789012345678901234567890
DECLARE @RateTypeMaxRate0         varchar(100) = 'Max-Rate :Timely Wages <= 0.00 (No Reserve Ratio)'; -- No Reserve Ratio
DECLARE @RateTypeMaxRate1         varchar(100) = 'Max-Rate :Late Report';
DECLARE @RateTypeMaxRate2         varchar(100) = 'Max-Rate :Inactive / Not liable';

-- A. - Filed wage reports = zero wages
-- Not Chargeable - To Be Chargeable need to have at least one Non Zero Wage in each Base Period
DECLARE @RateTypeMaxRate3        varchar(100) = 'Max-Rate :$0.00 Report / Base Missing Report';
DECLARE @RateTypeMaxRate4        varchar(100) = 'Max-Rate :No Reserve Calc'; -- No Reserve Ratio

DECLARE @RateTypeNewRate1        varchar(100) = 'New-Rate :Inactive / Not liable & Reserve >= 0';
DECLARE @RateTypeNewRate2        varchar(100) = 'New-Rate :$0.00 Report / Base Missing Report & Reserve >= 0';
DECLARE @RateTypeIsRated         varchar(100) = 'Rated :';
DECLARE @RateTypeUndetermined    varchar(100) = 'Undetermined :'

DECLARE @BasePeriodCounter INT = 1;
DECLARE @Prev5QtrCounter   INT = 1;

PRINT '=============================================='
PRINT '[Account].[TaxRateExpAnchorReserveCalcRun] Calculate'
PRINT ''
PRINT '@AnchorEmployerID           : ' + CAST(@AnchorEmployerID   AS VARCHAR)
PRINT '@FiscalYear                 : ' + CAST(@FiscalYear         AS VARCHAR)
PRINT ''
PRINT '@NumberOfYears              : ' + CAST(@NumberOfYears   AS VARCHAR)
PRINT ''
PRINT '@maxReserveRatio            : ' + CAST(@maxReserveRatio AS VARCHAR)
PRINT '@minReserveRatio            : ' + CAST(@minReserveRatio AS VARCHAR)
PRINT ''
PRINT '@LocalTimeZone              : ' + @LocalTimeZone
PRINT '@CurrentDateLocal           : ' + ISNULL(CAST(@CurrentDateLocal     AS VARCHAR),  '-NULL-')
PRINT '@CurrentDateTimeLocal       : ' + ISNULL(CAST(@CurrentDateTimeLocal AS VARCHAR),  '-NULL-')
PRINT '@CurrentDateTimeUTC         : ' + ISNULL(CAST(@CurrentDateTimeUTC   AS VARCHAR),  '-NULL-')
PRINT ''
PRINT '=============================================='

DECLARE @ReptTypeQWR  INT = (SELECT [ReportTypeId] FROM [Configuration].[ReportType] WHERE [Code] = 'QWR'  AND [IsEnabled] = 1)
DECLARE @ReptTypeQWRA INT = (SELECT [ReportTypeId] FROM [Configuration].[ReportType] WHERE [Code] = 'QWRA' AND [IsEnabled] = 1)
DECLARE @ReptTypeOAF  INT = (SELECT [ReportTypeId] FROM [Configuration].[ReportType] WHERE [Code] = 'OAF' AND [IsEnabled] = 1)


-- ##ttAcquistions POPULATED IN [Account].[TaxRateExpAcqEmployers] 
CREATE TABLE #ttAcquistions 
(
    [RecType]               SMALLINT,
    --[BaseType]              CHAR,

    -- [Account].[Acquisition]
    [AnchorEmployerId]      INT,
    [AcquisitionID]         BIGINT,
    [SuccessorEmployerID]   INT, 
    [PredecessorEmployerID] INT, 
    [AcquisitionDate]       DATE,
    [AcquisitionCreated]    DATETIME2,
    [SutaCutoffYear]        SMALLINT,
    [ExperienceTransferID]  BIGINT,
    [FormApplicationId]     BIGINT,

    -- Foreign Tables
    [TransferType]          VARCHAR(100) COLLATE DATABASE_DEFAULT,
    [IsPartial]             BIT,

    -- Stat Det - Liability Status - CURRENT
    [SuccCurLiaStat]        VARCHAR(100) COLLATE DATABASE_DEFAULT,
    [PredCurLiaStat]        VARCHAR(100) COLLATE DATABASE_DEFAULT,

    -- Processing Status 

    [ProcStatEffDt]         DATE,
    [ProcessCode]           VARCHAR(200) COLLATE DATABASE_DEFAULT,
    [ProcessStatusCode]     VARCHAR(200) COLLATE DATABASE_DEFAULT,
    [ProcStatID]            BIGINT,
    [ProcStatCreated]       DATETIME2,

    [ProcStatOrder]         BIGINT,
    [ProcStatRank]          BIGINT,

    [SuccLiaEffDate]         DATE,
    [SuccLiaStatus]          VARCHAR (100) COLLATE DATABASE_DEFAULT,
    [SuccLiabilityDate]      DATE,
    [SuccFirstLiabilityDate] DATE,

    [PredLiaEffDate]         DATE,
    [PredLiaStatus]          VARCHAR (100) COLLATE DATABASE_DEFAULT,
    [PredLiabilityDate]      DATE,
    [PredFirstLiabilityDate] DATE,

    [NavLevel]               INT,
    [NavPath]                VARCHAR(MAX) COLLATE DATABASE_DEFAULT,

    [CurrentStatusExclude]   VARCHAR(MAX) COLLATE DATABASE_DEFAULT
)

-- #ttAcqEmployers POPULATED IN [Account].[TaxRateExpAcqEmployers] will include the employers that we will be processed
CREATE TABLE #ttAcqEmployers 
(
     -- EmployerID that of the Employer being Rated
     [AnchorEmployerId]                 INT

     -- Account.Acquisition ID linking the Successor/Predecessor (NULL for the Anchor's own row)
    ,[AcquisitionID]                    BIGINT

     -- Effective date of the acquisition (used to derive FirstYearFy for partial transfers)
    ,[AcquisitionDate]                  DATE

     -- SUTA cutoff year from the Acquisition record
    ,[SutaCutoffYear]                   SMALLINT

     -- UTC date/time the Acquisition record was created
    ,[AcquisitionCreated]               DATETIME2(2)

     -- Experience transfer type code (UC86, SUTAFULL, SUTAPARTIAL)
    ,[TransferType]                     VARCHAR(100) COLLATE DATABASE_DEFAULT

     -- 1 = Partial transfer (TransferType in #PartialTransferTypes), 0 = Full transfer / Anchor row
    ,[IsPartial]                        BIT

     -- EmployerID that acquired the Predecessor (NULL for the Anchor's own row)
    ,[SuccessorEmployerID]              INT

     -- EmployerID being acquired by the Successor (set to the Anchor EmployerID for the Anchor's own row)
    ,[PredecessorEmployerID]            INT

     -- Depth of the acquisition chain from the Anchor (count of commas in NavPath; NULL for the Anchor's own row)
    ,[NavLevel]                         INT

     -- Comma-delimited chain of SuccessorEmployerIDs walked from the Anchor, e.g. ',123,456,' (prevents re-walking)
    ,[NavPath]                          VARCHAR(MAX) COLLATE DATABASE_DEFAULT

    -- Processing Parameters
     -- First fiscal year the experience counts: YEAR(AcquisitionDate) + 1 if partial, else @FiscalYear
    ,[FirstYearFy]                               SMALLINT

     -- Fiscal year being rated (@FiscalYear)
    ,[FiscalYear]                                SMALLINT

     -- February bill statement mailing date for FiscalYear (used for payroll wages)
    ,[FebMailingDate]                            DATE
     -- February bill statement mailing cutoff date for FiscalYear
    ,[FebMailingDateCutoff]                      DATE

     -- February bill statement mailing date for FiscalYear - 1 (used for payroll wages)
    ,[FebMailingDatePrior]                       DATE
     -- February bill statement mailing cutoff date for FiscalYear - 1
    ,[FebMailingDateCutoffPrior]                 DATE


     -- Receipts must have an EffectiveDate on or before this date (Jan 31 of FiscalYear)
    ,[RcptEffCutoffDate]                         DATE
     -- Receipt allocations must be created before this UTC time (FebMailingDateCutoff, local to UTC)
    ,[RcptCreatedCutoffUtc]                      DATETIME2(2)

     -- Benefit charges must be created before this UTC time (Jan 1 of FirstYearFy, local to UTC)
    ,[MaxPriorYearBenChgCreatedCutoffUtcFY]      DATETIME2(2)
     -- Start of the prior-year benefit charge window, as a UTC time (Jan 1 of FirstYearFy - 1, local to UTC)
    ,[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] DATETIME2(2)

     -- Tax quarter reports must be created before this UTC time (FebMailingDateCutoff, local to UTC)
    ,[TaxQtrCreatedCutoffUtc]                    DATETIME2(2)
)

-- ===================================================================================================================

PRINT 'CALL [Account].[TaxRateExpAcqEmployers]: '

SET @StepStart = SYSDATETIME()

-- Call [Account].[TaxRateExpAcqEmployers] -- Sets ##ttAcquistions AND #ttAcqEmployers

EXEC [Account].[TaxRateExpAcqEmployers] @ParamFiscalYear = @ParamFiscalYear,  @ParamEmployerID = @ParamEmployerID

/*
    IN: [Account].[TaxRateExpAcqEmployers]

    -- @FebMailingDateCutoff IS COMPUTED LIKE THIS PROCEDURE

    -- Same for every row: convert the local cutoffs to UTC once
    DECLARE @RcptEffCutoffUtc       DATETIME2(2) = CAST(CAST(DATEFROMPARTS(@FiscalYear, 01, 31) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2));
    DECLARE @FebMailingCutoffUtc    DATETIME2(2) = CAST(CAST(@FebMailingDateCutoff              AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2));

    THE VALUES ARE SET VIA... 
         #ttAcqEmployers.[FirstYearFy]                               = Calc.[FirstYearFy]
        ,#ttAcqEmployers.[FiscalYear]                                = @FiscalYear

        -- USED FOR PAYROLL WAGES
        ,#ttAcqEmployers.[FebMailingDate]                            = @FebMailingDate
        ,#ttAcqEmployers.[FebMailingDatePrior]                       = @FebMailingDatePrior
        ,#ttAcqEmployers.[FebMailingDateCutoff]                      = @FebMailingDateCutoff
        ,#ttAcqEmployers.[FebMailingDateCutoffPrior]                 = @FebMailingDateCutoffPrior

        ,#ttAcqEmployers.[RcptEffCutoffDate]                         = @RcptEffCutoffUtc
        ,#ttAcqEmployers.[RcptCreatedCutoffUtc]                      = @FebMailingCutoffUtc
        ,#ttAcqEmployers.[TaxQtrCreatedCutoffUtc]                    = @FebMailingCutoffUtc
*/

PRINT CONCAT('DONE [Account].[TaxRateExpAcqEmployers]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ')

SET @StepStart = SYSDATETIME()
SET @StepRows = (SELECT COUNT(*) FROM #ttAcquistions)
PRINT CONCAT('BUILD #ttAcquistions: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

SET @StepStart = SYSDATETIME()
SET @StepRows = (SELECT COUNT(*) FROM #ttAcqEmployers)
PRINT CONCAT('BUILD #ttAcqEmployers: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- #0 OUTPUT DATA RESULT SET (KEEP IN ORDER):  #ttAcquistions -- Done at beginning ============================================================
SET @StepStart = SYSDATETIME()

SELECT DISTINCT
     ttTaxRateExpAcquisition.[AcquisitionID]            AS [AcquisitionID]
    ,ttTaxRateExpAcquisition.[AcquisitionDate]          AS [AcquisitionDate]
    ,ttTaxRateExpAcquisition.[SutaCutoffYear]           AS [SutaCutoffYear]
    ,ttTaxRateExpAcquisition.[AcquisitionCreated]       AS [AcquisitionCreated]
    ,ttTaxRateExpAcquisition.[TransferType]             AS [TransferType]
    ,ttTaxRateExpAcquisition.[IsPartial]                AS [IsPartial]

    ,ttTaxRateExpAcquisition.[SuccessorEmployerID]      AS [SuccessorEmployerID]
    ,ttTaxRateExpAcquisition.[PredecessorEmployerID]    AS [PredecessorEmployerID]
    ,ttTaxRateExpAcquisition.[ProcStatEffDt]            AS [ProcStatEffDt]
    ,ttTaxRateExpAcquisition.[ProcessCode]              AS [ProcessCode]
    ,ttTaxRateExpAcquisition.[ProcessStatusCode]        AS [ProcessStatusCode]
    ,ttTaxRateExpAcquisition.[FormApplicationId]        AS [FormApplicationId]

    ,ttTaxRateExpAcquisition.[ProcStatID]               AS [ProcStatID]
    ,ttTaxRateExpAcquisition.[ProcStatCreated]          AS [ProcStatCreated]
    ,ttTaxRateExpAcquisition.[ProcStatOrder]            AS [ProcStatOrder]
    ,ttTaxRateExpAcquisition.[ProcStatRank]             AS [ProcStatRank]

    ,ttTaxRateExpAcquisition.[SuccLiaEffDate]           AS [SuccLiaEffDate]
    ,ttTaxRateExpAcquisition.[SuccLiaStatus]            AS [SuccLiaStatus]
    ,ttTaxRateExpAcquisition.[SuccLiabilityDate]        AS [SuccLiabilityDate]
    ,ttTaxRateExpAcquisition.[SuccFirstLiabilityDate]   AS [SuccFirstLiabilityDate]

    ,ttTaxRateExpAcquisition.[PredLiaEffDate]           AS [PredLiaEffDate]
    ,ttTaxRateExpAcquisition.[PredLiaStatus]            AS [PredLiaStatus]
    ,ttTaxRateExpAcquisition.[PredLiabilityDate]        AS [PredLiabilityDate]
    ,ttTaxRateExpAcquisition.[PredFirstLiabilityDate]   AS [PredFirstLiabilityDate]

FROM #ttAcquistions AS ttTaxRateExpAcquisition
WHERE 1=1
    AND ttTaxRateExpAcquisition.[ProcStatRank] = 1

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('#0 OUTPUT DATA RESULT SET (KEEP IN ORDER):  #ttAcquistions: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ===================================================================================================================

DECLARE @BasePeriodDate DATE;

-- #BasePeriod table is used to get the 1st 4 quarter of the prior 5 quarters of the quarter for the calandar year prior to the calandar year processing.
CREATE TABLE #BasePeriod 
(
     [BasePeriodDate]            DATE
    ,[BasePeriodDateYear]        INT
    ,[BasePeriodDateQtr]         INT
    ,[QtrNum]                    INT
    ,[BasePeriodDatePrior]       DATE
    ,[BasePeriodDatePriorEnd]    DATE
    ,[BasePeriodDatePriorYear]   SMALLINT
    ,[BasePeriodDatePriorQtr]    TINYINT
)

DECLARE @CNT INT = 1

SET @StepStart = SYSDATETIME()

WHILE @BasePeriodCounter <= 4
BEGIN
    
    SET @BasePeriodDate =  DATEFROMPARTS(@FiscalYear - 1, (@BasePeriodCounter - 1) * 3 + 1, 1) 

    ----PRINT CAST(@BasePeriodDate AS VARCHAR)

    SET @CNT = 0
    SET @Prev5QtrCounter = 5
    WHILE @Prev5QtrCounter >= 1 AND @CNT < 4 -- 1st 4 Quarters of Last 5 Quarters
    BEGIN
        SET @CNT = @CNT + 1

        INSERT INTO #BasePeriod
        SELECT
             @BasePeriodDate                    AS [BasePeriodDate]
            ,DATEPART(YEAR,    @BasePeriodDate) AS [BasePeriodDateYear]
            ,DATEPART(QUARTER, @BasePeriodDate) AS [BasePeriodDateQtr]
            ,@CNT                               AS [QtrNum]
            ,DATEADD(QUARTER, @Prev5QtrCounter * -1, @BasePeriodDate)                         AS [BasePeriodDatePrior]
            ,DATEADD(DAY, -1, DATEADD(QUARTER, (@Prev5QtrCounter * -1) + 1, @BasePeriodDate)) AS [BasePeriodDatePriorEnd]
            ,DATEPART(YEAR, DATEADD(QUARTER, @Prev5QtrCounter * -1, @BasePeriodDate))         AS [BasePeriodDatePriorYear]
            ,DATEPART(QUARTER, DATEADD(QUARTER, @Prev5QtrCounter * -1, @BasePeriodDate))      AS [BasePeriodDatePriorQtr]

        SET @Prev5QtrCounter = @Prev5QtrCounter - 1; -- DECREMENT
    END

    SET @BasePeriodCounter = @BasePeriodCounter + 1; -- INCREMENT
END

-- Loop inserts one row at a time, so count the table instead of using @@ROWCOUNT
SET @StepRows = (SELECT COUNT(*) FROM #BasePeriod)
PRINT CONCAT('INSERT #BasePeriod (loop): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

SET @StepStart = SYSDATETIME()

-- ====================================================================================================


-- [Account].[TaxRateExpTaxesPaid] -- All Wages for  { Successor, FULL Predecessor }, Aquistion Year Wages for {Partial Predecessor} 
SET @StepStart = SYSDATETIME()

MERGE INTO [Account].[TaxRateExpTaxesPaid] AS TARGET
USING (
SELECT 
     CTE_TaxesPaid.[EmployerID] 
    ,@FiscalYear                      AS [FiscalYear]
    ,CTE_TaxesPaid.[Year]         
    ,CTE_TaxesPaid.[Quarter] 
    ,CTE_TaxesPaid.[AcquisitionDate]
    ,CTE_TaxesPaid.[AcquisitionID]
    ,CTE_TaxesPaid.[IsPartial]

    ,SUM(CTE_TaxesPaid.[TaxesPaid])        AS [TaxesPaid]
    ,SUM(CTE_TaxesPaid.[TaxesPaidPrior])   AS [TaxesPaidPrior]

FROM (
-- CTE_TaxesPaid
SELECT 
    --TTDATA.*
    TTDATA.[EmployerID]

    ,TTDATA.[EffectiveDate]

    ,TTDATA.[DepositDate] ---------------- AS [EffectiveDate]
    
    ,CASE WHEN TTDATA.[Year] = CASE WHEN TTDATA.[IsPartial] = 1 THEN YEAR(TTDATA.[AcquisitionDate]) ELSE TTDATA.[FiscalYear] - 1 END 
          THEN TTDATA.[TaxesPaid]   
          ELSE 0.00 END AS [TaxesPaid]

    ,CASE WHEN TTDATA.[Year] < CASE WHEN TTDATA.[IsPartial] = 1 THEN YEAR(TTDATA.[AcquisitionDate]) ELSE TTDATA.[FiscalYear] - 1 END 
          THEN TTDATA.[TaxesPaid]   
          ELSE 0.00 END AS [TaxesPaidPrior]

    ,TTDATA.[Year]
    ,TTDATA.[Quarter]

    ,TTDATA.[RcptRqstRank]
    ,TTDATA.[RcptAllocRank]
    ,TTDATA.[AcquisitionDate]
    ,TTDATA.[AcquisitionID]
    ,TTDATA.[IsPartial]

FROM (
SELECT
    ttRcpt.[EmployerID]                  AS [EmployerID]

    ,CAST((SELECT TOP 1 xxRcptEff.[EffectiveDate] 
                      FROM [dbo].[ReceiptEffective] AS xxRcptEff 
                      WHERE xxRcptEff.[ReceiptID] = ttRcpt.[ReceiptID] 
                      ORDER BY xxRcptEff.[CreatedDate]) AS DATE) as [EffectiveDate]

    ,ttRcpt.[DepositDate] ---------------- AS [EffectiveDate]
    
    ,ISNULL(ttAllocRcv.[Amount], 0.00)   AS [TaxesPaid]

    ,ttTaxQtrRcv.[Year]    AS [Year]
    ,ttTaxQtrRcv.[Quarter] AS [Quarter]

    ,DENSE_RANK() OVER (PARTITION BY ttRcpt.[ReceiptID]
                        ORDER BY 
                            ttRcpt.[ReceiptID]       DESC, ttRcpt.[CreatedDate]          DESC,
                            ttRcptRqst.[CreatedDate] DESC, ttRcptRqst.[ReceiptRequestID] DESC) AS [RcptRqstRank]

    -- [RcptAllocRank] = 1 is the LATEST ReceiptAllocation for the receipt (created before the Feb cutoff).
    -- BY DESIGN (confirmed business rule): a re-allocation ALWAYS replaces the earlier allocations of the
    -- receipt, so only the latest allocation counts. All ReceiptAllocationReceivable lines of that one
    -- allocation are kept (they share the same rank).
    ,DENSE_RANK() OVER (PARTITION BY ttRcpt.[ReceiptID]
                        ORDER BY
                            ttRcpt.[ReceiptID]        DESC, ttRcpt.[CreatedDate]              DESC,
                            ttRcptRqst.[CreatedDate]  DESC, ttRcptRqst.[ReceiptRequestID]     DESC,
                            ttRcptAlloc.[CreatedDate] DESC, ttRcptAlloc.[ReceiptAllocationID] DESC) AS [RcptAllocRank]

    ,ttAcqEmployers.[AcquisitionID]
    ,ttAcqEmployers.[AcquisitionDate]
    ,ttAcqEmployers.[SuccessorEmployerID]
    ,ttAcqEmployers.[PredecessorEmployerID]

    ,ttAcqEmployers.[RcptEffCutoffDate]
    ,ttAcqEmployers.[FirstYearFy]
    ,ttAcqEmployers.[FiscalYear]
    ,ttAcqEmployers.[IsPartial]

FROM [dbo].[ReceiptAllocation]          AS ttRcptAlloc
    INNER JOIN [dbo].[ReceiptRequest]   AS ttRcptRqst    ON ttRcptRqst.[ReceiptRequestID] = ttRcptAlloc.[ReceiptRequestID] 
    INNER JOIN [dbo].[Receipt]          AS ttRcpt        ON ttRcpt.[ReceiptID]            = ttRcptRqst.[ReceiptID] 

    INNER JOIN #ttAcqEmployers          AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID]     = ttRcpt.[EmployerID]

    -- PAID
    LEFT JOIN [dbo].[ReceiptAllocationReceivable] AS ttAllocRcv  ON ttAllocRcv.[ReceiptAllocationID] = ttRcptAlloc.[ReceiptAllocationID] 
    LEFT JOIN [Account].[Receivable]              AS ttRcv       ON ttRcv.[ReceivableID]             = ttAllocRcv.[ReceivableID] 

    LEFT JOIN [Account].[TaxQuarter]              AS ttTaxQtrRcv ON ttTaxQtrRcv.[TaxQuarterID]       = ttRcv.[TaxQuarterID] 

    LEFT JOIN [Configuration].[ReceivableType]    AS ttRcvTyp    ON ttRcvTyp.[ReceivableTypeID]      = ttRcv.[ReceivableTypeID]
WHERE 1=1
    -- BY DESIGN (confirmed business rule): negative allocation lines are excluded. Reversed / refunded
    -- payments are removed through re-allocation (a new allocation replaces the old one - see [RcptAllocRank]).
    AND ttAllocRcv.[Amount] >= 0.00
    AND ttRcvTyp.[Code] IN ('TAXCOMPUTED', 'TAXSHAREDCOST', 'TAXOTHERSTATE')

    AND ttRcptAlloc.[CreatedDate] <  ttAcqEmployers.[RcptCreatedCutoffUtc]

) AS TTDATA
WHERE 1=1
  AND TTDATA.[EffectiveDate] <= TTDATA.[RcptEffCutoffDate]
  AND TTDATA.[RcptRqstRank]  = 1 
  AND TTDATA.[RcptAllocRank] = 1
  AND ((TTDATA.[IsPartial]   = 1 AND TTDATA.[Year] <= Year(TTDATA.[AcquisitionDate])) OR 
       (TTDATA.[IsPartial]   = 0 AND TTDATA.[Year] <  TTDATA.[FiscalYear]))

) AS CTE_TaxesPaid
GROUP BY 
     CTE_TaxesPaid.[EmployerID]
    ,CTE_TaxesPaid.[YEAR]
    ,CTE_TaxesPaid.[QUARTER]
    ,CTE_TaxesPaid.[AcquisitionDate]
    ,CTE_TaxesPaid.[AcquisitionID]
    ,CTE_TaxesPaid.[IsPartial]

) AS SOURCE -- SOURCE ===============================================
ON TARGET.[AnchorEmployerID] = @AnchorEmployerID         AND
   TARGET.[EmployerID]       = SOURCE.[EmployerID]       AND TARGET.[FiscalYear] = SOURCE.[FiscalYear] AND 
   TARGET.[Year]             = SOURCE.[Year]             AND TARGET.[Quarter]    = SOURCE.[Quarter]   AND
   TARGET.[AcquisitionID]    = SOURCE.[AcquisitionID]
-- If no match is found, insert new data
WHEN NOT MATCHED BY TARGET THEN
INSERT ([AnchorEmployerID], [EmployerID], [FiscalYear], [Year], [Quarter],
        [TaxesPaid], [TaxesPaidPrior], 
        [AcquisitionID], [IsPartial],
        [CreatedDate], [ModifiedDate]) 
VALUES
(  
     @AnchorEmployerID
    ,SOURCE.[EmployerID]
    ,SOURCE.[FiscalYear]
    ,SOURCE.[Year]
    ,SOURCE.[Quarter]

    ,SOURCE.[TaxesPaid]
    ,SOURCE.[TaxesPaidPrior]

    ,SOURCE.[AcquisitionID]
    ,SOURCE.[IsPartial]

    ,GETUTCDATE()  --AS 'CreatedDate'
    ,GETUTCDATE()  --AS 'ModifiedDate'
)

-- If a match is found, update the existing row
WHEN MATCHED 
 AND (TARGET.[TaxesPaid]        <> SOURCE.[TaxesPaid]        OR 
      TARGET.[TaxesPaidPrior]   <> SOURCE.[TaxesPaidPrior]   OR 
      TARGET.[IsPartial]        <> SOURCE.[IsPartial])
THEN
UPDATE SET
    TARGET.[TaxesPaid]        = SOURCE.[TaxesPaid],
    TARGET.[TaxesPaidPrior]   = SOURCE.[TaxesPaidPrior],
    TARGET.[IsPartial]        = SOURCE.[IsPartial],
 
    TARGET.[ModifiedDate] = GETUTCDATE()

-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE 
     AND (@FiscalYear         = TARGET.[FiscalYear])
     AND (@AnchorEmployerID   = TARGET.[AnchorEmployerID])
     AND (TARGET.[EmployerID] IN (SELECT XX.[PredecessorEmployerID] FROM #ttAcqEmployers AS XX))
THEN
    DELETE
OPTION (MAXDOP 1); -- Example: Force single-threaded execution

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE [Account].[TaxRateExpTaxesPaid]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- [Account].[TaxRateExpBenChg] -- All Charges for  { Successor, FULL Predecessor }, Aquistion Year Charges for {Partial Predecessor}
SET @StepStart = SYSDATETIME()

-- CHECK  - MaxPriorYearBenChgCreatedCutoffUtcFY - AOK
MERGE INTO [Account].[TaxRateExpBenChg] AS TARGET
USING (
SELECT 
     ttChgStmnt.[EmployerID]   AS [EmployerID]
    ,@FiscalYear               AS [FiscalYear]
    ,ttChgStmnt.[Year]         AS [Year]
    ,ttChgStmnt.[Quarter]      AS [Quarter]

    ,ttChgStmntChg.[ClientID]                                  AS [ClientID]

    ,ttChgStmntChg.[ChargeStatementChargeID]                   AS [ChargeStatementChargeID]
    ,ttChgStmntChg.[CreatedDate]                               AS [ChargeStatementChargeCreated]

    -- Reserve - Year / Quarter -- based on [Account].[ChargeStatementCharge] [CreatedDate]
    ,CASE WHEN ttChgStmntChg.[CreatedDate] <   ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFY] AND 
               ttChgStmntChg.[CreatedDate] >=  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] 
          THEN ISNULL(ttChgStmntChg.[BenefitsCharged],  0.00) ELSE 0.00 END AS [BenefitsChargedClient]

    ,CASE WHEN ttChgStmntChg.[CreatedDate] <   ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFY]  AND 
               ttChgStmntChg.[CreatedDate] >=  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior]
          THEN  ISNULL(ttChgStmntChg.[BenefitsRelieved], 0.00) ELSE 0.00 END AS [BenefitsRelievedClient]

    ,CASE WHEN ttChgStmntChg.[CreatedDate] <  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] 
          THEN  ISNULL(ttChgStmntChg.[BenefitsCharged],  0.00) ELSE 0.00 END AS [BenefitsChargedClientPrior]

    ,CASE WHEN ttChgStmntChg.[CreatedDate] <  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] 
           THEN ISNULL(ttChgStmntChg.[BenefitsRelieved], 0.00) ELSE 0.00 END AS [BenefitsRelievedClientPrior]

    ,ttAcqEmployers.[AcquisitionDate]
    ,ttAcqEmployers.[AcquisitionID]
    ,ttAcqEmployers.[IsPartial]

FROM [Account].[ChargeStatement]                              AS ttChgStmnt
  INNER JOIN #ttAcqEmployers                                  AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID]     = ttChgStmnt.[EmployerID]

  JOIN [Account].[ChargeStatementChargeStatementCharge]  AS ttChgStmntChgStmntChg ON ttChgStmntChgStmntChg.[ChargeStatementID] = ttChgStmnt.[ChargeStatementID]
  JOIN [Account].[ChargeStatementCharge]                 AS ttChgStmntChg         ON ttChgStmntChg.[ChargeStatementChargeID]   = ttChgStmntChgStmntChg.[ChargeStatementChargeID]

WHERE 1=1 
  AND ttChgStmnt.[IsEnabled] = 1
  AND (ttChgStmntChg.[BenefitsCharged] != 0.00 OR ttChgStmntChg.[BenefitsRelieved] != 0.00)

  -- Date Criteria: Only include if created in Prior Year 
  AND (ttChgStmntChg.[CreatedDate] < ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFY])


) AS SOURCE -- SOURCE ===============================================
ON TARGET.[AnchorEmployerID] = @AnchorEmployerID     AND
   TARGET.[EmployerID]       = SOURCE.[EmployerID]   AND TARGET.[FiscalYear]              = SOURCE.[FiscalYear]              AND 
   TARGET.[Year]             = SOURCE.[Year]         AND TARGET.[Quarter]                 = SOURCE.[Quarter]                 AND 
   TARGET.[ClientID]         = SOURCE.[ClientID]     AND TARGET.[ChargeStatementChargeID] = SOURCE.[ChargeStatementChargeID] AND
   TARGET.[AcquisitionID]    = SOURCE.[AcquisitionID]
-- If no match is found, insert new data
WHEN NOT MATCHED BY TARGET THEN
INSERT ([AnchorEmployerID], [EmployerID], [FiscalYear], [Year], [Quarter],
        [ClientID], [ChargeStatementChargeID], [ChargeStatementChargeCreated], [BenefitsChargedClient], [BenefitsRelievedClient], [BenefitsChargedClientPrior], [BenefitsRelievedClientPrior],
        [AcquisitionID], [IsPartial],
        [CreatedDate], [ModifiedDate]) 
VALUES
(
     @AnchorEmployerID
    ,SOURCE.[EmployerID]
    ,SOURCE.[FiscalYear]
    ,SOURCE.[Year]
    ,SOURCE.[Quarter]

    ,SOURCE.[ClientID]
    ,SOURCE.[ChargeStatementChargeID]
    ,SOURCE.[ChargeStatementChargeCreated]
    ,SOURCE.[BenefitsChargedClient]
    ,SOURCE.[BenefitsRelievedClient]
    ,SOURCE.[BenefitsChargedClientPrior]
    ,SOURCE.[BenefitsRelievedClientPrior]

    ,SOURCE.[AcquisitionID]
    ,SOURCE.[IsPartial]

    ,GETUTCDATE()  --AS 'CreatedDate'
    ,GETUTCDATE()  --AS 'ModifiedDate'
)

-- If a match is found, update the existing row
WHEN MATCHED  
 AND (TARGET.[ChargeStatementChargeCreated] <> SOURCE.[ChargeStatementChargeCreated] OR 
      TARGET.[BenefitsChargedClient]        <> SOURCE.[BenefitsChargedClient]        OR 
      TARGET.[BenefitsRelievedClient]       <> SOURCE.[BenefitsRelievedClient]       OR
      TARGET.[BenefitsChargedClientPrior]   <> SOURCE.[BenefitsChargedClientPrior]   OR 
      TARGET.[BenefitsRelievedClientPrior]  <> SOURCE.[BenefitsRelievedClientPrior]  OR 
      TARGET.[IsPartial]                    <> SOURCE.[IsPartial])
THEN
UPDATE SET
    TARGET.[ChargeStatementChargeCreated] = SOURCE.[ChargeStatementChargeCreated],
    TARGET.[BenefitsChargedClient]        = SOURCE.[BenefitsChargedClient],
    TARGET.[BenefitsRelievedClient]       = SOURCE.[BenefitsRelievedClient],
    TARGET.[BenefitsChargedClientPrior]   = SOURCE.[BenefitsChargedClientPrior],
    TARGET.[BenefitsRelievedClientPrior]  = SOURCE.[BenefitsRelievedClientPrior],

    TARGET.[IsPartial]                    = SOURCE.[IsPartial],

   TARGET.[ModifiedDate] = GETUTCDATE()

-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE 
     AND (@FiscalYear         = TARGET.[FiscalYear])
     AND (@AnchorEmployerID   = TARGET.[AnchorEmployerID])
     AND (TARGET.[EmployerID] IN (SELECT XX.[PredecessorEmployerID] FROM #ttAcqEmployers AS XX))
THEN
    DELETE
OPTION (MAXDOP 1); -- Example: Force single-threaded execution

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE [Account].[TaxRateExpBenChg]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')


CREATE TABLE #EmplStatDet
(
    [StatusDeterminationID]     BIGINT          NOT NULL,
    [EmployerID]                INT             NOT NULL,
    [LiaStatus]                 VARCHAR(50)     NULL,
    [FinMeth]                   VARCHAR(50)     NULL,
    [EffDt]                     DATE            NOT NULL,
    [EffEndDt]                  DATE            NOT NULL,
    [ReActivation581Liability]  DATE            NULL,
    [CovEffDate]                DATE            NULL,
    [StatDetCreatedUtc]         DATETIME2(2)    NOT NULL,
    [LiabilityDate]             DATE            NULL,
    [FirstLiabilityDate]        DATE            NULL,
    [StatDetRank]               BIGINT          NOT NULL,
    [StatDetOrder]              BIGINT          NOT NULL,
    [EffDtRank]                 BIGINT          NOT NULL,
    [EffDtOrder]                BIGINT          NOT NULL,
    [LiaStatusRank]             BIGINT          NOT NULL,
    [LiaStatusOrder]            BIGINT          NOT NULL
);

SET @StepStart = SYSDATETIME()

-- Use 12/31 because the Eff Date is as of the end of the day and we want the beginning of 01/01 which is the end of 12/31
-- end Dec 31 of FY-1 (= beginning of Jan 01 of FY) ([Account].[fn_StatusDeterminationFlattened_ForEmployer])
DECLARE @FirstDayOfYear DATE = DATEADD(DAY, -1, DATEFROMPARTS(@FiscalYear, 1, 1));

INSERT INTO #EmplStatDet
SELECT f.*
FROM [Account].[fn_StatusDeterminationFlattened_ForEmployer](@AnchorEmployerID) AS f
WHERE f.[EffDt] <= @FirstDayOfYear AND f.[EffEndDt] >= @FirstDayOfYear AND f.[EffDtRank] = 1

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #EmplStatDet: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

DECLARE @LiabilityDateLate DATE = 
        (SELECT TOP 1 f.LiabilityDate
            FROM #EmplStatDet AS f
            WHERE f.[EffDt] <= @FirstDayOfYear AND f.[EffEndDt] >= @FirstDayOfYear AND f.[EffDtRank] = 1)


SET @StepStart = SYSDATETIME()

-- ====================================================================================================
-- 7. LATE / MISSING REPORT CHECK  -> #TaxQuartersQwrQwraLateStatus -> @AnyLateMissingReports
-- ----------------------------------------------------------------------------------------------------
-- PURPOSE
--   One row per Anchor tax quarter, from the quarter that contains @LiabilityDateLate through FY-1,
--   with an [IsLate] flag. If any row has IsLate = 1, @AnyLateMissingReports = 1 and the rate type
--   becomes 'Max-Rate :Late Report'.
--
-- RULES
--   - A LATE report has the SAME impact as a MISSING report.
--   - A report QUALIFIES when: IsEnabled = 1 AND ReceivedDate IS NOT NULL AND
--       (ReceivedDate <= @FebMailingDateCutoff OR TaxQuarter.TaxRateTimely = 1)
--   - TaxRateTimely = 1 overrides the cutoff: a late report with TaxRateTimely = 1 still qualifies
--     and is NOT flagged.
--   - A quarter is only flagged if the Anchor was ACTIVE / REACTIVATED at least one day in it
--     ([ActiveDaysInRange] > 0) - EXCEPT the OAF rule below, which ignores active days.
--
-- CONFIRMED BUSINESS RULES (BY DESIGN - do not "fix")
--   - OAF as the latest qualifying report: if the latest qualifying report for a quarter is NOT a
--     QWR / QWRA (e.g. an OAF), the quarter is flagged late ([IsLate] 1st WHEN), even when the
--     Anchor was not active in that quarter. Do NOT add a ReportTypeId filter to the LEFT JOIN ON.
--   - No liability date at year end: when there is no Anchor status row in effect at end of Dec 31
--     of FY-1, or that row has no LiabilityDate (@LiabilityDateLate IS NULL), NO quarters are
--     checked and the Anchor cannot get 'Max-Rate :Late Report' from this check.
--   - Quarters come from [Account].[TaxQuarter] only: an ACTIVE quarter always has a TaxQuarter row,
--     so a quarter with no TaxQuarter row is not a missing report and is not checked.
--   - Active days use EffDt only: a quarter counts as active only for days inside the year-end
--     ACTIVE / REACTIVATED status row's EffDt..EffEndDt. LiabilityDate (@LiabilityDateLate) is the
--     date reporting liability should have started; it sets the FIRST quarter in range but does NOT
--     make a quarter active. Quarters between LiabilityDate and that row's EffDt get 0 active days
--     and are not flagged. Do NOT switch CTE_StatusFlattened to the full status history.
--
-- CHANGE (YYYY-MM-DD <name>) - report filters moved from WHERE into the LEFT JOIN ON
--   NOTE:  the filters are in the LEFT JOIN ON, so:
--           - Every tax quarter in range returns exactly ONE rank-1 row: the latest qualifying
--             report, or a row with NULL report columns when no report qualifies.
--           - Only-late quarters are now flagged: a quarter whose only report was received after the
--             cutoff (TaxRateTimely 0 / NULL) comes through as a NULL-report row and, if the Anchor
--             was active at least one day in it, gets [IsLate] = 1 - the same as a missing report.
--           - Disabled-only and not-received-only quarters now also count as missing.
--           - The TaxRateTimely = 1 rule is unchanged.
--   !!! Do NOT move these filters back into a WHERE: on a LEFT JOIN that removes the NULL row for
--   !!! quarters whose reports all fail, and those quarters disappear from the check.
-- ====================================================================================================

;WITH CTE_TaxQuarters AS (
-- One row per tax quarter x qualifying report, or one NULL-report row when no report qualifies.
-- [TqRptRowRank] = 1 is the latest qualifying report (or the single NULL-report row).
SELECT 
    --TQ.*
     TQ.EmployerID
    ,TQ.TaxQuarterID
    ,TQ.TaxRateTimely
    ,TQ.Year
    ,TQ.Quarter
    ,QuarterStartDate
    ,QuarterEndDate

    -- Latest qualifying report per tax quarter. The ROW_NUMBER is computed AFTER the ON-clause
    -- filters, so rank 1 is always a qualifying report (or the NULL row).
    ,ROW_NUMBER() OVER (PARTITION BY TQ.[TaxQuarterID] ORDER BY ttTQRept.[EffectiveDate] DESC, ttTQRept.[CreatedDate] DESC, ttTQRept.[TaxQuarterReportId] DESC) AS [TqRptRowRank]
    ,ttTQRept.[EffectiveDate]
    ,ttTQRept.[CreatedDate]
    ,ttTQRept.[TaxQuarterReportId]

    ,ttTQRept.[ReceivedDate]
    ,ttTQRept.[ReportTypeId]
    ,ttTQRept.IsEnabled
FROM (
-- Anchor tax quarters from the quarter that contains @LiabilityDateLate through FY-1.
-- Only quarters with an [Account].[TaxQuarter] row are checked. BY DESIGN: an ACTIVE quarter always
-- has a TaxQuarter row, so a quarter without one is not treated as a missing report.
-- NOTE: if @LiabilityDateLate is NULL (no #EmplStatDet row / no liability date) the range test is
--       NULL and NO quarters are returned, so nothing is checked. BY DESIGN (confirmed business rule).
SELECT
    ttTaxQtr.EmployerID,
    ttTaxQtr.TaxQuarterID,
    ttTaxQtr.TaxRateTimely,
    ttTaxQtr.Year as year,
    ttTaxQtr.Quarter,
    DATEFROMPARTS(ttTaxQtr.[Year], ((ttTaxQtr.Quarter - 1) * 3) + 1,1) AS QuarterStartDate,
    EOMONTH(DATEFROMPARTS(ttTaxQtr.[Year],ttTaxQtr.Quarter * 3,1))     AS QuarterEndDate

FROM Account.TaxQuarter AS ttTaxQtr
WHERE 1=1
  AND ttTaxQtr.EmployerID =  @AnchorEmployerID
  AND ttTaxQtr.[Year]    <= @FiscalYear - 1
  AND ttTaxQtr.[Year] * 10 + ttTaxQtr.Quarter >= DATEPART(YEAR, @LiabilityDateLate) * 10 + DATEPART(QUARTER, @LiabilityDateLate)
) AS TQ
    -- Qualifying-report filters belong in the ON clause (see CHANGE note above). A report that fails
    -- them (late with TaxRateTimely 0 / NULL, disabled, or not received) is treated as MISSING.
    LEFT JOIN [Account].[TaxQuarterReports] AS ttTQRept
           ON ttTQRept.[TaxQuarterID]  = TQ.[TaxQuarterID]
          AND ttTQRept.[IsEnabled]     = 1
          AND ttTQRept.[ReceivedDate]  IS NOT NULL
          AND (ttTQRept.[ReceivedDate] <= @FebMailingDateCutoff OR TQ.[TaxRateTimely] = 1)  -- TaxRateTimely = 1 overrides the cutoff
          -- BY DESIGN: no ReportTypeId filter here. Every report type (QWR / QWRA / OAF / ...) is
          --            ranked, and a latest qualifying report that is not a QWR / QWRA is flagged late
          --            by the [IsLate] 1st WHEN (confirmed business rule).
    LEFT JOIN [Configuration].[ReportType]  AS ttReptType ON ttReptType.[ReportTypeId] = ttTQRept.[ReportTypeId]  -- not referenced; kept for diagnostics
    -- (No WHERE - see CHANGE note above)
)
,CTE_StatusFlattened AS (
    -- Anchor ACTIVE / REACTIVATED status rows used to count active days per quarter.
    -- NOTE: reads #EmplStatDet, which holds ONLY the status row in effect at end of Dec 31 of FY-1.
    --       Active days are counted only inside that row's EffDt..EffEndDt.
    --       BY DESIGN (confirmed business rule): active days use EffDt only. LiabilityDate sets the
    --       first quarter in range but does NOT make a quarter active; quarters between LiabilityDate
    --       and this row's EffDt get 0 active days and are not flagged.
    --       Do NOT switch to the commented-out function source (full status history).
    SELECT *
    --FROM [Account].[fn_StatusDeterminationFlattened_ForEmployer](@AnchorEmployerID)
    FROM #EmplStatDet
    WHERE [EffDtRank] = 1
      AND [LiaStatus] IN ('ACTIVE', 'REACTIVATED')
)
-- Clamp each overlapping ACTIVE / REACTIVATED status row's range to the quarter's range, so the
-- active days in the quarter can be summed. A quarter with no overlapping active row gets one row
-- with ClampedStart / ClampedEnd = NULL (0 active days).
,CTE_ClampedOverlap AS (
SELECT 
     --q.*
     q.EmployerID
    ,q.TaxQuarterID
    ,q.TaxRateTimely
    ,q.Year
    ,q.Quarter
    ,q.QuarterStartDate
    ,q.QuarterEndDate

    ,q.[TqRptRowRank]
    ,q.[EffectiveDate]
    ,q.[CreatedDate]
    ,q.[TaxQuarterReportId]

    ,q.[ReceivedDate]
    ,q.[ReportTypeId]
    ,q.IsEnabled 
    ,c.[ClampedStart]
    ,c.[ClampedEnd]
    ,c.[EffDt]
    ,c.[EffEndDt]
FROM (
SELECT
     CTE_TaxQuarters.*
FROM CTE_TaxQuarters 
WHERE 1=1
  AND CTE_TaxQuarters.TqRptRowRank  = 1   -- one row per tax quarter (latest qualifying report or NULL row)
) AS q
LEFT JOIN CTE_StatusFlattened  AS f
    ON f.EmployerID = q.EmployerID AND f.[EffDt] <= q.[QuarterEndDate] AND f.[EffEndDt] >= q.[QuarterStartDate]
CROSS APPLY (
    SELECT
         f.[EffDt], f.[EffEndDt],
         CASE WHEN f.[EmployerID] IS NULL THEN NULL ELSE CASE WHEN f.[EffDt]    > q.[QuarterStartDate] THEN f.[EffDt]    ELSE q.[QuarterStartDate] END END AS [ClampedStart]
        ,CASE WHEN f.[EmployerID] IS NULL THEN NULL ELSE CASE WHEN f.[EffEndDt] < q.[QuarterEndDate]   THEN f.[EffEndDt] ELSE q.[QuarterEndDate]   END END AS [ClampedEnd]
) AS c
)
SELECT 
     --CTE_ClampedOverlap.*
     CTE_ClampedOverlap.EmployerID
    ,CTE_ClampedOverlap.TaxQuarterID
    ,CTE_ClampedOverlap.TaxRateTimely
    ,CTE_ClampedOverlap.Year
    ,CTE_ClampedOverlap.Quarter
    ,CTE_ClampedOverlap.QuarterStartDate
    ,CTE_ClampedOverlap.QuarterEndDate

    ,CTE_ClampedOverlap.[TqRptRowRank]
    ,CTE_ClampedOverlap.[EffectiveDate]
    ,CTE_ClampedOverlap.[CreatedDate]
    ,CTE_ClampedOverlap.[TaxQuarterReportId]

    ,CTE_ClampedOverlap.[ReceivedDate]
    ,CTE_ClampedOverlap.[ReportTypeId]
    ,CTE_ClampedOverlap.IsEnabled

    -- Days the Anchor was ACTIVE / REACTIVATED in the quarter (0 when no overlap)
    ,ISNULL(SUM(DATEDIFF(DAY, CTE_ClampedOverlap.[ClampedStart], CTE_ClampedOverlap.[ClampedEnd]) + 1), 0) AS [ActiveDaysInRange]

    ,CTE_ClampedOverlap.[ClampedStart]
    ,CTE_ClampedOverlap.[ClampedEnd]

    -- [IsLate] (first match wins):
    --   1st WHEN: the latest qualifying report is NOT a QWR / QWRA (e.g. OAF) -> late.
    --             BY DESIGN (confirmed business rule): applies regardless of liability date or active days.
    --             Not evaluated for the NULL-report row: NULL NOT IN (...) is UNKNOWN, so it falls through.
    --   2nd WHEN: quarter is on / after the liability date AND the Anchor was active at least one day
    --             AND no qualifying report (ReceivedDate NULL = missing or late) AND TaxRateTimely is
    --             not 1 -> late.
    --             NOTE: "ReceivedDate > @FebMailingDateCutoff" can no longer be true here (such reports
    --             are filtered out in the ON clause and arrive as NULL); kept as a safety net.
    ,CASE WHEN CTE_ClampedOverlap.ReportTypeId NOT IN (@ReptTypeQWR, @ReptTypeQWRA) THEN 1
          WHEN (@LiabilityDateLate <= CTE_ClampedOverlap.QuarterEndDate 
           AND ISNULL(SUM(DATEDIFF(DAY, CTE_ClampedOverlap.[ClampedStart], CTE_ClampedOverlap.[ClampedEnd]) + 1), 0) > 0 
           AND (CTE_ClampedOverlap.[ReceivedDate] IS NULL OR CTE_ClampedOverlap.[ReceivedDate] > @FebMailingDateCutoff))  
           AND (CTE_ClampedOverlap.TaxRateTimely  IS NULL OR CTE_ClampedOverlap.TaxRateTimely = 0)
          THEN 1 ELSE 0 END AS [IsLate]

INTO #TaxQuartersQwrQwraLateStatus
FROM CTE_ClampedOverlap
GROUP BY
     CTE_ClampedOverlap.EmployerID
    ,CTE_ClampedOverlap.TaxQuarterID
    ,CTE_ClampedOverlap.TaxRateTimely
    ,CTE_ClampedOverlap.Year
    ,CTE_ClampedOverlap.Quarter
    ,CTE_ClampedOverlap.QuarterStartDate
    ,CTE_ClampedOverlap.QuarterEndDate

    ,CTE_ClampedOverlap.[TqRptRowRank]
    ,CTE_ClampedOverlap.[EffectiveDate]
    ,CTE_ClampedOverlap.[CreatedDate]
    ,CTE_ClampedOverlap.[TaxQuarterReportId]

    ,CTE_ClampedOverlap.[ReceivedDate]
    ,CTE_ClampedOverlap.[ReportTypeId]
    ,CTE_ClampedOverlap.IsEnabled
    -- NOTE: grouping by ClampedStart / ClampedEnd gives one row per quarter x overlapping status row,
    --       so a quarter can have more than one row. Any row with IsLate = 1 sets @AnyLateMissingReports.
    ,CTE_ClampedOverlap.[ClampedStart]
    ,CTE_ClampedOverlap.[ClampedEnd]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #TaxQuartersQwrQwraLateStatus: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')


-- ==== TEMP TABLE NO LONGER UTILIZED: #EmplStatDet

SET @StepStart = SYSDATETIME()

MERGE INTO [Account].[TaxRateExpPayRoll] AS TARGET -- [TaxRateExpPayRoll] Employer and Full Transfers -- [IsPartial] = 0 AND [IsPartial] = 1
USING (
SELECT
     ISNULL(CASE WHEN ttTaxQtr.[RptRcvd] <= ttTaxQtr.[FebMailingDateCutoff] OR ttTaxQtr.[QtrTaxRateTimely] = 1
                 THEN ISNULL(ttTaxQtr.[UseTaxable], 0.00) 
                 END, 0.00) AS [TaxablePayRollTimely]

    ,ISNULL(ttTaxQtr.[UseTaxable], 0.00) AS [TaxablePayRoll]

    ,ISNULL(CASE WHEN ttTaxQtr.[RptRcvd] <= ttTaxQtr.[FebMailingDateCutoff] OR ttTaxQtr.[QtrTaxRateTimely] = 1
                 THEN ISNULL(ttTaxQtr.[UseTotal], 0.00)
                 END, 0.00) AS [TotalPayRollTimely]

    ,ISNULL(ttTaxQtr.[UseTotal], 0.00)   AS [TotalPayRoll]

    ,@FiscalYear AS [FiscalYear]

    ,ttTaxQtr.*

FROM (
SELECT 

     ROW_NUMBER() OVER (PARTITION BY ttTQ.[TaxQuarterID] ORDER BY ttTQRept.[EffectiveDate] ASC,  ttTQRept.[CreatedDate] ASC,  ttTQRept.[TaxQuarterReportId] ASC)  AS [RowSeq]
    ,ROW_NUMBER() OVER (PARTITION BY ttTQ.[TaxQuarterID] ORDER BY ttTQRept.[EffectiveDate] DESC, ttTQRept.[CreatedDate] DESC, ttTQRept.[TaxQuarterReportId] DESC) AS [RowRank]

    --,(ttTQ.[Year] * 10 + ttTQ.[Quarter]) AS [YearQtr]
    --,ttRptType.[Code]               AS RptType       -- VARCHAR(100)

    ,ttTQ.[TaxQuarterID]            AS [TqId]        -- BIGINT
    ,ttTQ.[CreatedDate]             AS [TqCreated]   -- DATETIEM2(2)
    ,ttTQ.[EmployerID]              AS [EmployerID]  -- INT
    ,ttTQ.[Year]                    AS [Year]        -- SMALLINT
    ,ttTQ.[Quarter]                 AS [Quarter]     -- TINYINT
 
    ,ttTQRept.[ReceivedDate]        AS [RptRcvd]     -- DATE
    ,ttTQ.[ReportDueDate]           AS [RptDue]      -- DATE

    ,ttTQ.[TaxRateTimely]           AS [QtrTaxRateTimely] -- BIT

    ,CASE WHEN ttTQRept.[ReceivedDate]   <= ttAcqEmployers.[FebMailingDateCutoff] THEN 1 ELSE 0 END AS [QtrIsTimely] -- BIT

    ,ttTQRept.[TaxQuarterReportID]  AS [TqReptId]       -- BIGINT
    ,ttTQRept.[CreatedDate]         AS [TqReptCreated]  -- DATETIME
    ,ttTQRept.[ReceivedDate]        AS [TqReptReceived] -- DATE

    ,ttTQRept.[TotalWages]          AS [Total]     -- [decimal](18, 2) -- SPRINT 36
    ,ttTQRept.[ExcessWages]         AS [Excess]    -- [decimal](18, 2) -- SPRINT 36
    ,ttTQRept.[TaxableWages]        AS [Taxable]   -- [decimal](18, 2) -- SPRINT 36
   
    ,ttTQRept.[TotalWages]          AS [UseTotal]         -- [decimal](18, 2) -- SPRINT 36
    ,ttTQRept.[ExcessWages]         AS [UseExcess]        -- [decimal](18, 2) -- SPRINT 36
    ,ttTQRept.[TaxableWages]        AS [UseTaxable]       -- [decimal](18, 2) -- SPRINT 36
    ,ttTQRept.[CreatedDate]         AS [UseCreatedDate]   -- DATETIME         -- SPRINT 36

    ,ttAcqEmployers.[TaxQtrCreatedCutoffUtc]
    ,ttAcqEmployers.[FebMailingDateCutoff]
    ,ttAcqEmployers.[AcquisitionDate]
    ,ttAcqEmployers.[AcquisitionID]
    ,ttAcqEmployers.[IsPartial]
    ,ttAcqEmployers.[FirstYearFY]

    ,NULL AS [ClientTaxablePayRoll]

  FROM [Account].[TaxQuarter]                     AS ttTQ
    INNER JOIN #ttAcqEmployers                    AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID] = ttTQ.[EmployerID]
    INNER JOIN [Account].[TaxQuarterReports]      AS ttTQRept       ON ttTQRept.[TaxQuarterID]                = ttTQ.[TaxQuarterID]

    INNER JOIN [Configuration].[ReportType]       AS ttRptType      ON ttRptType.[ReportTypeId]               = ttTQRept.[ReportTypeId]

    INNER JOIN [Account].[Employer]               AS ttEmp          ON ttEmp.[EmployerID]                     = ttTQ.[EmployerID]
    INNER JOIN [Configuration].[LiabilityStatus]  AS ttLiaStat      ON ttLiaStat.[LiabilityStatusID]          = ttEmp.[CurrentLiabilityStatusID]
    INNER JOIN [Configuration].[FinancingMethod]                    ON [FinancingMethod].[FinancingMethodID]  = ttEmp.[CurrentFinancingMethodID]

 WHERE 1=1 
   -- Only Go back 3 years for payroll
   AND ttTQRept.IsEnabled      = 1
   AND ttTQ.[Year]     <= @FiscalYear - 1
   AND ttTQ.[Year]     >= @FiscalYear - @NumberOfYears
   AND ttTQRept.[ReceivedDate] IS NOT NULL

   AND (ttTQRept.[ReceivedDate] <= ttAcqEmployers.[FebMailingDateCutoff] OR ttTQ.[TaxRateTimely] = 1)
   AND ttTQRept.[ReportTypeId] IN (@ReptTypeQWR, @ReptTypeQWRA, @ReptTypeOAF)

   -- Processing Filters
   --------------------AND [FinancingMethod].[Code] = 'EXPERIENCERATED' -- EXPERIENCERATED ADVANCEPAYMENT BILLEDMONTHLY
   AND ttLiaStat.[Code]        IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
   --AND (ttTQ.[CreatedDate]     <  ttAcqEmployers.[TaxQtrCreatedCutoffUtc])
   --AND (ttTQRept.[CreatedDate] <  ttAcqEmployers.[TaxQtrCreatedCutoffUtc])

) ttTaxQtr
WHERE 1=1  
  AND ttTaxQtr.[RowRank] = 1
  AND (ISNULL(CASE WHEN ttTaxQtr.[RptRcvd] <= ttTaxQtr.[FebMailingDateCutoff] OR ttTaxQtr.[QtrTaxRateTimely] = 1
                 THEN ISNULL(ttTaxQtr.[UseTaxable], 0.00) 
                 END, 0.00) > 0.00 -- [TaxablePayRollTimely]

      OR ISNULL(ttTaxQtr.[UseTaxable], 0.00)  > 0.00 -- [TaxablePayRoll]

      OR ISNULL(CASE WHEN ttTaxQtr.[RptRcvd] <= ttTaxQtr.[FebMailingDateCutoff] OR ttTaxQtr.[QtrTaxRateTimely] = 1
                 THEN ISNULL(ttTaxQtr.[UseTotal], 0.00)
                 END, 0.00)  > 0.00 -- [TotalPayRollTimely]

      OR ISNULL(ttTaxQtr.[UseTotal], 0.00) > 0.00) -- [TotalPayRoll]
) AS SOURCE -- SOURCE ===============================================
ON TARGET.[AnchorEmployerID] = @AnchorEmployerID      AND
   TARGET.[EmployerID]       = SOURCE.[EmployerID]    AND TARGET.[FiscalYear] = SOURCE.[FiscalYear] AND 
   TARGET.[Year]             = SOURCE.[Year]          AND TARGET.[Quarter]    = SOURCE.[Quarter]    AND 
   TARGET.[AcquisitionID]    = SOURCE.[AcquisitionID] AND TARGET.[IsPartial]  = SOURCE.[IsPartial] 
-- If no match is found, insert new data
WHEN NOT MATCHED BY TARGET THEN
INSERT ([AnchorEmployerID], [EmployerID], [FiscalYear], [Year], [Quarter], [QtrIsTimely], [QtrTaxRateTimely],
        [TaxablePayRollTimely], [TaxablePayRoll], [TotalPayRollTimely], [TotalPayRoll], [UseCreatedDate],
        [AcquisitionID], [IsPartial], [ClientTaxablePayRoll],
        [CreatedDate], [ModifiedDate]) 
VALUES
(
     @AnchorEmployerID
    ,SOURCE.[EmployerID]
    ,SOURCE.[FiscalYear]
    ,SOURCE.[Year]
    ,SOURCE.[Quarter]
    ,SOURCE.[QtrIsTimely]
    ,SOURCE.[QtrTaxRateTimely]

    ,SOURCE.[TaxablePayRollTimely]
    ,SOURCE.[TaxablePayRoll]
    ,SOURCE.[TotalPayRollTimely]
    ,SOURCE.[TotalPayRoll]
    ,SOURCE.[UseCreatedDate]

    ,SOURCE.[AcquisitionID]
    ,SOURCE.[IsPartial]
    ,SOURCE.[ClientTaxablePayRoll]

    ,GETUTCDATE()  --AS 'CreatedDate'
    ,GETUTCDATE()  --AS 'ModifiedDate'
)

-- If a match is found, update the existing row
WHEN MATCHED  
 AND (TARGET.[QtrIsTimely]                <> SOURCE.[QtrIsTimely]                 OR 
      TARGET.[QtrTaxRateTimely]           <> SOURCE.[QtrTaxRateTimely]            OR 
      TARGET.[TaxablePayRollTimely]       <> SOURCE.[TaxablePayRollTimely]        OR 
      TARGET.[TaxablePayRoll]             <> SOURCE.[TaxablePayRoll]              OR 
      TARGET.[TotalPayRollTimely]         <> SOURCE.[TotalPayRollTimely]          OR 
      TARGET.[TotalPayRoll]               <> SOURCE.[TotalPayRoll]                OR 
      TARGET.[UseCreatedDate]             <> SOURCE.[UseCreatedDate]              OR 
      TARGET.[ClientTaxablePayRoll]       <> SOURCE.[ClientTaxablePayRoll])
THEN
UPDATE SET
    TARGET.[QtrIsTimely]                = SOURCE.[QtrIsTimely],
    TARGET.[QtrTaxRateTimely]           = SOURCE.[QtrTaxRateTimely],
    TARGET.[TaxablePayRollTimely]       = SOURCE.[TaxablePayRollTimely],
    TARGET.[TaxablePayRoll]             = SOURCE.[TaxablePayRoll],
    TARGET.[TotalPayRollTimely]         = SOURCE.[TotalPayRollTimely],
    TARGET.[TotalPayRoll]               = SOURCE.[TotalPayRoll],
    TARGET.[UseCreatedDate]             = SOURCE.[UseCreatedDate],

    TARGET.[ClientTaxablePayRoll]       = SOURCE.[ClientTaxablePayRoll],

    TARGET.[ModifiedDate] = GETUTCDATE()

-- If NO match is found, DELETE 
WHEN NOT MATCHED BY SOURCE 
     AND (@FiscalYear         = TARGET.[FiscalYear])
     AND (@AnchorEmployerID   = TARGET.[AnchorEmployerID])
     AND (TARGET.[IsPartial]  = 0)
     AND (TARGET.[EmployerID] IN (SELECT XX.[PredecessorEmployerID] FROM #ttAcqEmployers AS XX))
THEN
    DELETE
OPTION (MAXDOP 1); -- Example: Force single-threaded execution

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE [Account].[TaxRateExpPayRoll]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- We only want to do this for the ANCHOR Employer

DECLARE @RcptCreatedCutoffUtc                  DATETIME2(2) = CAST(CAST(@FebMailingDateCutoff              AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
DECLARE @MaxPriorYearBenChgCreatedCutoffUtcFY  DATETIME2(2) = CAST(CAST(DATEFROMPARTS(@FiscalYear, 01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))

DECLARE @StatDetCreatedCutoffUtc       DATETIME2(2) = CAST(CAST(@FebMailingDateCutoff AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))

DECLARE @RcptCreatedCutoffUtcPrior     DATETIME2(2)             = CAST(CAST(@FebMailingDateCutoffPrior             AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
DECLARE @MaxPriorYearBenChgCreatedCutoffUtcFYPrior DATETIME2(2) = CAST(CAST(DATEFROMPARTS(@FiscalYear - 1, 01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))

DECLARE @AnyLateMissingReports BIT = 0;

IF EXISTS (SELECT 1 FROM #TaxQuartersQwrQwraLateStatus WHERE IsLate = 1)
BEGIN
    SET @AnyLateMissingReports = 1;
END;

-- ==== TEMP TABLE NO LONGER UTILIZED: #TaxQuartersQwrQwraLateStatus

-- building [Account].[TaxRateExpReserveCalc]

-- ----------------------------------------------------------------------------------------------------
-- 9a. #ttRC_StatDet - Anchor status-determination timeline
--     (was CTE_OrderedStatDet / CTE_FirstCovEffDate / CTE_StatusDetermination)
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

;WITH CTE_OrderedStatDet AS (
SELECT
     [StatusDeterminationID]
    ,[EmployerID]
    ,[LiaStatus]
    ,[FinMeth]
    ,[EffDt]
    ,[EffEndDt]
    ,[ReActivation581Liability]
    ,[CovEffDate]
    ,[StatDetCreatedUtc]
    ,[StatDetRank]
    ,[StatDetOrder]
    ,COALESCE( -- nearest earlier row that has a coverage date: the most recent one before this row (should find one within 12) -- KEPT AS-IS (QUIRK 4): looks back 12 rows max
         LAG([CovEffDate],01) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],02) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],03) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],04) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],05) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],06) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],07) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],08) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],09) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],10) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],11) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ,LAG([CovEffDate],12) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
) AS [PrevCovEffDate]
FROM (
SELECT
     ttSDRank.[StatusDeterminationID]
    ,ttSDRank.[EmployerID]
    ,ttSDRank.[LiaStatus]
    ,ttSDRank.[FinMeth]
    ,ttSDRank.[EffDt] AS [EffDt]
    ,MAX(ttSDRank.[EffEndDt]) AS [EffEndDt]
    ,MIN(ttSDRank.[ReActivation581Liability]) AS [ReActivation581Liability]
    ,MIN(ttSDRank.[CovEffDate]) AS [CovEffDate]
    ,MIN(ttSDRank.[StatDetCreatedUtc]) AS [StatDetCreatedUtc]
    ,ROW_NUMBER() OVER (PARTITION BY ttSDRank.[EmployerID] ORDER BY MIN(ttSDRank.[EffDt]) DESC) AS [StatDetRank]
    ,ROW_NUMBER() OVER (PARTITION BY ttSDRank.[EmployerID] ORDER BY MIN(ttSDRank.[EffDt]) ASC) AS [StatDetOrder]
FROM (
SELECT
    ttSDOrder.[StatusDeterminationID],
    ttSDOrder.[EmployerID] AS [EmployerID],
    ttSDOrder.[EffectiveDate] AS [EffDt],
    ttSDOrder.[CoverageEffectiveDate],
    ttSDOrder.[CreatedDate],
    ttSDOrder.[LiaStatus] AS [LiaStatus],
    ttSDOrder.[FinMeth] AS [FinMeth],
    CASE
        WHEN DateAdd(DAY, -1, LEAD(ttSDOrder.[EffectiveDate], 1, '9999-12-31') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])) < ttSDOrder.[EffectiveDate]
        THEN ttSDOrder.[EffectiveDate]
        ELSE DateAdd(DAY, -1, LEAD(ttSDOrder.[EffectiveDate], 1, '9999-12-31') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]))
        END AS [EffEndDt],
    CASE
        WHEN ttSDOrder.[CoverageEffectiveDate] IS NULL AND ttSDOrder.[LiaStatus]     IN ('ACTIVE', 'REACTIVATED') AND LAG(ttSDOrder.[LiaStatus], 1, '') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]) NOT IN ('ACTIVE', 'REACTIVATED')
        THEN ttSDOrder.[EffectiveDate]
        WHEN ttSDOrder.[CoverageEffectiveDate] IS NOT NULL AND ttSDOrder.[LiaStatus] IN ('ACTIVE', 'REACTIVATED') AND LAG(ttSDOrder.[LiaStatus], 1, '') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]) NOT IN ('ACTIVE', 'REACTIVATED')
        THEN ttSDOrder.[CoverageEffectiveDate]
        WHEN ttSDOrder.[CoverageEffectiveDate] IS NULL AND ttSDOrder.[LiaStatus]     IN ('ACTIVE', 'REACTIVATED') AND LAG(ttSDOrder.[LiaStatus], 1, '') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])  IN ('ACTIVE', 'REACTIVATED')
        THEN LAG(ttSDOrder.[CoverageEffectiveDate], 1) OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])
        END AS [ReActivation581Liability],
    ttSDOrder.[CoverageEffectiveDate] AS [CovEffDate],
    ttSDOrder.[CreatedDate] AS [StatDetCreatedUtc]
FROM (
SELECT
    ttSD1.[StatusDeterminationID],
    ttLiaStat.[LiabilityStatusID],
    ttSD1.[EmployerID],
    ttLiaStat.[Code] AS [LiaStatus],
    ttFinMeth.[Code] AS [FinMeth],
    ttSD1.[EffectiveDate],
    ttSD1.[CoverageEffectiveDate],
    ttSD1.[CreatedDate],
    ISNULL(ttFirstDates.[CovEffDt1st], ttFirstDates.[EffDt1st]) AS [LiabilityDate]
FROM (
SELECT
    ttSD0.[EmployerID],
    MIN(ttSD0.[CoverageEffectiveDate]) AS [CovEffDt1st],
    MIN(ttSD0.[EffectiveDate]) AS [EffDt1st]
FROM [Account].[StatusDetermination] AS ttSD0
    JOIN #ttAcqEmployers             AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID] = ttSD0.[EmployerID]
        AND ttAcqEmployers.[IsPartial] = 0 AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER
    JOIN [Account].[Employer]                          ON [Employer].[EmployerID] = ttSD0.[EmployerID]
WHERE ttSD0.[IsEnabled] = 1
GROUP BY ttSD0.[EmployerID]
) AS ttFirstDates
    JOIN [Account].[StatusDetermination] AS ttSD1 ON ttSD1.[EmployerID] = ttFirstDates.[EmployerID] AND ttSD1.[IsEnabled] = 1
    JOIN [Account].[Employer] AS ttEmp ON ttEmp.[EmployerID] = ttSD1.[EmployerID]
    JOIN [Configuration].[LiabilityStatus] AS ttLiaStat ON ttLiaStat.[LiabilityStatusID] = ttSD1.[LiabilityStatusID]
    JOIN [Configuration].[FinancingMethod] AS ttFinMeth ON ttFinMeth.[FinancingMethodID] = ttEmp.[CurrentFinancingMethodID]
) ttSDOrder
) as ttSDRank
GROUP BY
     ttSDRank.[StatusDeterminationID]
    ,ttSDRank.[EmployerID]
    ,ttSDRank.[EffDt]
    ,ttSDRank.[LiaStatus]
    ,ttSDRank.[FinMeth]
) AS ttStatus
),
CTE_FirstCovEffDate AS (
SELECT
    XX.[EmployerID],
    MIN(XX.[CoverageEffectiveDate]) AS [FirstLiabilityDate]
FROM [Account].[StatusDetermination] AS XX
    -- NEW: limit the scan to the Anchor (was a full-table scan; the INNER JOIN below discarded the rest)
    JOIN #ttAcqEmployers AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID] = XX.[EmployerID]
        AND ttAcqEmployers.[IsPartial] = 0 AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER
-- KEPT AS-IS (QUIRK 4): no IsEnabled filter here
GROUP BY XX.[EmployerID]
)
SELECT
     ttPrevStatus.[StatusDeterminationID]
    ,ttPrevStatus.[EmployerID]
    ,ttPrevStatus.[LiaStatus]
    ,ttPrevStatus.[FinMeth]
    ,ttPrevStatus.[EffDt]
    ,ttPrevStatus.[EffEndDt]
    ,ttPrevStatus.[ReActivation581Liability]
    ,ttPrevStatus.[CovEffDate]
    ,ttPrevStatus.[StatDetCreatedUtc]
    ,ttPrevStatus.[StatDetRank]   -- Stat Det Rank
    ,ttPrevStatus.[StatDetOrder]  -- Stat Det Order
    ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], ttPrevStatus.[EffDt]     ORDER BY ttPrevStatus.[StatDetRank] ) AS [EffDtRank]      -- Stat Det Rank  within Eff Dt
    ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], ttPrevStatus.[EffDt]     ORDER BY ttPrevStatus.[StatDetOrder]) AS [EffDtOrder]     -- Stat Det Order within Eff Dt
    ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], ttPrevStatus.[LiaStatus] ORDER BY ttPrevStatus.[StatDetRank])  AS [LiaStatusRank]  -- Stat Det Rank  within Lia Status
    ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], ttPrevStatus.[LiaStatus] ORDER BY ttPrevStatus.[StatDetOrder]) AS [LiaStatusOrder] -- Stat Det Order within Lia Status
    ,CASE WHEN ttPrevStatus.[CovEffDate] IS NULL THEN ttPrevStatus.[PrevCovEffDate] ELSE ttPrevStatus.[CovEffDate] END AS [LiabilityDate]
    ,ttFirstCovEffDate.[FirstLiabilityDate]
INTO #ttRC_StatDet
FROM CTE_OrderedStatDet AS ttPrevStatus
    JOIN CTE_FirstCovEffDate ttFirstCovEffDate ON ttPrevStatus.[EmployerID] = ttFirstCovEffDate.[EmployerID]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_StatDet: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- select * from #ttRC_StatDet -- debug select

-- ----------------------------------------------------------------------------------------------------
-- 9b. #ttRC_TaxQtr - latest timely QWR / QWRA per tax quarter + timely wages
--     (was ttTaxQtrRank -> ttTaxQtrData -> ttTaxQtrStatus)
--     The WHERE filters must stay in the same statement as the ROW_NUMBER (rank 1 = latest QUALIFYING report)
--
--     DEPENDENCY (removed [IsLate] / [SUM_IsLate]): 9b keeps ONLY timely reports
--         ReceivedDate IS NOT NULL AND (ReceivedDate <= @FebMailingDateCutoff OR TaxRateTimely = 1)
--     Because of this filter the old 9d [IsLate] flag could never be 1, so [IsLate] (9d), [SUM_IsLate]
--     (9e / 9f) and "WHEN [SUM_IsLate] > 0" (9h) were removed with no change in results.
--     If this filter is ever changed to let late reports through, that removal no longer holds:
--     re-evaluate whether 9d needs a late flag again. Late / missing reports are still covered by the
--     step 7 check (#TaxQuartersQwrQwraLateStatus -> @AnyLateMissingReports) either way.
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

SELECT DISTINCT
     ttTaxQtrData.[EmployerID]
    ,ttTaxQtrData.[FirstDayTaxQtr]
    ,ttTaxQtrData.[LastDayTaxQtr]
    ,ttTaxQtrData.[TaxQtrRcvDate]
    ,ttTaxQtrData.[TaxRateTimely]
    ,CAST(SUM(ISNULL(ttTaxQtrData.[TaxableWagesQtrTimely], 0.00)) AS MONEY) AS [TaxableWagesQtrTimely]
INTO #ttRC_TaxQtr
FROM (

SELECT DISTINCT
     ttTaxQtrRank.[EmployerID]
    ,ttTaxQtrRank.[FirstDayTaxQtr]
    ,ttTaxQtrRank.[LastDayTaxQtr]
    ,ttTaxQtrRank.[TaxQtrRcvDate]
    ,ttTaxQtrRank.[TaxRateTimely]
    ,ttTaxQtrRank.[TaxableWagesQtrTimely]
FROM (

SELECT DISTINCT
     ttTaxQtr.[EmployerID]                                                                                                 AS [EmployerID]
    ,DATEADD(QUARTER, ttTaxQtr.[Quarter] - 1, DATEFROMPARTS(ttTaxQtr.[Year], 1, 1))                                        AS [FirstDayTaxQtr]
    ,DATEADD(DAY,    -1,                      DATEADD(QUARTER, ttTaxQtr.[Quarter], DATEFROMPARTS(ttTaxQtr.[Year], 1, 1)))  AS [LastDayTaxQtr]

    ,ttTQRept.[ReceivedDate]               AS [TaxQtrRcvDate]    -- SPRINT 36
    ,ttTaxQtr.[TaxRateTimely]

    ,CAST(CASE WHEN (ttTQRept.[ReceivedDate]  IS NOT NULL AND ttTQRept.[ReceivedDate] <= @FebMailingDateCutoff)    -- SPRINT 36
                 OR (ttTaxQtr.[TaxRateTimely] IS NOT NULL AND ttTaxQtr.[TaxRateTimely] = 1)
               THEN ISNULL(ttTQRept.[TaxableWages], 0.00)
               END AS MONEY) AS [TaxableWagesQtrTimely]

    ,ROW_NUMBER() OVER (PARTITION BY ttTaxQtr.[TaxQuarterID]
                        ORDER BY ttTQRept.[EffectiveDate] DESC, ttTQRept.[CreatedDate] DESC, ttTQRept.[TaxQuarterReportId] DESC) AS [TqReptRank]

    FROM [Account].[TaxQuarter]                AS ttTaxQtr
    JOIN #ttAcqEmployers                       AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID] = ttTaxQtr.[EmployerID]
        AND ttAcqEmployers.[IsPartial] = 0 AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER

    -- QUIRK 6 (resolved): was a LEFT JOIN that the WHERE turned into an INNER JOIN; now an explicit INNER JOIN.
    --                     Unused [Configuration].[ReportType] join removed.
    INNER JOIN [Account].[TaxQuarterReports]       AS ttTQRept   ON ttTQRept.[TaxQuarterID]   = ttTaxQtr.[TaxQuarterID]
    --LEFT JOIN [Configuration].[ReportType]        AS ttReptType ON ttReptType.[ReportTypeId] = ttTQRept.[ReportTypeId]

    WHERE 1=1
      AND ttTQRept.IsEnabled       = 1
      AND ttTaxQtr.[Year]          <= @FiscalYear - 1
      AND ttTQRept.[ReceivedDate]  IS NOT NULL
      -- QUIRK 6 (resolved): #ttAcqEmployers.[FebMailingDateCutoff] = @FebMailingDateCutoff (set by [Account].[TaxRateExpAcqEmployers])
      AND (ttTQRept.[ReceivedDate] <= @FebMailingDateCutoff OR ttTaxQtr.[TaxRateTimely] = 1)
      AND ttTQRept.[ReportTypeId]  IN (@ReptTypeQWR, @ReptTypeQWRA)

) AS ttTaxQtrRank
    WHERE 1=1
    AND ttTaxQtrRank.[TqReptRank] = 1

) AS ttTaxQtrData
    GROUP BY
         ttTaxQtrData.[EmployerID]
        ,ttTaxQtrData.[FirstDayTaxQtr]
        ,ttTaxQtrData.[LastDayTaxQtr]
        ,ttTaxQtrData.[TaxQtrRcvDate]
        ,ttTaxQtrData.[TaxRateTimely]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_TaxQtr: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- select * from #ttRC_TaxQtr -- debug select

-- ----------------------------------------------------------------------------------------------------
-- 9c. #ttRC_QtrStatus - tax quarter x status-determination overlap
--     (was ttBpTqStat)
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

SELECT DISTINCT
     ttTaxQtrStatus.[EmployerID]
    ,ttTaxQtrStatus.[FirstDayTaxQtr]
    ,ttTaxQtrStatus.[LastDayTaxQtr]
    ,ttTaxQtrStatus.[TaxQtrRcvDate]
    ,ttTaxQtrStatus.[TaxRateTimely]
    ,ttTaxQtrStatus.[TaxableWagesQtrTimely]

    ,MIN(ttStatus.[EffDt])         AS [EffDt]
    ,MAX(ttStatus.[EffEndDt])      AS [EffEndDt]
    ,MIN(ttStatus.[ReActivation581Liability]) AS [UseCovEffDate]
    ,MIN(ttStatus.[CovEffDate])    AS [CovEffDate]

    ,MIN(CASE WHEN ttStatus.[LiaStatus] IN ('ACTIVE', 'REACTIVATED') THEN  ttStatus.[LiabilityDate] ELSE NULL END) AS [LiabilityDate]

    -- KEPT AS-IS (QUIRK 3): Begin and End are the same expression (StatDetOrder = 1)
    ,MAX(CASE WHEN ttStatus.[StatDetOrder]  = 1 THEN ttStatus.[LiaStatus] ELSE NULL END) AS [LiaStatusBegin]
    ,MAX(CASE WHEN ttStatus.[StatDetOrder]  = 1 THEN ttStatus.[LiaStatus] ELSE NULL END) AS [LiaStatusEnd]

    ,SUM(CASE WHEN ttStatus.[LiaStatus] IN ('ACTIVE', 'REACTIVATED') THEN  1 ELSE 0 END) AS [TotalActiveCnt]
INTO #ttRC_QtrStatus
FROM #ttRC_TaxQtr AS ttTaxQtrStatus
    INNER JOIN #ttRC_StatDet AS ttStatus ON ttStatus.[EmployerID] = ttTaxQtrStatus.[EmployerID]
                AND ttTaxQtrStatus.[FirstDayTaxQtr] <= ttStatus.[EffEndDt]
                AND ttTaxQtrStatus.[LastDayTaxQtr]  >= ttStatus.[EffDt]
GROUP BY
     ttTaxQtrStatus.[EmployerID]
    ,ttTaxQtrStatus.[FirstDayTaxQtr]
    ,ttTaxQtrStatus.[LastDayTaxQtr]
    ,ttTaxQtrStatus.[TaxQtrRcvDate]
    ,ttTaxQtrStatus.[TaxRateTimely]
    ,ttTaxQtrStatus.[TaxableWagesQtrTimely]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_QtrStatus: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- select * from #ttRC_QtrStatus -- debug select

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttRC_StatDet, #ttRC_TaxQtr  ** EXCEPT FOR DEBUG **


-- ----------------------------------------------------------------------------------------------------
-- 9d. #ttRC_QtrFlags - per quarter / base period flags
--     (was ttData)
--     !!! DO NOT ADD OR REMOVE COLUMNS: SELECT DISTINCT runs over the whole column list and the SUMs in 9e
--     !!! depend on how many rows survive it (KEPT AS-IS - QUIRK 2). IsLiable / QtrLiaStatusEnd are not used
--     !!! later but take part in the DISTINCT.
--     !!! EXCEPTION (YYYY-MM-DD <name>): [IsLate] was removed. It was 0 on EVERY row (see the DEPENDENCY
--     !!! note in 9b), and a column with the same value on every row never makes two rows distinct, so
--     !!! the DISTINCT row count - and the 9e SUMs - are unchanged. This is NOT a precedent for removing
--     !!! any other column: IsLiable / QtrLiaStatusEnd vary by row and DO affect the DISTINCT.
--     !!! DO NOT ADD PARENTHESES to the NotRateable CASEs (KEPT AS-IS - QUIRK 1: AND binds before OR).
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

SELECT DISTINCT
    ttBpTqStat.[EmployerID]

    -- Base Period Has WAges
    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  1 AND ttBpTqStat.[TaxableWagesQtrTimely] >  0.00 THEN 1 ELSE 0 END AS [NonZeroWageBasePeriod1]
    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  2 AND ttBpTqStat.[TaxableWagesQtrTimely] >  0.00 THEN 1 ELSE 0 END AS [NonZeroWageBasePeriod2]
    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  3 AND ttBpTqStat.[TaxableWagesQtrTimely] >  0.00 THEN 1 ELSE 0 END AS [NonZeroWageBasePeriod3]
    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  4 AND ttBpTqStat.[TaxableWagesQtrTimely] >  0.00 THEN 1 ELSE 0 END AS [NonZeroWageBasePeriod4]

    /*
    NOT RATEABLE AND WILL HAVE A NEW EMPLOYER OR MAX RATE
    - If the employer has 4 consecutive quarters in any base period from CY preceding rate year in any combination of the following:
        A. - Filed wage reports = zero wages
        B. - Inactive status
        C. - Not liable (based on liability date)
    */

    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  1                          AND -- Base Period

                -- A. - Filed wage reports = zero wages
                -- Zero Wages
                ttBpTqStat.[TaxableWagesQtrTimely] IS NULL OR ttBpTqStat.[TaxableWagesQtrTimely] = 0.00 OR

                -- B. - Inactive status
                -- Not Active at end of qtr / Never Active in Quarter
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END 
                NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

                -- C. - Not liable (based on liability date)
                -- Not Liable - Liability Date > [LastDayTaxQtr]
                ttBpTqStat.[LiabilityDate] IS NULL OR ttBpTqStat.[LiabilityDate] > ttBpTqStat.[LastDayTaxQtr]

            THEN 1 ELSE 0 END AS [NotRateableQtrCntBasePeriod1]

    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  2                          AND -- Base Period
                -- A. - Filed wage reports = zero wages
                -- Zero Wages
                ttBpTqStat.[TaxableWagesQtrTimely] IS NULL OR ttBpTqStat.[TaxableWagesQtrTimely] = 0.00 OR

                -- B. - Inactive status
                -- Not Active at end of qtr / Never Active in Quarter
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END 
                NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

                -- C. - Not liable (based on liability date)
                -- Not Liable - Liability Date > [LastDayTaxQtr]
                ttBpTqStat.[LiabilityDate] IS NULL OR ttBpTqStat.[LiabilityDate] > ttBpTqStat.[LastDayTaxQtr]

            THEN 1 ELSE 0 END AS [NotRateableQtrCntBasePeriod2]

    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  3                          AND -- Base Period
                -- A. - Filed wage reports = zero wages
                -- Zero Wages
                ttBpTqStat.[TaxableWagesQtrTimely] IS NULL OR ttBpTqStat.[TaxableWagesQtrTimely] = 0.00 OR

                -- B. - Inactive status
                -- Not Active at end of qtr / Never Active in Quarter
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END 
                NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

                -- C. - Not liable (based on liability date)
                -- Not Liable - Liability Date > [LastDayTaxQtr]
                ttBpTqStat.[LiabilityDate] IS NULL OR ttBpTqStat.[LiabilityDate] > ttBpTqStat.[LastDayTaxQtr]

            THEN 1 ELSE 0 END AS [NotRateableQtrCntBasePeriod3]

    ,CASE WHEN ttBasePeriod.[BasePeriodDateQtr]  =  4                          AND -- Base Period
                -- A. - Filed wage reports = zero wages
                -- Zero Wages
                ttBpTqStat.[TaxableWagesQtrTimely] IS NULL OR ttBpTqStat.[TaxableWagesQtrTimely] = 0.00 OR

                -- B. - Inactive status
                -- Not Active at end of qtr / Never Active in Quarter
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END 
                NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

                -- C. - Not liable (based on liability date)
                -- Not Liable - Liability Date > [LastDayTaxQtr]
                ttBpTqStat.[LiabilityDate] IS NULL OR ttBpTqStat.[LiabilityDate] > ttBpTqStat.[LastDayTaxQtr]

            THEN 1 ELSE 0 END AS [NotRateableQtrCntBasePeriod4]

    ,CASE WHEN ttBpTqStat.[LiabilityDate] <= ttBpTqStat.[LastDayTaxQtr] AND ttBpTqStat.[TotalActiveCnt] > 0      THEN 1 ELSE 0 END AS [IsLiable]

    -- [IsLate] REMOVED - was always 0 (see the DEPENDENCY note in 9b). Late / missing reports are
    -- checked in step 7 (@AnyLateMissingReports).

    ,CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END [QtrLiaStatusEnd]
INTO #ttRC_QtrFlags
FROM #ttRC_QtrStatus AS ttBpTqStat -- Base Period Tax Quarter Status
    LEFT JOIN #BasePeriod AS ttBasePeriod ON ttBasePeriod.[BasePeriodDatePrior] = ttBpTqStat.[FirstDayTaxQtr] AND ttBasePeriod.[BasePeriodDatePriorEnd] = ttBpTqStat.[LastDayTaxQtr]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_QtrFlags: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

--select * from #ttRC_QtrFlags -- debug select

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttRC_QtrStatus  ** EXCEPT FOR DEBUG **

-- ----------------------------------------------------------------------------------------------------
-- 9e. #ttRC_BasePeriodSum - flags rolled up per employer
--     (was ttDataSum)
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

SELECT DISTINCT
     ttData.[EmployerID]

    -- Base Period Has WAges
    ,MAX(ttData.[NonZeroWageBasePeriod1]) AS [MAX_NonZeroWageBasePeriod1]
    ,MAX(ttData.[NonZeroWageBasePeriod2]) AS [MAX_NonZeroWageBasePeriod2]
    ,MAX(ttData.[NonZeroWageBasePeriod3]) AS [MAX_NonZeroWageBasePeriod3]
    ,MAX(ttData.[NonZeroWageBasePeriod4]) AS [MAX_NonZeroWageBasePeriod4]

    ,SUM(ttData.[NotRateableQtrCntBasePeriod1]) AS [SUM_NotRateableQtrCntBasePeriod1]
    ,SUM(ttData.[NotRateableQtrCntBasePeriod2]) AS [SUM_NotRateableQtrCntBasePeriod2]
    ,SUM(ttData.[NotRateableQtrCntBasePeriod3]) AS [SUM_NotRateableQtrCntBasePeriod3]
    ,SUM(ttData.[NotRateableQtrCntBasePeriod4]) AS [SUM_NotRateableQtrCntBasePeriod4]

    -- [SUM_IsLate] REMOVED - was always 0 (see the DEPENDENCY note in 9b)
INTO #ttRC_BasePeriodSum
FROM #ttRC_QtrFlags AS ttData
GROUP BY
    ttData.[EmployerID]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_BasePeriodSum: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

--select * from #ttRC_BasePeriodSum -- debug select

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttRC_QtrFlags  ** EXCEPT FOR DEBUG **

SET @StepStart = SYSDATETIME()

-- ----------------------------------------------------------------------------------------------------
-- 9f. #ttRC_Money - totals from TaxRateExpTaxesPaid / TaxRateExpBenChg / TaxRateExpPayRoll
--     (was ttSumTaxesPaid -> ttSumBenChg -> ttMoney)
--     Each OUTER APPLY aggregates its own table first, so no fan-out (same as today's GROUP BY layers).
--     ISNULL(SUM(...), 0.00) on every column: today a missing match goes through a LEFT JOIN and
--     SUM(ISNULL(NULL, 0)) = 0.00; an OUTER APPLY over no rows returns NULL without the ISNULL.
--
--     WHAT COUNTS TOWARD THE ANCHOR (confirmed business rules) - the ANCHOR's own data only:
--       TaxesPaid / TaxesPaidPrior : Anchor ONLY  (EmployerID = Anchor, IsPartial = 0)
--       Benefit charges            : Anchor ONLY  (EmployerID = Anchor, IsPartial = 0)
--       Payroll (ratio denominator): Anchor ONLY  (EmployerID = Anchor, IsPartial = 0)
--       Adjustments (9g)           : Anchor ONLY  ([Account].[RunningReserve] for the Anchor EmployerID)
--     All three OUTER APPLYs use the same filter: AnchorEmployerID = Anchor, IsPartial = 0,
--     EmployerID = ttDataSum.[EmployerID] (always the Anchor - see the ONLY ANCHOR EMPLOYER join), FiscalYear = FY.
--     In the TaxRateExp* tables, AnchorEmployerId = EmployerID is the Anchor's own data; any other EmployerID
--     is a predecessor's data for that Anchor. Predecessor data (FULL and PARTIAL) is NOT added here: it is
--     returned in result sets #1 / #2 (TransferExperience, with PercentTransfer) and handled by the app code.
-- ----------------------------------------------------------------------------------------------------

SELECT
     ttDataSum.[EmployerID]

    ,ttDataSum.[MAX_NonZeroWageBasePeriod1]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod2]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod3]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod4]

    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod1]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod2]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod3]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod4]

    -- [SUM_IsLate] REMOVED - was always 0 (see the DEPENDENCY note in 9b)

    -- ttTaxesPaid
    ,ttTaxesPaid.[TaxesPaid]
    ,ttTaxesPaid.[TaxesPaidPrior]

    -- ttBenChg
    ,ttBenChg.[BenefitsChargedClient]
    ,ttBenChg.[BenefitsRelievedClient]
    ,ttBenChg.[BenefitsTotalClient]
    ,ttBenChg.[BenefitsChargedClientPrior]
    ,ttBenChg.[BenefitsRelievedClientPrior]
    ,ttBenChg.[BenefitsTotalClientPrior]

    -- ttPayRoll
    ,ttPayRoll.[TaxablePayRoll]
    ,ttPayRoll.[TaxablePayRollTimely]
    ,ttPayRoll.[TaxablePayRoll3YrAvg]
    ,ttPayRoll.[TaxablePayRollTimely3YrAvg]

    ,@FiscalYear - 3 AS [Year1]
    ,ttPayRoll.[TaxablePayRollTimelyYear1]
    ,ttPayRoll.[TaxablePayRollYear1]
    ,ttPayRoll.[TotalPayRollTimelyYear1]
    ,ttPayRoll.[TotalPayRollYear1]

    ,@FiscalYear - 2 AS [Year2]
    ,ttPayRoll.[TaxablePayRollTimelyYear2]
    ,ttPayRoll.[TaxablePayRollYear2]
    ,ttPayRoll.[TotalPayRollTimelyYear2]
    ,ttPayRoll.[TotalPayRollYear2]

    ,@FiscalYear - 1 AS [Year3]
    ,ttPayRoll.[TaxablePayRollTimelyYear3]
    ,ttPayRoll.[TaxablePayRollYear3]
    ,ttPayRoll.[TotalPayRollTimelyYear3]
    ,ttPayRoll.[TotalPayRollYear3]
INTO #ttRC_Money
FROM #ttRC_BasePeriodSum AS ttDataSum
INNER JOIN #ttAcqEmployers AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID] = ttDataSum.[EmployerID]
        AND ttAcqEmployers.[IsPartial] = 0 AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER

OUTER APPLY ( -- ttTaxesPaid: Anchor ONLY (predecessor taxes are handled in the app code via result set #1)
    SELECT
         ISNULL(CAST(SUM(ISNULL(tp.[TaxesPaid],      0.00)) AS MONEY), 0.00) AS [TaxesPaid]
        ,ISNULL(CAST(SUM(ISNULL(tp.[TaxesPaidPrior], 0.00)) AS MONEY), 0.00) AS [TaxesPaidPrior]
    FROM [Account].[TaxRateExpTaxesPaid] AS tp

    WHERE tp.[AnchorEmployerId] = ttAcqEmployers.[AnchorEmployerId]
      AND tp.[IsPartial]        = 0 -- exclude [IsPartial] = 1 (Partial Predecessors) - Handled in App Code
      AND tp.[EmployerID]       = ttDataSum.[EmployerID]
      AND tp.[FiscalYear]       = @FiscalYear
) AS ttTaxesPaid

OUTER APPLY ( -- ttBenChg: Anchor ONLY (predecessor charges are handled in the app code via result set #1)
    SELECT
         ISNULL(CAST(SUM(ISNULL(bc.[BenefitsChargedClient],       0.00)) AS MONEY), 0.00)                                                        AS [BenefitsChargedClient]
        ,ISNULL(CAST(SUM(ISNULL(bc.[BenefitsRelievedClient],      0.00)) AS MONEY), 0.00)                                                        AS [BenefitsRelievedClient]
        ,ISNULL(CAST(SUM(ISNULL(bc.[BenefitsChargedClient],       0.00) - ISNULL(bc.[BenefitsRelievedClient],      0.00)) AS MONEY), 0.00) AS [BenefitsTotalClient]

        ,ISNULL(CAST(SUM(ISNULL(bc.[BenefitsChargedClientPrior],  0.00)) AS MONEY), 0.00)                                                        AS [BenefitsChargedClientPrior]
        ,ISNULL(CAST(SUM(ISNULL(bc.[BenefitsRelievedClientPrior], 0.00)) AS MONEY), 0.00)                                                        AS [BenefitsRelievedClientPrior]
        ,ISNULL(CAST(SUM(ISNULL(bc.[BenefitsChargedClientPrior],  0.00) - ISNULL(bc.[BenefitsRelievedClientPrior], 0.00)) AS MONEY), 0.00) AS [BenefitsTotalClientPrior]
    FROM [Account].[TaxRateExpBenChg] AS bc
    WHERE bc.[AnchorEmployerID] = @AnchorEmployerID
      AND bc.[IsPartial]        = 0 -- exclude [IsPartial] = 1 (Partial Predecessors) - Handled in App Code
      AND bc.[EmployerID]       = ttDataSum.[EmployerID]
      AND bc.[FiscalYear]       = @FiscalYear
) AS ttBenChg

OUTER APPLY ( -- ttPayRoll: Anchor ONLY (predecessor payroll is handled in the app code via result sets #1 / #2)
    SELECT
         ISNULL(CAST(SUM(ISNULL(pr.[TaxablePayRoll],       0.00))        AS MONEY), 0.00) AS [TaxablePayRoll]
        ,ISNULL(CAST(SUM(ISNULL(pr.[TaxablePayRollTimely], 0.00))        AS MONEY), 0.00) AS [TaxablePayRollTimely]
        ,ISNULL(CAST(SUM(ISNULL(pr.[TaxablePayRoll],       0.00) / 3.00) AS MONEY), 0.00) AS [TaxablePayRoll3YrAvg]
        ,ISNULL(CAST(SUM(ISNULL(pr.[TaxablePayRollTimely], 0.00) / 3.00) AS MONEY), 0.00) AS [TaxablePayRollTimely3YrAvg]

        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 3 THEN ISNULL(pr.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TaxablePayRollTimelyYear1]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 3 THEN ISNULL(pr.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TaxablePayRollYear1]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 3 THEN ISNULL(pr.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TotalPayRollTimelyYear1]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 3 THEN ISNULL(pr.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TotalPayRollYear1]

        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 2 THEN ISNULL(pr.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TaxablePayRollTimelyYear2]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 2 THEN ISNULL(pr.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TaxablePayRollYear2]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 2 THEN ISNULL(pr.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TotalPayRollTimelyYear2]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 2 THEN ISNULL(pr.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TotalPayRollYear2]

        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 1 THEN ISNULL(pr.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TaxablePayRollTimelyYear3]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 1 THEN ISNULL(pr.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TaxablePayRollYear3]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 1 THEN ISNULL(pr.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TotalPayRollTimelyYear3]
        ,ISNULL(CAST(SUM(CASE WHEN pr.[Year] = @FiscalYear - 1 THEN ISNULL(pr.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY), 0.00) AS [TotalPayRollYear3]
    FROM [Account].[TaxRateExpPayRoll] AS pr
    WHERE pr.[AnchorEmployerID] = @AnchorEmployerID
      AND pr.[IsPartial]        = 0 -- exclude [IsPartial] = 1 (Partial Predecessors) - Handled in App Code
      AND pr.[EmployerID]       = ttDataSum.[EmployerID]
      AND pr.[FiscalYear]       = @FiscalYear
) AS ttPayRoll

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_Money: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- select * from #ttRC_Money -- debug select

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttRC_BasePeriodSum  ** EXCEPT FOR DEBUG **

-- ----------------------------------------------------------------------------------------------------
-- 9g. #ttRC_Adjust - [Account].[RunningReserve] adjustments, ONE pass (was 8 correlated subqueries)
--     PAYMENTADJUST adds, BENEFITADJUST subtracts (signed buckets only).
--     Anchor ONLY (confirmed business rule): #ttRC_Money holds only the Anchor EmployerID, so predecessor
--     adjustments do not count.
--     NOTE: PriorReserve uses AdjPriorReserve (YEAR <= FY-2, prior cutoffs).
--           Reserve and the ReserveRatio numerator both use AdjPriorReserve + AdjReserve
--           (AdjReserve = YEAR = FY-1, current cutoffs).
--           A YEAR <= FY-2 adjustment posted between the prior and current cutoffs is NOT counted this year;
--           it is picked up next year, when it falls before that year's prior cutoff (PriorReserve).
--     NOTE: BenefitsTotalClientAdjust is a WINDOW (>= FYPrior cutoff AND < FY cutoff).
--     SELECT INTO (not CREATE TABLE) so each column keeps the exact type of the original expression.
--     "Null value is eliminated by an aggregate" warnings are expected (CASE with no ELSE) and harmless.
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

SELECT
     XX.[EmployerID]

    -- PriorReserve adjustments: YEAR <= FY-2, prior-year cutoffs, signed
    ,ISNULL(SUM(CASE WHEN XX.[YEAR] <= @FiscalYear - 2
                      AND XX.[AdjustmentUtcDate] < CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN @RcptCreatedCutoffUtcPrior ELSE @MaxPriorYearBenChgCreatedCutoffUtcFYPrior END
                     THEN ISNULL(XX.[Adjustment], 0.00) * CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN 1.00 ELSE -1.00 END
                     END), 0.00) AS [AdjPriorReserve]

    -- Reserve adjustments: YEAR = FY-1, current cutoffs, signed
    ,ISNULL(SUM(CASE WHEN XX.[YEAR] = @FiscalYear - 1
                      AND XX.[AdjustmentUtcDate] < CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN @RcptCreatedCutoffUtc      ELSE @MaxPriorYearBenChgCreatedCutoffUtcFY      END
                     THEN ISNULL(XX.[Adjustment], 0.00) * CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN 1.00 ELSE -1.00 END
                     END), 0.00) AS [AdjReserve]

    -- TaxesPaidAdjust: PAYMENTADJUST, YEAR = FY-1, < @RcptCreatedCutoffUtc (unsigned)
    ,ISNULL(SUM(CASE WHEN XX.[Component] = 'PAYMENTADJUST'
                      AND XX.[YEAR] = @FiscalYear - 1
                      AND XX.[AdjustmentUtcDate] <  @RcptCreatedCutoffUtc
                     THEN ISNULL(XX.[Adjustment], 0.00)
                     END), 0.00) AS [TaxesPaidAdjust]

    -- TaxesPaidPriorAdjust: PAYMENTADJUST, YEAR <= FY-2, < @RcptCreatedCutoffUtcPrior (unsigned)
    ,ISNULL(SUM(CASE WHEN XX.[Component] = 'PAYMENTADJUST'
                      AND XX.[YEAR] <= @FiscalYear - 2
                      AND XX.[AdjustmentUtcDate] < @RcptCreatedCutoffUtcPrior
                     THEN ISNULL(XX.[Adjustment], 0.00)
                     END), 0.00) AS [TaxesPaidPriorAdjust]

    -- BenefitsTotalClientAdjust: BENEFITADJUST, YEAR = FY-1, window FYPrior <= date < FY (unsigned)
    ,ISNULL(SUM(CASE WHEN XX.[Component] = 'BENEFITADJUST'
                      AND XX.[YEAR] = @FiscalYear - 1
                      AND XX.[AdjustmentUtcDate] >= @MaxPriorYearBenChgCreatedCutoffUtcFYPrior
                      AND XX.[AdjustmentUtcDate] <  @MaxPriorYearBenChgCreatedCutoffUtcFY
                     THEN ISNULL(XX.[Adjustment], 0.00)
                     END), 0.00) AS [BenefitsTotalClientAdjust]

    -- BenefitsTotalClientPriorAdjust: BENEFITADJUST, YEAR <= FY-2, < FYPrior cutoff (unsigned)
    ,ISNULL(SUM(CASE WHEN XX.[Component] = 'BENEFITADJUST'
                      AND XX.[YEAR] <= @FiscalYear - 2
                      AND XX.[AdjustmentUtcDate] < @MaxPriorYearBenChgCreatedCutoffUtcFYPrior
                     THEN ISNULL(XX.[Adjustment], 0.00)
                     END), 0.00) AS [BenefitsTotalClientPriorAdjust]
INTO #ttRC_Adjust
FROM [Account].[RunningReserve] AS XX
    INNER JOIN (SELECT DISTINCT [EmployerID] FROM #ttRC_Money) AS ttEmp ON ttEmp.[EmployerID] = XX.[EmployerID]
WHERE XX.[Component] IN ('PAYMENTADJUST', 'BENEFITADJUST')
GROUP BY XX.[EmployerID]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_Adjust: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- select * from #ttRC_Adjust -- debug select 

-- ----------------------------------------------------------------------------------------------------
-- 9h. #ttRC_Source - final SOURCE rows for the MERGE (same columns, same order as today's SOURCE)
--     (was ttReserveCalc + SOURCE)
--     PROVISIONAL, ANCHOR-ONLY: PriorReserve, Reserve, ReserveRatio and RateTypeDetermined here use the
--     Anchor's own data only. The APPLICATION adds the acquisition experience (result sets #1 / #2) and
--     calculates the final Reserve, ReserveRatio and Rate Type (see PROCEDURE vs. APPLICATION in the header).
--     BEHAVIOUR CHANGE (YYYY-MM-DD <name>):
--       - Reserve = PriorReserve + (TaxesPaid - BenefitsTotalClient) + AdjReserve.
--         The original left the PriorReserve adjustments (AdjPriorReserve) out of Reserve. Reserve now changes
--         by exactly AdjPriorReserve, which can change RateTypeDetermined where Reserve crosses 0.00
--         (New-Rate vs Max-Rate in the Inactive / $0.00 Report branches).
--       - ReserveRatio numerator = Reserve. The original used YEAR <= FY-1 adjustments with the CURRENT
--         cutoffs for every year, so the ratio now changes by MINUS the YEAR <= FY-2 adjustments posted
--         between the prior and current cutoffs (those are counted next year instead).
--       - PriorReserve is unchanged.
--     Removed: LEFT JOIN [Account].[vw_EmployerStatusDetFromToLiability] - no column was used.
--     !!! Before removing it, confirm it never returns > 1 row per EmployerID for this filter:
--         SELECT [EmployerID], COUNT(*) FROM [Account].[vw_EmployerStatusDetFromToLiability]
--         WHERE [StatDetCreatedUtc] < @StatDetCreatedCutoffUtc AND [StatDetRank] = 1
--         GROUP BY [EmployerID] HAVING COUNT(*) > 1
--     (@StatDetCreatedCutoffUtc is then no longer used here; keep the DECLARE if anything else uses it)
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

SELECT -- ttReserveCalc
     @FiscalYear       AS [FiscalYear]
    ,@AnchorEmployerID AS [AnchorEmployerID]
    ,ttMoney.[EmployerID]

    -- ttTaxesPaid
    ,ttMoney.[TaxesPaid]
    ,ISNULL(ttAdj.[TaxesPaidAdjust], 0.00)                AS [TaxesPaidAdjust]
    ,ttMoney.[TaxesPaidPrior]
    ,ISNULL(ttAdj.[TaxesPaidPriorAdjust], 0.00)           AS [TaxesPaidPriorAdjust]

    -- ttBenChg
    ,ttMoney.[BenefitsChargedClient]
    ,ttMoney.[BenefitsRelievedClient]
    ,ttMoney.[BenefitsTotalClient]
    ,ISNULL(ttAdj.[BenefitsTotalClientAdjust], 0.00)      AS [BenefitsTotalClientAdjust]

    ,ttMoney.[BenefitsChargedClientPrior]
    ,ttMoney.[BenefitsRelievedClientPrior]
    ,ttMoney.[BenefitsTotalClientPrior]
    ,ISNULL(ttAdj.[BenefitsTotalClientPriorAdjust], 0.00) AS [BenefitsTotalClientPriorAdjust]

    -- ttPayRoll
    ,ttMoney.[TaxablePayRoll]
    ,ttMoney.[TaxablePayRollTimely]
    ,ttMoney.[TaxablePayRoll3YrAvg]
    ,ttMoney.[TaxablePayRollTimely3YrAvg]

    ,ttMoney.[Year1]
    ,ttMoney.[TaxablePayRollTimelyYear1]
    ,ttMoney.[TaxablePayRollYear1]
    ,ttMoney.[TotalPayRollTimelyYear1]
    ,ttMoney.[TotalPayRollYear1]

    ,ttMoney.[Year2]
    ,ttMoney.[TaxablePayRollTimelyYear2]
    ,ttMoney.[TaxablePayRollYear2]
    ,ttMoney.[TotalPayRollTimelyYear2]
    ,ttMoney.[TotalPayRollYear2]

    ,ttMoney.[Year3]
    ,ttMoney.[TaxablePayRollTimelyYear3]
    ,ttMoney.[TaxablePayRollYear3]
    ,ttMoney.[TotalPayRollTimelyYear3]
    ,ttMoney.[TotalPayRollYear3]

    ,ttCalc.[PriorReserve]
    ,ttCalc.[Reserve]
    ,CASE WHEN ttCalc.[ReserveRatio] IS NULL            THEN NULL
          WHEN ttCalc.[ReserveRatio] > @maxReserveRatio THEN CAST(@maxReserveRatio      AS DECIMAL(8, 4))
          WHEN ttCalc.[ReserveRatio] < @minReserveRatio THEN CAST(@minReserveRatio      AS DECIMAL(8, 4))
          ELSE                                               CAST(ttCalc.[ReserveRatio] AS DECIMAL(8, 4))
          END AS [ReserveRatio]

    -- If any quarterly wage report required to be filed from initial liability date has not been filed by the cut-off date,
    -- -- These employers will be assigned the maximum rate.
    ,CASE WHEN @AnyLateMissingReports  > 0 THEN  @RateTypeMaxRate1 -- MAX RATE: Has at least one late / missing report (step 7)
          -- "WHEN [SUM_IsLate] > 0" REMOVED - could never be true (see the DEPENDENCY note in 9b)
          /*
          NOT RATEABLE AND WILL HAVE A NEW EMPLOYER OR MAX RATE
          - If the employer has 4 consecutive quarters in any base period from CY preceding rate year in any combination of the following:
              A. - Filed wage reports = zero wages
              B. - Inactive status
              C. - Not liable (based on liability date)
          */
          WHEN -- B. - Inactive status  C. - Not liable (based on liability date)
              ttMoney.[SUM_NotRateableQtrCntBasePeriod1] = 4 OR
              ttMoney.[SUM_NotRateableQtrCntBasePeriod2] = 4 OR
              ttMoney.[SUM_NotRateableQtrCntBasePeriod3] = 4 OR
              ttMoney.[SUM_NotRateableQtrCntBasePeriod4] = 4
          THEN CASE WHEN (ttCalc.[Reserve] >= 0.00) THEN  @RateTypeNewRate1  ELSE @RateTypeMaxRate2 END -- { NEW RATE: Reserve >= 0.00, MAX RATE: Reserve < 0.00 }

          WHEN -- A. - Filed wage reports = zero wages
              -- Not Chargeable - To Be Chargeable need to have at least one Non Zero Wage in each Base Period
              (ttMoney.[MAX_NonZeroWageBasePeriod1] + ttMoney.[MAX_NonZeroWageBasePeriod2] +
               ttMoney.[MAX_NonZeroWageBasePeriod3] + ttMoney.[MAX_NonZeroWageBasePeriod4] ) <> 4
          THEN CASE WHEN (ttCalc.[Reserve] >= 0.00) THEN  @RateTypeNewRate2  ELSE @RateTypeMaxRate3 END -- { NEW RATE: Reserve >= 0.00, MAX RATE: Reserve < 0.00 }

          WHEN ttCalc.[ReserveRatio] IS NULL   THEN  @RateTypeMaxRate0 -- MAX RATE: [TaxablePayRollTimely3YrAvg] <= 0.00 -- 3 year timely wages <= 0.00

          -- One quarter in each of the 4 Base periods above has a quarterly report filed with wages > 0.
          WHEN ttMoney.[MAX_NonZeroWageBasePeriod1] = 1 AND ttMoney.[MAX_NonZeroWageBasePeriod2] = 1 AND
               ttMoney.[MAX_NonZeroWageBasePeriod3] = 1 AND ttMoney.[MAX_NonZeroWageBasePeriod4] = 1 THEN @RateTypeIsRated -- EXPERIENCE RATED: Reserve Ratio Lookup

          ELSE @RateTypeUndetermined
          END AS [RateTypeDetermined]
INTO #ttRC_Source
FROM #ttRC_Money AS ttMoney
    LEFT JOIN #ttRC_Adjust AS ttAdj ON ttAdj.[EmployerID] = ttMoney.[EmployerID]
CROSS APPLY (
    SELECT
         -- [PriorReserve]
         (ttMoney.[TaxesPaidPrior] - ttMoney.[BenefitsTotalClientPrior] + ISNULL(ttAdj.[AdjPriorReserve], 0.00)) -- Prior Reserve (FY-2)
         AS [PriorReserve]

         -- [Reserve]
        ,(ttMoney.[TaxesPaidPrior] - ttMoney.[BenefitsTotalClientPrior] + ISNULL(ttAdj.[AdjPriorReserve], 0.00)) + -- Prior Reserve (FY-2) + Reserve (FY -1)
         (ttMoney.[TaxesPaid]      - ttMoney.[BenefitsTotalClient]      + ISNULL(ttAdj.[AdjReserve],      0.00))
         AS [Reserve]

         -- [ReserveRatio] (raw, before clamping) - numerator = Reserve (same expression as [Reserve] above)
        ,CASE WHEN ttMoney.[TaxablePayRollTimely3YrAvg] <= 0.00 THEN NULL
              WHEN (ttMoney.[TaxesPaidPrior] - ttMoney.[BenefitsTotalClientPrior] + ISNULL(ttAdj.[AdjPriorReserve], 0.00)) + -- Prior Reserve (FY-2) + Reserve (FY -1)
                   (ttMoney.[TaxesPaid]      - ttMoney.[BenefitsTotalClient]      + ISNULL(ttAdj.[AdjReserve],      0.00)) = 0.00 THEN 0.00
              ELSE ROUND((
                   (
                    (ttMoney.[TaxesPaidPrior] - ttMoney.[BenefitsTotalClientPrior] + ISNULL(ttAdj.[AdjPriorReserve], 0.00)) + -- Prior Reserve (FY-2) + Reserve (FY -1)
                    (ttMoney.[TaxesPaid]      - ttMoney.[BenefitsTotalClient]      + ISNULL(ttAdj.[AdjReserve],      0.00))
                   ) / ttMoney.[TaxablePayRollTimely3YrAvg]), 4)
              END AS [ReserveRatio]
) AS ttCalc

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('SELECT INTO #ttRC_Source: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')


--select * from #ttRC_Source -- debug select 
--WHERE [AnchorEmployerID] = @AnchorEmployerID AND [EmployerID] = @AnchorEmployerID AND [FiscalYear] = @FiscalYear


-- ==== TEMP TABLE NO LONGER UTILIZED: #ttRC_Money, #ttRC_Adjust  ** EXCEPT FOR DEBUG **


-- ----------------------------------------------------------------------------------------------------
-- 9i. MERGE [Account].[TaxRateExpReserveCalc] - body UNCHANGED, only the USING source is replaced
-- ----------------------------------------------------------------------------------------------------
SET @StepStart = SYSDATETIME()

MERGE INTO [Account].[TaxRateExpReserveCalc] AS TARGET
USING #ttRC_Source AS SOURCE
ON TARGET.[AnchorEmployerID]  = SOURCE.[AnchorEmployerID]   AND
   TARGET.[EmployerID]       = SOURCE.[EmployerID]         AND
   TARGET.[FiscalYear]       = SOURCE.[FiscalYear]
-- If no match is found, insert new data
WHEN NOT MATCHED BY TARGET THEN
INSERT ([AnchorEmployerID]
        ,[EmployerID]
        ,[FiscalYear]

        -- ttTaxesPaid
        ,[TaxesPaid]
        ,[TaxesPaidAdjust]
        ,[TaxesPaidPrior]
        ,[TaxesPaidPriorAdjust]

        -- ttBenChg
        ,[BenefitsChargedClient]
        ,[BenefitsRelievedClient]
        ,[BenefitsTotalClient]
        ,[BenefitsTotalClientAdjust]

        ,[BenefitsChargedClientPrior]
        ,[BenefitsRelievedClientPrior]
        ,[BenefitsTotalClientPrior]
        ,[BenefitsTotalClientPriorAdjust]

        -- ttPayRoll
        ,[TaxablePayRoll]
        ,[TaxablePayRollTimely]
        ,[TaxablePayRoll3YrAvg]
        ,[TaxablePayRollTimely3YrAvg]

        ,[Year1]
        ,[TaxablePayRollTimelyYear1]
        ,[TaxablePayRollYear1]
        ,[TotalPayRollTimelyYear1]
        ,[TotalPayRollYear1]

        ,[Year2]
        ,[TaxablePayRollTimelyYear2]
        ,[TaxablePayRollYear2]
        ,[TotalPayRollTimelyYear2]
        ,[TotalPayRollYear2]

        ,[Year3]
        ,[TaxablePayRollTimelyYear3]
        ,[TaxablePayRollYear3]
        ,[TotalPayRollTimelyYear3]
        ,[TotalPayRollYear3]

        ,[PriorReserve]
        ,[Reserve]
        ,[ReserveRatio]

        ,[RateTypeDetermined]
        ,[FebMailingDateCutoff]

        ,[CreatedDate], [ModifiedDate])
VALUES
(
     SOURCE.[AnchorEmployerID]
    ,SOURCE.[EmployerID]
    ,SOURCE.[FiscalYear]

    -- TaxesPaid
    ,ISNULL(SOURCE.[TaxesPaid],                   0.00)
    ,ISNULL(SOURCE.[TaxesPaidAdjust],             0.00)
    ,ISNULL(SOURCE.[TaxesPaidPrior],              0.00)
    ,ISNULL(SOURCE.[TaxesPaidPriorAdjust],        0.00)

    -- BenChg
    ,ISNULL(SOURCE.[BenefitsChargedClient],       0.00)
    ,ISNULL(SOURCE.[BenefitsRelievedClient],      0.00)
    ,ISNULL(SOURCE.[BenefitsTotalClient],         0.00)
    ,ISNULL(SOURCE.[BenefitsTotalClientAdjust],   0.00)

    ,ISNULL(SOURCE.[BenefitsChargedClientPrior],     0.00)
    ,ISNULL(SOURCE.[BenefitsRelievedClientPrior],    0.00)
    ,ISNULL(SOURCE.[BenefitsTotalClientPrior],       0.00)
    ,ISNULL(SOURCE.[BenefitsTotalClientPriorAdjust], 0.00)

    -- Payroll
    ,ISNULL(SOURCE.[TaxablePayRoll],              0.00)
    ,ISNULL(SOURCE.[TaxablePayRollTimely],        0.00)
    ,ISNULL(SOURCE.[TaxablePayRoll3YrAvg],        0.00)
    ,ISNULL(SOURCE.[TaxablePayRollTimely3YrAvg],  0.00)

    ,ISNULL(SOURCE.[Year1], @FiscalYear - 3)
    ,ISNULL(SOURCE.[TaxablePayRollTimelyYear1],   0.00)
    ,ISNULL(SOURCE.[TaxablePayRollYear1],         0.00)
    ,ISNULL(SOURCE.[TotalPayRollTimelyYear1],     0.00)
    ,ISNULL(SOURCE.[TotalPayRollYear1],           0.00)

    ,ISNULL(SOURCE.[Year2], @FiscalYear - 2)
    ,ISNULL(SOURCE.[TaxablePayRollTimelyYear2],   0.00)
    ,ISNULL(SOURCE.[TaxablePayRollYear2],         0.00)
    ,ISNULL(SOURCE.[TotalPayRollTimelyYear2],     0.00)
    ,ISNULL(SOURCE.[TotalPayRollYear2],           0.00)

    ,ISNULL(SOURCE.[Year3], @FiscalYear - 1)
    ,ISNULL(SOURCE.[TaxablePayRollTimelyYear3],   0.00)
    ,ISNULL(SOURCE.[TaxablePayRollYear3],         0.00)
    ,ISNULL(SOURCE.[TotalPayRollTimelyYear3],     0.00)
    ,ISNULL(SOURCE.[TotalPayRollYear3],           0.00)

    ,ISNULL(SOURCE.[PriorReserve],                0.00)

    ,ISNULL(SOURCE.[Reserve],                     0.00)
    ,SOURCE.[ReserveRatio]

    ,ISNULL(SOURCE.[RateTypeDetermined], @RateTypeUndetermined)

    ,@FebMailingDateCutoff -- [FebMailingDateCutoff]

    ,GETUTCDATE()  --AS 'CreatedDate'
    ,GETUTCDATE()  --AS 'ModifiedDate'
)

-- If a match is found, update the existing row
WHEN MATCHED
    AND (TARGET.[TaxesPaid]                  <> ISNULL(SOURCE.[TaxesPaid],                  0.00)  OR
        TARGET.[TaxesPaidAdjust]             <> ISNULL(SOURCE.[TaxesPaidAdjust],            0.00)  OR
        TARGET.[TaxesPaidPrior]              <> ISNULL(SOURCE.[TaxesPaidPrior],             0.00)  OR
        TARGET.[TaxesPaidPriorAdjust]        <> ISNULL(SOURCE.[TaxesPaidPriorAdjust],       0.00)  OR

        TARGET.[BenefitsChargedClient]       <> ISNULL(SOURCE.[BenefitsChargedClient],      0.00)  OR
        TARGET.[BenefitsRelievedClient]      <> ISNULL(SOURCE.[BenefitsRelievedClient],     0.00)  OR
        TARGET.[BenefitsTotalClient]         <> ISNULL(SOURCE.[BenefitsTotalClient],        0.00)  OR
        TARGET.[BenefitsTotalClientAdjust]   <> ISNULL(SOURCE.[BenefitsTotalClientAdjust],  0.00)  OR

        TARGET.[BenefitsChargedClientPrior]     <> ISNULL(SOURCE.[BenefitsChargedClientPrior],      0.00)  OR
        TARGET.[BenefitsRelievedClientPrior]    <> ISNULL(SOURCE.[BenefitsRelievedClientPrior],     0.00)  OR
        TARGET.[BenefitsTotalClientPrior]       <> ISNULL(SOURCE.[BenefitsTotalClientPrior],        0.00)  OR
        TARGET.[BenefitsTotalClientPriorAdjust] <> ISNULL(SOURCE.[BenefitsTotalClientPriorAdjust],  0.00)  OR

        TARGET.[TaxablePayRoll]              <> ISNULL(SOURCE.[TaxablePayRoll],             0.00)  OR
        TARGET.[TaxablePayRollTimely]        <> ISNULL(SOURCE.[TaxablePayRollTimely],       0.00)  OR
        TARGET.[TaxablePayRoll3YrAvg]        <> ISNULL(SOURCE.[TaxablePayRoll3YrAvg],       0.00)  OR
        TARGET.[TaxablePayRollTimely3YrAvg]  <> ISNULL(SOURCE.[TaxablePayRollTimely3YrAvg], 0.00)  OR

        TARGET.[Year1]                       <> ISNULL(SOURCE.[Year1], @FiscalYear - 3)            OR

        TARGET.[TaxablePayRollTimelyYear1]   <> ISNULL(SOURCE.[TaxablePayRollTimelyYear1],  0.00)  OR
        TARGET.[TaxablePayRollYear1]         <> ISNULL(SOURCE.[TaxablePayRollYear1],        0.00)  OR
        TARGET.[TotalPayRollTimelyYear1]     <> ISNULL(SOURCE.[TotalPayRollTimelyYear1],    0.00)  OR
        TARGET.[TotalPayRollYear1]           <> ISNULL(SOURCE.[TotalPayRollYear1],          0.00)  OR

        TARGET.[Year2]                       <> ISNULL(SOURCE.[Year2], @FiscalYear - 2)            OR

        TARGET.[TaxablePayRollTimelyYear2]   <> ISNULL(SOURCE.[TaxablePayRollTimelyYear2],  0.00)  OR
        TARGET.[TaxablePayRollYear2]         <> ISNULL(SOURCE.[TaxablePayRollYear2],        0.00)  OR
        TARGET.[TotalPayRollTimelyYear2]     <> ISNULL(SOURCE.[TotalPayRollTimelyYear2],    0.00)  OR
        TARGET.[TotalPayRollYear2]           <> ISNULL(SOURCE.[TotalPayRollYear2],          0.00)  OR

        TARGET.[Year3]                       <> ISNULL(SOURCE.[Year3], @FiscalYear - 1)            OR

        TARGET.[TaxablePayRollTimelyYear3]   <> ISNULL(SOURCE.[TaxablePayRollTimelyYear3],  0.00)  OR
        TARGET.[TaxablePayRollYear3]         <> ISNULL(SOURCE.[TaxablePayRollYear3],        0.00)  OR
        TARGET.[TotalPayRollTimelyYear3]     <> ISNULL(SOURCE.[TotalPayRollTimelyYear3],    0.00)  OR
        TARGET.[TotalPayRollYear3]           <> ISNULL(SOURCE.[TotalPayRollYear3],          0.00)  OR

        TARGET.[PriorReserve]                <> ISNULL(SOURCE.[PriorReserve],               0.00)  OR
        TARGET.[Reserve]                     <> ISNULL(SOURCE.[Reserve],                    0.00)  OR
        TARGET.[ReserveRatio]                <> SOURCE.[ReserveRatio]                              OR  -- KEPT AS-IS (QUIRK 5): NULL never compares <>

        TARGET.[RateTypeDetermined]          <> ISNULL(SOURCE.[RateTypeDetermined], @RateTypeUndetermined) OR

        TARGET.[FebMailingDateCutoff]        <> @FebMailingDateCutoff
        )
THEN
UPDATE SET
    TARGET.[TaxesPaid]                   = ISNULL(SOURCE.[TaxesPaid],                  0.00),
    TARGET.[TaxesPaidAdjust]             = ISNULL(SOURCE.[TaxesPaidAdjust],            0.00),
    TARGET.[TaxesPaidPrior]              = ISNULL(SOURCE.[TaxesPaidPrior],             0.00),
    TARGET.[TaxesPaidPriorAdjust]        = ISNULL(SOURCE.[TaxesPaidPriorAdjust],       0.00),

    TARGET.[BenefitsChargedClient]       = ISNULL(SOURCE.[BenefitsChargedClient],      0.00),
    TARGET.[BenefitsRelievedClient]      = ISNULL(SOURCE.[BenefitsRelievedClient],     0.00),
    TARGET.[BenefitsTotalClient]         = ISNULL(SOURCE.[BenefitsTotalClient],        0.00),
    TARGET.[BenefitsTotalClientAdjust]   = ISNULL(SOURCE.[BenefitsTotalClientAdjust],  0.00),

    TARGET.[BenefitsChargedClientPrior]     = ISNULL(SOURCE.[BenefitsChargedClientPrior],      0.00),
    TARGET.[BenefitsRelievedClientPrior]    = ISNULL(SOURCE.[BenefitsRelievedClientPrior],     0.00),
    TARGET.[BenefitsTotalClientPrior]       = ISNULL(SOURCE.[BenefitsTotalClientPrior],        0.00),
    TARGET.[BenefitsTotalClientPriorAdjust] = ISNULL(SOURCE.[BenefitsTotalClientPriorAdjust],  0.00),

    TARGET.[TaxablePayRoll]              = ISNULL(SOURCE.[TaxablePayRoll],             0.00),
    TARGET.[TaxablePayRollTimely]        = ISNULL(SOURCE.[TaxablePayRollTimely],       0.00),
    TARGET.[TaxablePayRoll3YrAvg]        = ISNULL(SOURCE.[TaxablePayRoll3YrAvg],       0.00),
    TARGET.[TaxablePayRollTimely3YrAvg]  = ISNULL(SOURCE.[TaxablePayRollTimely3YrAvg], 0.00),

    TARGET.[Year1]                       = ISNULL(SOURCE.[Year1], @FiscalYear - 3),

    TARGET.[TaxablePayRollTimelyYear1]   = ISNULL(SOURCE.[TaxablePayRollTimelyYear1],  0.00),
    TARGET.[TaxablePayRollYear1]         = ISNULL(SOURCE.[TaxablePayRollYear1],        0.00),
    TARGET.[TotalPayRollTimelyYear1]     = ISNULL(SOURCE.[TotalPayRollTimelyYear1],    0.00),
    TARGET.[TotalPayRollYear1]           = ISNULL(SOURCE.[TotalPayRollYear1],          0.00),

    TARGET.[Year2]                       = ISNULL(SOURCE.[Year2], @FiscalYear - 2),

    TARGET.[TaxablePayRollTimelyYear2]   = ISNULL(SOURCE.[TaxablePayRollTimelyYear2],  0.00),
    TARGET.[TaxablePayRollYear2]         = ISNULL(SOURCE.[TaxablePayRollYear2],        0.00),
    TARGET.[TotalPayRollTimelyYear2]     = ISNULL(SOURCE.[TotalPayRollTimelyYear2],    0.00),
    TARGET.[TotalPayRollYear2]           = ISNULL(SOURCE.[TotalPayRollYear2],          0.00),

    TARGET.[Year3]                       = ISNULL(SOURCE.[Year3], @FiscalYear - 1),

    TARGET.[TaxablePayRollTimelyYear3]   = ISNULL(SOURCE.[TaxablePayRollTimelyYear3],  0.00),
    TARGET.[TaxablePayRollYear3]         = ISNULL(SOURCE.[TaxablePayRollYear3],        0.00),
    TARGET.[TotalPayRollTimelyYear3]     = ISNULL(SOURCE.[TotalPayRollTimelyYear3],    0.00),
    TARGET.[TotalPayRollYear3]           = ISNULL(SOURCE.[TotalPayRollYear3],          0.00),

    TARGET.[PriorReserve]                = ISNULL(SOURCE.[PriorReserve],               0.00),
    TARGET.[Reserve]                     = ISNULL(SOURCE.[Reserve],                    0.00),

    TARGET.[ReserveRatio]                = SOURCE.[ReserveRatio],

    TARGET.[RateTypeDetermined]          = ISNULL(SOURCE.[RateTypeDetermined], @RateTypeUndetermined),

    TARGET.[FebMailingDateCutoff]        = @FebMailingDateCutoff,

    TARGET.[ModifiedDate] = GETUTCDATE()

-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE
        AND (@AnchorEmployerID = TARGET.[AnchorEmployerID])
        AND (@FiscalYear       = TARGET.[FiscalYear])
        AND (@AnchorEmployerID = TARGET.[EmployerID])
THEN
    DELETE
OPTION (MAXDOP 1); -- Example: Force single-threaded execution

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE [Account].[TaxRateExpReserveCalc]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttRC_Source  ** EXCEPT FOR DEBUG **


--SELECT * -- debug select 
--FROM [Account].[TaxRateExpReserveCalc]
--WHERE [AnchorEmployerID] = @AnchorEmployerID AND [EmployerID] = @AnchorEmployerID AND [FiscalYear] = @FiscalYear

-- ==== TEMP TABLE NO LONGER UTILIZED: #BasePeriod

CREATE TABLE #MissingIds
(
     [EmployerId]                   INT
    ,[FiscalYear]                   SMALLINT

    ,[TaxesPaid]                    MONEY                 NULL
    ,[TaxesPaidAdjust]              MONEY                 NULL
    ,[TaxesPaidPrior]               MONEY                 NULL
    ,[TaxesPaidPriorAdjust]         MONEY                 NULL

    ,[BenefitsChargedClient]        MONEY                 NULL
    ,[BenefitsRelievedClient]       MONEY                 NULL
    --,[BenefitsTotalClient]        MONEY                 NULL
    ,[BenefitsTotalClientAdjust]    MONEY                 NULL

    ,[BenefitsChargedClientPrior]        MONEY                 NULL
    ,[BenefitsRelievedClientPrior]       MONEY                 NULL
    --,[BenefitsTotalClientPrior]        MONEY                 NULL
    ,[BenefitsTotalClientPriorAdjust]    MONEY                 NULL

    -- ttPayRoll
    ,[TaxablePayRoll]               MONEY                 NULL
    ,[TaxablePayRollTimely]         MONEY                 NULL
    ,[TaxablePayRoll3YrAvg]         MONEY                 NULL
    ,[TaxablePayRollTimely3YrAvg]   MONEY                 NULL

    ,[Year1]                        SMALLINT              NULL
    ,[TaxablePayRollTimelyYear1]    MONEY                 NULL
    ,[TaxablePayRollYear1]          MONEY                 NULL
    ,[TotalPayRollTimelyYear1]      MONEY                 NULL
    ,[TotalPayRollYear1]            MONEY                 NULL

    ,[Year2]                        SMALLINT              NULL
    ,[TaxablePayRollTimelyYear2]    MONEY                 NULL
    ,[TaxablePayRollYear2]          MONEY                 NULL
    ,[TotalPayRollTimelyYear2]      MONEY                 NULL
    ,[TotalPayRollYear2]            MONEY                 NULL

    ,[Year3]                        SMALLINT              NULL
    ,[TaxablePayRollTimelyYear3]    MONEY                 NULL
    ,[TaxablePayRollYear3]          MONEY                 NULL
    ,[TotalPayRollTimelyYear3]      MONEY                 NULL
    ,[TotalPayRollYear3]            MONEY                 NULL
)

SET @StepStart = SYSDATETIME()

INSERT INTO #MissingIds
SELECT DISTINCT
     ttAcqEmployers.[PredecessorEmployerID]
    ,@FiscalYear

    ,ISNULL(ttTaxesPaid.[TaxesPaid],             0.00)

    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttAcqEmployers.[PredecessorEmployerID] 
            AND XX.[Component] IN ('PAYMENTADJUST')
            AND XX.[YEAR] = @FiscalYear - 1
            AND XX.[AdjustmentUtcDate] >= @RcptCreatedCutoffUtcPrior
            AND XX.[AdjustmentUtcDate] <  @RcptCreatedCutoffUtc
        ), 0.00) AS [TaxesPaidAdjust]

    ,ISNULL(ttTaxesPaid.[TaxesPaidPrior],       0.00)

    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttAcqEmployers.[PredecessorEmployerID] 
            AND XX.[Component] IN ('PAYMENTADJUST')
            AND XX.[YEAR] <= @FiscalYear - 2
            AND XX.[AdjustmentUtcDate] < @RcptCreatedCutoffUtcPrior
        ), 0.00) AS [TaxesPaidPriorAdjust]

    ,ISNULL(ttBenChg.[BenefitsChargedClient],       0.00)
    ,ISNULL(ttBenChg.[BenefitsRelievedClient],      0.00)

    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttAcqEmployers.[PredecessorEmployerID]  
            AND XX.[Component] IN ('BENEFITADJUST')
            AND XX.[YEAR] = @FiscalYear - 1
            AND XX.[AdjustmentUtcDate] >= @MaxPriorYearBenChgCreatedCutoffUtcFYPrior
            AND XX.[AdjustmentUtcDate] <  @MaxPriorYearBenChgCreatedCutoffUtcFY
        ), 0.00) AS [BenefitsTotalClientAdjust]

    ,ISNULL(ttBenChg.[BenefitsChargedClientPrior],  0.00)
    ,ISNULL(ttBenChg.[BenefitsRelievedClientPrior], 0.00)

    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttAcqEmployers.[PredecessorEmployerID]  
            AND XX.[Component] IN ('BENEFITADJUST')
            AND XX.[YEAR] <= @FiscalYear - 2
            AND XX.[AdjustmentUtcDate] < @MaxPriorYearBenChgCreatedCutoffUtcFYPrior
        ), 0.00) AS [BenefitsTotalClientPriorAdjust]

    ,ISNULL(ttPayRoll.[TaxablePayRoll],             0.00)
    ,ISNULL(ttPayRoll.[TaxablePayRollTimely],       0.00)
    ,ISNULL(ttPayRoll.[TaxablePayRoll3YrAvg],       0.00)
    ,ISNULL(ttPayRoll.[TaxablePayRollTimely3YrAvg], 0.00)

    ,ISNULL(ttPayRoll.[Year1],                      @FiscalYear - 3)
    ,ISNULL(ttPayRoll.[TaxablePayRollTimelyYear1],  0.00)
    ,ISNULL(ttPayRoll.[TaxablePayRollYear1],        0.00)
    ,ISNULL(ttPayRoll.[TotalPayRollTimelyYear1],    0.00)
    ,ISNULL(ttPayRoll.[TotalPayRollYear1],          0.00)

    ,ISNULL(ttPayRoll.[Year2],                      @FiscalYear - 2)
    ,ISNULL(ttPayRoll.[TaxablePayRollTimelyYear2],  0.00)
    ,ISNULL(ttPayRoll.[TaxablePayRollYear2],        0.00)
    ,ISNULL(ttPayRoll.[TotalPayRollTimelyYear2],    0.00)
    ,ISNULL(ttPayRoll.[TotalPayRollYear2],          0.00)

    ,ISNULL(ttPayRoll.[Year3],                      @FiscalYear - 1)
    ,ISNULL(ttPayRoll.[TaxablePayRollTimelyYear3],  0.00)
    ,ISNULL(ttPayRoll.[TaxablePayRollYear3],        0.00)
    ,ISNULL(ttPayRoll.[TotalPayRollTimelyYear3],    0.00)
    ,ISNULL(ttPayRoll.[TotalPayRollYear3],          0.00)

    FROM  #ttAcqEmployers                         AS ttAcqEmployers 
    LEFT JOIN [Account].[TaxRateExpReserveCalc] AS ttReserveCalc ON ttReserveCalc.[AnchorEmployerID] = @AnchorEmployerID
          AND ttReserveCalc.[EmployerID]       = ttAcqEmployers.[PredecessorEmployerID] 
          AND ttAcqEmployers.[IsPartial]       = 0 
          AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER
          AND ttReserveCalc.[FiscalYear]       = ttAcqEmployers.[FiscalYear]

    -- ttTaxesPaid
    LEFT JOIN 
    (SELECT 
            XX.[EmployerID]

        ,CAST(SUM(ISNULL(XX.[TaxesPaid],        0.00)) AS MONEY) AS [TaxesPaid]
        ,CAST(SUM(ISNULL(XX.[TaxesPaidPrior],   0.00)) AS MONEY) AS [TaxesPaidPrior]
        FROM [Account].[TaxRateExpTaxesPaid] AS XX 
        WHERE 1=1
          AND XX.[AnchorEmployerId]    = @AnchorEmployerId
          AND XX.[IsPartial]           = 0
          AND XX.[FiscalYear]          = @FiscalYear 
        GROUP BY XX.[EmployerID]
    ) AS ttTaxesPaid ON ttTaxesPaid.[EmployerID] = ttAcqEmployers.[AnchorEmployerId] 

    -- ttBenChg
    LEFT JOIN 
    (SELECT 
            XX.[EmployerID]

            ,CAST(SUM(ISNULL(XX.[BenefitsChargedClient],  0.00))      AS MONEY) AS [BenefitsChargedClient]
            ,CAST(SUM(ISNULL(XX.[BenefitsRelievedClient], 0.00))      AS MONEY) AS [BenefitsRelievedClient]

            ,CAST(SUM(ISNULL(XX.[BenefitsChargedClientPrior],  0.00)) AS MONEY) AS [BenefitsChargedClientPrior]
            ,CAST(SUM(ISNULL(XX.[BenefitsRelievedClientPrior], 0.00)) AS MONEY) AS [BenefitsRelievedClientPrior]
        FROM [Account].[TaxRateExpBenChg] XX 
        WHERE 1=1 
          AND XX.[AnchorEmployerID] = @AnchorEmployerID
          AND XX.[IsPartial] = 0
          AND XX.[FiscalYear] = @FiscalYear 
        GROUP BY XX.[EmployerID]
    ) AS ttBenChg ON ttBenChg.[EmployerID] = ttAcqEmployers.[AnchorEmployerId] 

    -- ttPayRoll
    LEFT JOIN 
    (SELECT 
            XX.[EmployerID]

        ,CAST(SUM(ISNULL(XX.[TaxablePayRoll],       0.00))        AS MONEY) AS [TaxablePayRoll]
        ,CAST(SUM(ISNULL(XX.[TaxablePayRollTimely], 0.00))        AS MONEY) AS [TaxablePayRollTimely]
        ,CAST(SUM(ISNULL(XX.[TaxablePayRoll],       0.00) / 3.00) AS MONEY) AS [TaxablePayRoll3YrAvg]
        ,CAST(SUM(ISNULL(XX.[TaxablePayRollTimely], 0.00) / 3.00) AS MONEY) AS [TaxablePayRollTimely3YrAvg]

        ,@FiscalYear - 3 as [Year1]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 3 THEN ISNULL(XX.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollTimelyYear1]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 3 THEN ISNULL(XX.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollYear1]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 3 THEN ISNULL(XX.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollTimelyYear1]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 3 THEN ISNULL(XX.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollYear1]

        ,@FiscalYear - 2 as [Year2]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 2 THEN ISNULL(XX.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollTimelyYear2]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 2 THEN ISNULL(XX.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollYear2]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 2 THEN ISNULL(XX.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollTimelyYear2]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 2 THEN ISNULL(XX.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollYear2]

        ,@FiscalYear - 1 as [Year3]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 1 THEN ISNULL(XX.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollTimelyYear3]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 1 THEN ISNULL(XX.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollYear3]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 1 THEN ISNULL(XX.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollTimelyYear3]
        ,CAST(SUM(CASE WHEN XX.[Year] = @FiscalYear - 1 THEN ISNULL(XX.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollYear3]

        FROM [Account].[TaxRateExpPayRoll]   AS XX  
        WHERE 1=1
        AND XX.[AnchorEmployerID] = @AnchorEmployerID 
        AND XX.[IsPArtial]        = 0 
        AND XX.[FiscalYear]       = @FiscalYear
        GROUP BY XX.[EmployerID]
    ) AS ttPayRoll ON ttPayRoll.[EmployerID] = ttAcqEmployers.[AnchorEmployerId] 

    WHERE 1=1
      AND ttReserveCalc.[EmployerID] IS NULL
      AND ttAcqEmployers.[IsPartial]       = 0 
      AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER
OPTION (RECOMPILE)

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #MissingIds: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

SET @StepStart = SYSDATETIME()

-- building missing Anchor row [Account].[TaxRateExpReserveCalc]
-- PROVISIONAL: 'Max-Rate :No Reserve Calc' is Anchor-only; the APPLICATION re-decides the Rate Type for
-- this row after adding the acquisition experience (result sets #1 / #2).
INSERT INTO [Account].[TaxRateExpReserveCalc]
(
     [AnchorEmployerID]
    ,[EmployerID]
    ,[FiscalYear] 

    -- ttTaxesPaid
    ,[TaxesPaid]
    ,[TaxesPaidAdjust]
    ,[TaxesPaidPrior]
    ,[TaxesPaidPriorAdjust]

    -- ttBenChg
    ,[BenefitsChargedClient]
    ,[BenefitsRelievedClient]
    ,[BenefitsTotalClient]
    ,[BenefitsTotalClientAdjust]

    ,[BenefitsChargedClientPrior]
    ,[BenefitsRelievedClientPrior]
    ,[BenefitsTotalClientPrior]
    ,[BenefitsTotalClientPriorAdjust]

    -- ttPayRoll
    ,[TaxablePayRoll]
    ,[TaxablePayRollTimely]
    ,[TaxablePayRoll3YrAvg]
    ,[TaxablePayRollTimely3YrAvg]

    ,[Year1]
    ,[TaxablePayRollTimelyYear1]
    ,[TaxablePayRollYear1]
    ,[TotalPayRollTimelyYear1]
    ,[TotalPayRollYear1]

    ,[Year2]
    ,[TaxablePayRollTimelyYear2]
    ,[TaxablePayRollYear2]
    ,[TotalPayRollTimelyYear2]
    ,[TotalPayRollYear2]

    ,[Year3]
    ,[TaxablePayRollTimelyYear3]
    ,[TaxablePayRollYear3]
    ,[TotalPayRollTimelyYear3]
    ,[TotalPayRollYear3]

    ,[PriorReserve] 

    ,[Reserve]
    ,[ReserveRatio]

    ,[RateTypeDetermined]
    ,[FebMailingDateCutoff]
    ,[CreatedDate], [ModifiedDate]) 
SELECT
     @AnchorEmployerID
    ,mi.[EmployerId]
    ,@FiscalYear

    ,mi.[TaxesPaid]
    ,mi.[TaxesPaidAdjust]
    ,mi.[TaxesPaidPrior]
    ,mi.[TaxesPaidPriorAdjust]

    ,mi.[BenefitsChargedClient]
    ,mi.[BenefitsRelievedClient]
    ,(mi.[BenefitsChargedClient]  - mi.[BenefitsRelievedClient]) AS [BenefitsTotalClient]
    ,mi.[BenefitsTotalClientAdjust]

    ,mi.[BenefitsChargedClientPrior]
    ,mi.[BenefitsRelievedClientPrior]
    ,(mi.[BenefitsChargedClientPrior]  - mi.[BenefitsRelievedClientPrior]) AS [BenefitsTotalClientPrior]
    ,mi.[BenefitsTotalClientPriorAdjust]

    ,mi.[TaxablePayRoll]
    ,mi.[TaxablePayRollTimely]
    ,mi.[TaxablePayRoll3YrAvg]
    ,mi.[TaxablePayRollTimely3YrAvg]

    ,mi.[Year1]
    ,mi.[TaxablePayRollTimelyYear1]
    ,mi.[TaxablePayRollYear1]
    ,mi.[TotalPayRollTimelyYear1]
    ,mi.[TotalPayRollYear1]

    ,mi.[Year2]
    ,mi.[TaxablePayRollTimelyYear2]
    ,mi.[TaxablePayRollYear2]
    ,mi.[TotalPayRollTimelyYear2]
    ,mi.[TotalPayRollYear2]

    ,mi.[Year3]
    ,mi.[TaxablePayRollTimelyYear3]
    ,mi.[TaxablePayRollYear3]
    ,mi.[TotalPayRollTimelyYear3]
    ,mi.[TotalPayRollYear3]

    ,(mi.[TaxesPaidPrior])                                                   -- ADD      [TaxesPaidPrior]
    - (mi.[BenefitsChargedClientPrior]  - mi.[BenefitsRelievedClientPrior])  -- SUBTRACT [BenefitsTotalClientPrior]
    + mi.[TaxesPaidPriorAdjust]                                              -- ADD      [TaxesPaidPriorAdjust]
    - mi.[BenefitsTotalClientPriorAdjust]                                    -- SUBTRACT BenefitsTotalClientPriorAdjust
    as [PriorReserve]

    ,(mi.[TaxesPaidPrior])                                                   -- ADD      [TaxesPaidPrior]
    - (mi.[BenefitsChargedClientPrior]  - mi.[BenefitsRelievedClientPrior])  -- SUBTRACT [BenefitsTotalClientPrior]
    + mi.[TaxesPaidPriorAdjust]                                              -- ADD      [TaxesPaidPriorAdjust]
    - mi.[BenefitsTotalClientPriorAdjust]                                    -- SUBTRACT BenefitsTotalClientPriorAdjust

    + (mi.[TaxesPaid])                                                        -- ADD      [TaxesPaid]
    - (mi.[BenefitsChargedClient]      - mi.[BenefitsRelievedClient])         -- SUBTRACT [BenefitsTotalClient]
    + mi.[TaxesPaidAdjust]                                                    -- ADD      [TaxesPaidAdjust]
    - mi.[BenefitsTotalClientAdjust]                                          -- SUBTRACT [BenefitsTotalClientAdjust]
    AS [Reserve]

    ,NULL --,SOURCE.[ReserveRatio]

    ,@RateTypeMaxRate4 -- ISNULL(SOURCE.[RateTypeDetermined], @RateTypeUndetermined)
    ,@FebMailingDateCutoff -- [FebMailingDateCutoff]

    ,GETUTCDATE()  --AS 'CreatedDate'
    ,GETUTCDATE()  --AS 'ModifiedDate'

FROM #MissingIds AS mi
WHERE [EmployerId] = @AnchorEmployerID

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT [Account].[TaxRateExpReserveCalc] (missing Anchor row): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ==== TEMP TABLE NO LONGER UTILIZED: #MissingIds

-- TransferExperience

CREATE TABLE #ttTransExp 
(
    [AnchorEmployerId]                  INT,
    [EmployerID]                        INT,
    [AcquisitionID]                     BIGINT,
    [IsPartial]                         BIT,
    [SuccessorEmployerID]               INT,
    [PredecessorEmployerID]             INT,

    [TaxablePayRollTimely]              MONEY,
    [TaxablePayRoll]                    MONEY,
    [TotalPayRollTimely]                MONEY,
    [TotalPayRoll]                      MONEY,

    [TaxesPaid]                         MONEY,
    [TaxesPaidAdjust]                   MONEY,

    [TaxesPaidPrior]                    MONEY,
    [TaxesPaidPriorAdjust]              MONEY,

    [BenefitsChargedClient]             MONEY,
    [BenefitsRelievedClient]            MONEY,
    [BenefitsTotalClientAdjust]         MONEY,

    [BenefitsChargedClientPrior]        MONEY,
    [BenefitsRelievedClientPrior]       MONEY,
    [BenefitsTotalClientPriorAdjust]    MONEY,

    [Year1]                             SMALLINT,
    [TaxablePayRollTimelyYear1]         MONEY,
    [TaxablePayRollYear1]               MONEY,
    [TotalPayRollTimelyYear1]           MONEY,
    [TotalPayRollYear1]                 MONEY,

    [Year2]                             SMALLINT,
    [TaxablePayRollTimelyYear2]         MONEY,
    [TaxablePayRollYear2]               MONEY,
    [TotalPayRollTimelyYear2]           MONEY,
    [TotalPayRollYear2]                 MONEY,

    [Year3]                             SMALLINT,
    [TaxablePayRollTimelyYear3]         MONEY,
    [TaxablePayRollYear3]               MONEY,
    [TotalPayRollTimelyYear3]           MONEY,
    [TotalPayRollYear3]                 MONEY,

    [ClientTaxablePayRoll]              MONEY,

    [Reserve]                           MONEY,
    [PriorReserve]                      MONEY,

    [PercentTransfer]                   DECIMAL(8, 4)
)

-- Employer and Full Transfer Experience -- [IsPartial] = 0
SET @StepStart = SYSDATETIME()

INSERT INTO #ttTransExp
SELECT -- ttTransferExpData
    [AnchorEmployerId],
    [EmployerID],
    [AcquisitionID],
    [IsPartial],
    [SuccessorEmployerID],
    [PredecessorEmployerID],

    SUM([TaxablePayRollTimely])        AS [TaxablePayRollTimely],
    SUM([TaxablePayRoll])              AS [TaxablePayRoll],
    SUM([TotalPayRollTimely])          AS [TotalPayRollTimely],
    SUM([TotalPayRoll])                AS [TotalPayRoll],

    SUM([TaxesPaid])                   AS [TaxesPaid],
    0.00                               AS [TaxesPaidAdjust],
        
    SUM([TaxesPaidPrior])              AS [TaxesPaidPrior],
    0.00                               AS [TaxesPaidPriorAdjust],

    SUM([BenefitsChargedClient])       AS [BenefitsChargedClient],
    SUM([BenefitsRelievedClient])      AS [BenefitsRelievedClient],
    0.00                               AS [BenefitsTotalClientAdjust],

    SUM([BenefitsChargedClientPrior])  AS [BenefitsChargedClientPrior],
    SUM([BenefitsRelievedClientPrior]) AS [BenefitsRelievedClientPrior],
    0.00                               AS [BenefitsTotalClientPriorAdjust],

    [Year1],
    SUM([TaxablePayRollTimelyYear1])  AS [TaxablePayRollTimelyYear1],
    SUM([TaxablePayRollYear1])        AS [TaxablePayRollYear1],
    SUM([TotalPayRollTimelyYear1])    AS [TotalPayRollTimelyYear1],
    SUM([TotalPayRollYear1])          AS [TotalPayRollYear1],

    [Year2],
    SUM([TaxablePayRollTimelyYear2])  AS [TaxablePayRollTimelyYear2],
    SUM([TaxablePayRollYear2])        AS [TaxablePayRoll2],
    SUM([TotalPayRollTimelyYear2])    AS [TotalPayRollTimelyYear2],
    SUM([TotalPayRollYear2])          AS [TotalPayRollYear2],

    [Year3],
    SUM([TaxablePayRollTimelyYear3])  AS [TaxablePayRollTimelyYear3],
    SUM([TaxablePayRollYear3])        AS [TaxablePayRollYear3],
    SUM([TotalPayRollTimelyYear3])    AS [TotalPayRollTimelyYear3],
    SUM([TotalPayRollYear3])          AS [TotalPayRollYear3],

    0.00                          AS [ClientTaxablePayRoll],

    0.00                          AS [Reserve],
    0.00                          AS [PriorReserve],

    0.00                          AS [PercentTransfer]

FROM (
SELECT 
    @AnchorEmployerId                  AS [AnchorEmployerId],
    ttTransferExp.[EmployerID],
    ttTransferExp.[AcquisitionID],
    ttTransferExp.[IsPartial],
    ttTransferExp.[SuccessorEmployerID],
    ttTransferExp.[PredecessorEmployerID],

    ([TaxablePayRollTimely])        AS [TaxablePayRollTimely],
    ([TaxablePayRoll])              AS [TaxablePayRoll],
    ([TotalPayRollTimely])          AS [TotalPayRollTimely],
    ([TotalPayRoll])                AS [TotalPayRoll],

    ([TaxesPaid])                   AS [TaxesPaid],
    ([TaxesPaidPrior])              AS [TaxesPaidPrior],

    ([BenefitsChargedClient])       AS [BenefitsChargedClient],
    ([BenefitsRelievedClient])      AS [BenefitsRelievedClient],
    ([BenefitsChargedClientPrior])  AS [BenefitsChargedClientPrior],
    ([BenefitsRelievedClientPrior]) AS [BenefitsRelievedClientPrior],

    @FiscalYear - 1  AS [Year1],
    0.00  AS [TaxablePayRollTimelyYear1],
    0.00  AS [TaxablePayRollYear1],
    0.00  AS [TotalPayRollTimelyYear1],
    0.00  AS [TotalPayRollYear1],

    @FiscalYear - 2  AS [Year2],
    0.00  AS [TaxablePayRollTimelyYear2],
    0.00  AS [TaxablePayRollYear2],
    0.00  AS [TotalPayRollTimelyYear2],
    0.00  AS [TotalPayRollYear2],

    @FiscalYear - 3  AS [Year3],
    0.00  AS [TaxablePayRollTimelyYear3],
    0.00  AS [TaxablePayRollYear3],
    0.00  AS [TotalPayRollTimelyYear3],
    0.00  AS [TotalPayRollYear3]

FROM (
SELECT -- [Account].[TaxRateExpTaxesPaid]
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    0.0 AS [TaxablePayRollTimely],
    0.0 AS [TaxablePayRoll],
    0.0 AS [TotalPayRollTimely],
    0.0 AS [TotalPayRoll],

    (ISNULL(ttData.[TaxesPaid],      0.00)) AS [TaxesPaid],
    (ISNULL(ttData.[TaxesPaidPrior], 0.00)) AS [TaxesPaidPrior],

    0.00 AS [BenefitsChargedClient],
    0.00 AS [BenefitsRelievedClient],
    0.00 AS [BenefitsChargedClientPrior],
    0.00 AS [BenefitsRelievedClientPrior]

FROM #ttAcqEmployers AS ttAcqEmployers
LEFT JOIN [Account].[TaxRateExpTaxesPaid] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        AND ttData.[EmployerID]        = ttAcqEmployers.[PredecessorEmployerID] 
        AND ttAcqEmployers.[IsPartial] = 0
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = ttAcqEmployers.[FiscalYear] 

UNION ALL

SELECT -- [Account].[TaxRateExpBenChg]
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    0.0 AS [TaxablePayRollTimely],
    0.0 AS [TaxablePayRoll],
    0.0 AS [TotalPayRollTimely],
    0.0 AS [TotalPayRoll],

    0.00 AS [TaxesPaid],
    0.00 AS [TaxesPaidPrior],

    (ISNULL(ttData.[BenefitsChargedClient],       0.00)) AS [BenefitsChargedClient],
    (ISNULL(ttData.[BenefitsRelievedClient],      0.00)) AS [BenefitsRelievedClient],
    (ISNULL(ttData.[BenefitsChargedClientPrior],  0.00)) AS [BenefitsChargedClientPrior],
    (ISNULL(ttData.[BenefitsRelievedClientPrior], 0.00)) AS [BenefitsRelievedClientPrior]

FROM #ttAcqEmployers AS ttAcqEmployers
LEFT JOIN [Account].[TaxRateExpBenChg] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        AND ttData.[EmployerID]        = ttAcqEmployers.[PredecessorEmployerID] 
        AND ttAcqEmployers.[IsPartial] = 0
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = ttAcqEmployers.[FiscalYear] 

UNION ALL

SELECT -- [Account].[TaxRateExpPayRoll]
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    (ISNULL(ttData.[TaxablePayRollTimely], 0.00)) AS [TaxablePayRollTimely],
    (ISNULL(ttData.[TaxablePayRoll],       0.00)) AS [TaxablePayRoll],
    (ISNULL(ttData.[TotalPayRollTimely],   0.00)) AS [TotalPayRollTimely],
    (ISNULL(ttData.[TotalPayRoll],         0.00)) AS [TotalPayRoll],

    0.00 AS [TaxesPaid],
    0.00 AS [TaxesPaidPrior],

    0.00 AS [BenefitsChargedClient],
    0.00 AS [BenefitsRelievedClient],
    0.00 AS [BenefitsChargedClientPrior],
    0.00 AS [BenefitsRelievedClientPrior]

FROM #ttAcqEmployers AS ttAcqEmployers
LEFT JOIN [Account].[TaxRateExpPayRoll] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        AND ttData.[EmployerID]        = ttAcqEmployers.[PredecessorEmployerID] 
        AND ttAcqEmployers.[IsPartial] = 0
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = ttAcqEmployers.[FiscalYear] 

) ttTransferExp

UNION ALL 

SELECT -- [Year1], [Year2], [Year3] FROM [Account].[TaxRateExpPayRoll]
    @AnchorEmployerId                  AS [AnchorEmployerId],
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    0.0 AS [TaxablePayRollTimely],
    0.0 AS [TaxablePayRoll],
    0.0 AS [TotalPayRollTimely],
    0.0 AS [TotalPayRoll],

    0.00 AS [TaxesPaid],
    0.00 AS [TaxesPaidPrior],

    0.00 AS [BenefitsChargedClient],
    0.00 AS [BenefitsRelievedClient],
    0.00 AS [BenefitsChargedClientPrior],
    0.00 AS [BenefitsRelievedClientPrior],

    @FiscalYear - 1  AS [Year1],
    CASE WHEN ttData.[Year] = @FiscalYear - 1 THEN ISNULL([TaxablePayRollTimely], 0.00) ELSE 0.00 END AS [TaxablePayRollTimely1],
    CASE WHEN ttData.[Year] = @FiscalYear - 1 THEN ISNULL([TaxablePayRoll],       0.00) ELSE 0.00 END AS [TaxablePayRoll1],
    CASE WHEN ttData.[Year] = @FiscalYear - 1 THEN ISNULL([TotalPayRollTimely],   0.00) ELSE 0.00 END AS [TotalPayRollTimely1],
    CASE WHEN ttData.[Year] = @FiscalYear - 1 THEN ISNULL([TotalPayRoll],         0.00) ELSE 0.00 END AS [TotalPayRoll1],

    @FiscalYear - 2  AS [Year2],
    CASE WHEN ttData.[Year] = @FiscalYear - 2 THEN ISNULL([TaxablePayRollTimely], 0.00) ELSE 0.00 END AS [TaxablePayRollTimely2],
    CASE WHEN ttData.[Year] = @FiscalYear - 2 THEN ISNULL([TaxablePayRoll],       0.00) ELSE 0.00 END AS [TaxablePayRoll2],
    CASE WHEN ttData.[Year] = @FiscalYear - 2 THEN ISNULL([TotalPayRollTimely],   0.00) ELSE 0.00 END AS [TotalPayRollTimely2],
    CASE WHEN ttData.[Year] = @FiscalYear - 2 THEN ISNULL([TotalPayRoll],         0.00) ELSE 0.00 END AS [TotalPayRoll2],

    @FiscalYear - 3  AS [Year3],
    CASE WHEN ttData.[Year] = @FiscalYear - 3 THEN ISNULL([TaxablePayRollTimely], 0.00) ELSE 0.00 END AS [TaxablePayRollTimely3],
    CASE WHEN ttData.[Year] = @FiscalYear - 3 THEN ISNULL([TaxablePayRoll],       0.00) ELSE 0.00 END AS [TaxablePayRoll3],
    CASE WHEN ttData.[Year] = @FiscalYear - 3 THEN ISNULL([TotalPayRollTimely],   0.00) ELSE 0.00 END AS [TotalPayRollTimely3],
    CASE WHEN ttData.[Year] = @FiscalYear - 3 THEN ISNULL([TotalPayRoll],         0.00) ELSE 0.00 END AS [TotalPayRoll3]

FROM #ttAcqEmployers AS ttAcqEmployers
INNER JOIN [Account].[TaxRateExpPayRoll] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID] 
    AND ttData.[EmployerID] = ttAcqEmployers.[PredecessorEmployerID] 
    AND ttAcqEmployers.[IsPartial] = 0
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = ttAcqEmployers.[FiscalYear] 

) AS ttTransferExpData
GROUP BY
    [AnchorEmployerId],
    [EmployerID],
    [AcquisitionID],
    [IsPartial],
    [SuccessorEmployerID],
    [PredecessorEmployerID],
    [Year1],
    [Year2],
    [Year3]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttTransExp (Employer / FULL transfers): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Partial Transfer Experience -- [IsPartial] = 1
SET @StepStart = SYSDATETIME()

INSERT INTO #ttTransExp
SELECT -- ttTransferExpData
    [AnchorEmployerId],
    [EmployerID],
    [AcquisitionID],
    [IsPartial],
    [SuccessorEmployerID],
    [PredecessorEmployerID],

    SUM([TaxablePayRollTimely])        AS [TaxablePayRollTimely],
    SUM([TaxablePayRoll])              AS [TaxablePayRoll],
    SUM([TotalPayRollTimely])          AS [TotalPayRollTimely],
    SUM([TotalPayRoll])                AS [TotalPayRoll],

    SUM([TaxesPaid])                   AS [TaxesPaid],
    0.00                               AS [TaxesPaidAdjust],
        
    SUM([TaxesPaidPrior])              AS [TaxesPaidPrior],
    0.00                               AS [TaxesPaidPriorAdjust],

    SUM([BenefitsChargedClient])       AS [BenefitsChargedClient],
    SUM([BenefitsRelievedClient])      AS [BenefitsRelievedClient],
    0.00                               AS [BenefitsTotalClientAdjust],

    SUM([BenefitsChargedClientPrior])  AS [BenefitsChargedClientPrior],
    SUM([BenefitsRelievedClientPrior]) AS [BenefitsRelievedClientPrior],
    0.00                               AS [BenefitsTotalClientPriorAdjust],


    [Year1],
    SUM([TaxablePayRollTimely1])  AS [TaxablePayRollTimely1],
    SUM([TaxablePayRoll1])        AS [TaxablePayRoll1],
    SUM([TotalPayRollTimely1])    AS [TotalPayRollTimely1],
    SUM([TotalPayRoll1])          AS [TotalPayRoll1],

    [Year2],
    SUM([TaxablePayRollTimely2])  AS [TaxablePayRollTimely2],
    SUM([TaxablePayRoll2])        AS [TaxablePayRoll2],
    SUM([TotalPayRollTimely2])    AS [TotalPayRollTimely2],
    SUM([TotalPayRoll2])          AS [TotalPayRoll2],

    [Year3],
    SUM([TaxablePayRollTimely3])  AS [TaxablePayRollTimely3],
    SUM([TaxablePayRoll3])        AS [TaxablePayRoll3],
    SUM([TotalPayRollTimely3])    AS [TotalPayRollTimely3],
    SUM([TotalPayRoll3])          AS [TotalPayRoll3],

    0.00                          AS [ClientTaxablePayRoll],

    0.00                          AS [Reserve],
    0.00                          AS [ReservePrior],

    0.00                          AS [PercentTransfer]

FROM (
SELECT 
    @AnchorEmployerId                  AS [AnchorEmployerId],
    ttTransferExp.[EmployerID],
    ttTransferExp.[AcquisitionID],
    ttTransferExp.[IsPartial],
    ttTransferExp.[SuccessorEmployerID],
    ttTransferExp.[PredecessorEmployerID],

    ([TaxablePayRollTimely])        AS [TaxablePayRollTimely],
    ([TaxablePayRoll])              AS [TaxablePayRoll],
    ([TotalPayRollTimely])          AS [TotalPayRollTimely],
    ([TotalPayRoll])                AS [TotalPayRoll],

    ([TaxesPaid])                   AS [TaxesPaid],
    ([TaxesPaidPrior])              AS [TaxesPaidPrior],

    ([BenefitsChargedClient])       AS [BenefitsChargedClient],
    ([BenefitsRelievedClient])      AS [BenefitsRelievedClient],
    ([BenefitsChargedClientPrior])  AS [BenefitsChargedClientPrior],
    ([BenefitsRelievedClientPrior]) AS [BenefitsRelievedClientPrior],

    YEAR(ttTransferExp.[AcquisitionDate]) - 0 AS [Year1],
    0.00  AS [TaxablePayRollTimely1],
    0.00  AS [TaxablePayRoll1],
    0.00  AS [TotalPayRollTimely1],
    0.00  AS [TotalPayRoll1],

    YEAR(ttTransferExp.[AcquisitionDate]) - 1 AS [Year2],
    0.00  AS [TaxablePayRollTimely2],
    0.00  AS [TaxablePayRoll2],
    0.00  AS [TotalPayRollTimely2],
    0.00  AS [TotalPayRoll2],

    YEAR(ttTransferExp.[AcquisitionDate]) - 2 AS [Year3],
    0.00  AS [TaxablePayRollTimely3],
    0.00  AS [TaxablePayRoll3],
    0.00  AS [TotalPayRollTimely3],
    0.00  AS [TotalPayRoll3]

FROM (
SELECT -- [Account].[TaxRateExpTaxesPaid]
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[AcquisitionDate],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    0.0 AS [TaxablePayRollTimely],
    0.0 AS [TaxablePayRoll],
    0.0 AS [TotalPayRollTimely],
    0.0 AS [TotalPayRoll],

    (ISNULL(ttData.[TaxesPaid],      0.00)) AS [TaxesPaid],
    (ISNULL(ttData.[TaxesPaidPrior], 0.00)) AS [TaxesPaidPrior],

    0.00 AS [BenefitsChargedClient],
    0.00 AS [BenefitsRelievedClient],
    0.00 AS [BenefitsChargedClientPrior],
    0.00 AS [BenefitsRelievedClientPrior]

FROM #ttAcqEmployers AS ttAcqEmployers
LEFT JOIN [Account].[TaxRateExpTaxesPaid] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        AND ttData.[EmployerID]                     = ttAcqEmployers.[PredecessorEmployerID] 
        AND ttAcqEmployers.[PredecessorEmployerID] != ttAcqEmployers.[AnchorEmployerID]
        AND ttAcqEmployers.[IsPartial]              = 1 
        AND ttAcqEmployers.[AcquisitionDate]       IS NOT NULL
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = ttAcqEmployers.[FiscalYear] 

UNION ALL

SELECT -- [Account].[TaxRateExpBenChg]
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[AcquisitionDate],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    0.0 AS [TaxablePayRollTimely],
    0.0 AS [TaxablePayRoll],
    0.0 AS [TotalPayRollTimely],
    0.0 AS [TotalPayRoll],

    0.00 AS [TaxesPaid],
    0.00 AS [TaxesPaidPrior],

    (ISNULL(ttData.[BenefitsChargedClient],       0.00)) AS [BenefitsChargedClient],
    (ISNULL(ttData.[BenefitsRelievedClient],      0.00)) AS [BenefitsRelievedClient],
    (ISNULL(ttData.[BenefitsChargedClientPrior],  0.00)) AS [BenefitsChargedClientPrior],
    (ISNULL(ttData.[BenefitsRelievedClientPrior], 0.00)) AS [BenefitsRelievedClientPrior]

FROM #ttAcqEmployers AS ttAcqEmployers
LEFT JOIN [Account].[TaxRateExpBenChg] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        -- Only ttAcqEmployers that are partials 
        AND ttData.[EmployerID]                     = ttAcqEmployers.[PredecessorEmployerID] 
        AND ttAcqEmployers.[PredecessorEmployerID] != ttAcqEmployers.[AnchorEmployerID]
        AND ttAcqEmployers.[IsPartial]              = 1 
        AND ttAcqEmployers.[AcquisitionDate]       IS NOT NULL
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = ttAcqEmployers.[FiscalYear]

UNION ALL

SELECT -- [Account].[TaxRateExpPayRoll]
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[AcquisitionDate],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    (ISNULL(ttData.[TaxablePayRollTimely], 0.00)) AS [TaxablePayRollTimely],
    (ISNULL(ttData.[TaxablePayRoll],       0.00)) AS [TaxablePayRoll],
    (ISNULL(ttData.[TotalPayRollTimely],   0.00)) AS [TotalPayRollTimely],
    (ISNULL(ttData.[TotalPayRoll],         0.00)) AS [TotalPayRoll],

    0.00 AS [TaxesPaid],
    0.00 AS [TaxesPaidPrior],

    0.00 AS [BenefitsChargedClient],
    0.00 AS [BenefitsRelievedClient],
    0.00 AS [BenefitsChargedClientPrior],
    0.00 AS [BenefitsRelievedClientPrior]

FROM #ttAcqEmployers AS ttAcqEmployers
LEFT JOIN [Account].[TaxRateExpPayRoll] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        AND ttData.[EmployerID]                     = ttAcqEmployers.[PredecessorEmployerID] 
        AND ttAcqEmployers.[PredecessorEmployerID] != ttAcqEmployers.[AnchorEmployerID]
        AND ttAcqEmployers.[IsPartial]              = 1 
        AND ttAcqEmployers.[AcquisitionDate]       IS NOT NULL
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = @FiscalYear 

) ttTransferExp

UNION ALL 

SELECT -- [Year1], [Year2], [Year3] FROM [Account].[TaxRateExpPayRoll]
    @AnchorEmployerId                  AS [AnchorEmployerId],
    ttData.[EmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    0.0 AS [TaxablePayRollTimely],
    0.0 AS [TaxablePayRoll],
    0.0 AS [TotalPayRollTimely],
    0.0 AS [TotalPayRoll],

    0.00 AS [TaxesPaid],
    0.00 AS [TaxesPaidPrior],

    0.00 AS [BenefitsChargedClient],
    0.00 AS [BenefitsRelievedClient],
    0.00 AS [BenefitsChargedClientPrior],
    0.00 AS [BenefitsRelievedClientPrior],

    YEAR(ttAcqEmployers.[AcquisitionDate]) - 0  AS [Year1],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 0 THEN ISNULL([TaxablePayRollTimely], 0.00) ELSE 0.00 END AS [TaxablePayRollTimely1],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 0 THEN ISNULL([TaxablePayRoll],       0.00) ELSE 0.00 END AS [TaxablePayRoll1],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 0 THEN ISNULL([TotalPayRollTimely],   0.00) ELSE 0.00 END AS [TotalPayRollTimely1],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 0 THEN ISNULL([TotalPayRoll],         0.00) ELSE 0.00 END AS [TotalPayRoll1],

    YEAR(ttAcqEmployers.[AcquisitionDate]) - 1  AS [Year2],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 1 THEN ISNULL([TaxablePayRollTimely], 0.00) ELSE 0.00 END AS [TaxablePayRollTimely2],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 1 THEN ISNULL([TaxablePayRoll],       0.00) ELSE 0.00 END AS [TaxablePayRoll2],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 1 THEN ISNULL([TotalPayRollTimely],   0.00) ELSE 0.00 END AS [TotalPayRollTimely2],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 1 THEN ISNULL([TotalPayRoll],         0.00) ELSE 0.00 END AS [TotalPayRoll2],

    YEAR(ttAcqEmployers.[AcquisitionDate]) - 2  AS [Year3],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 2 THEN ISNULL([TaxablePayRollTimely], 0.00) ELSE 0.00 END AS [TaxablePayRollTimely3],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 2 THEN ISNULL([TaxablePayRoll],       0.00) ELSE 0.00 END AS [TaxablePayRoll3],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 2 THEN ISNULL([TotalPayRollTimely],   0.00) ELSE 0.00 END AS [TotalPayRollTimely3],
    CASE WHEN ttData.[Year] = YEAR(ttAcqEmployers.[AcquisitionDate]) - 2 THEN ISNULL([TotalPayRoll],         0.00) ELSE 0.00 END AS [TotalPayRoll3]

FROM #ttAcqEmployers AS ttAcqEmployers
INNER JOIN [Account].[TaxRateExpPayRoll] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        AND ttData.[EmployerID]                     = ttAcqEmployers.[PredecessorEmployerID] 
        AND ttAcqEmployers.[PredecessorEmployerID] != ttAcqEmployers.[AnchorEmployerID]
        AND ttAcqEmployers.[IsPartial]              = 1 
        AND ttAcqEmployers.[AcquisitionDate]        IS NOT NULL
WHERE  1=1
    AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
    AND ttData.[FiscalYear]        = @FiscalYear 

) AS ttTransferExpData
GROUP BY
    [AnchorEmployerId],
    [EmployerID],
    [AcquisitionID],
    [IsPartial],
    [SuccessorEmployerID],
    [PredecessorEmployerID],
    [Year1],
    [Year2],
    [Year3]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttTransExp (PARTIAL transfers): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- MISSING ACQUISTION DATA
SET @StepStart = SYSDATETIME()

INSERT INTO #ttTransExp
SELECT -- ttTransferExpData
    ttAcqEmployers.[AnchorEmployerId],
    ttAcqEmployers.[PredecessorEmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    0.00 AS [TaxablePayRollTimely],
    0.00 AS [TaxablePayRoll],
    0.00 AS [TotalPayRollTimely],
    0.00 AS [TotalPayRoll],

    0.00 AS [TaxesPaid],
    0.00 AS [TaxesPaidAdjust],

    0.00 AS [TaxesPaidPrior],
    0.00 AS [TaxesPaidPriorAdjust],

    0.00 AS [BenefitsChargedClient],
    0.00 AS [BenefitsRelievedClient],
    0.00 AS [BenefitsRelievedClientAdjust],

    0.00 AS [BenefitsChargedClientPrior],
    0.00 AS [BenefitsRelievedClientPrior],
    0.00 AS [BenefitsRelievedClientPriorAdjust],

    CASE WHEN ttAcqEmployers.[IsPartial] = 1 THEN YEAR(ttAcqEmployers.[AcquisitionDate]) - 0 ELSE ttAcqEmployers.[FiscalYear] - 1 END AS [Year1],
    0.00 AS [TaxablePayRollTimely1],
    0.00 AS [TaxablePayRoll1],
    0.00 AS [TotalPayRollTimely1],
    0.00 AS [TotalPayRoll1],

    CASE WHEN ttAcqEmployers.[IsPartial] = 1 THEN YEAR(ttAcqEmployers.[AcquisitionDate]) - 1 ELSE ttAcqEmployers.[FiscalYear] - 2 END AS [Year2],
    0.00 AS [TaxablePayRollTimely2],
    0.00 AS [TaxablePayRoll2],
    0.00 AS [TotalPayRollTimely2],
    0.00 AS [TotalPayRoll2],

    CASE WHEN ttAcqEmployers.[IsPartial] = 1 THEN YEAR(ttAcqEmployers.[AcquisitionDate]) - 2 ELSE ttAcqEmployers.[FiscalYear] - 3 END AS [Year3],
    0.00 AS [TaxablePayRollTimely3],
    0.00 AS [TaxablePayRoll3],
    0.00 AS [TotalPayRollTimely3],
    0.00 AS [TotalPayRoll3],

    0.00                          AS [ClientTaxablePayRoll],

    0.00                          AS [Reserve],
    0.00                          AS [ReservePrior],

    0.00                          AS [PercentTransfer]

FROM #ttAcqEmployers  AS ttAcqEmployers
-- LEFT JOIN #ttTransExp AS ttTransExp ON ttTransExp.[AcquisitionID] = ttAcqEmployers.[AcquisitionID] AND ttAcqEmployers.[AcquisitionID] IS NOT NULL
WHERE 1=1
    AND ttAcqEmployers.[AcquisitionID] IS NOT NULL 
    AND (SELECT XX.[AcquisitionID] FROM #ttTransExp XX WHERE XX.[AcquisitionID] = ttAcqEmployers.[AcquisitionID]) IS NULL
--WHERE 1=1
--  AND ttTransExp.[AnchorEmployerId] IS NULL

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttTransExp (missing acquisition data): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- #ttTransExp SET RESERVE
SET @StepStart = SYSDATETIME()

UPDATE  TT SET
    TT.[Reserve]      = TT.[TaxesPaid]      - (TT.[BenefitsChargedClient]      - TT.[BenefitsRelievedClient]),
    TT.[PriorReserve] = TT.[TaxesPaidPrior] - (TT.[BenefitsChargedClientPrior] - TT.[BenefitsRelievedClientPrior])
FROM #ttTransExp AS TT

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('UPDATE #ttTransExp [Reserve] / [PriorReserve]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- #ttTransExp Set [ClientTaxablePayroll]
SET @StepStart = SYSDATETIME()

UPDATE  TT SET
    TT.[ClientTaxablePayroll] =
    CASE WHEN  TT.[IsPartial] = 0  THEN 0.00 
            ELSE
            (SELECT 
                ISNULL(SUM(ISNULL(ttTrExpClientPay.[ClientTaxablePayroll], 0.00)), 0.00) AS [ClientTaxablePayroll]
                FROM [Account].[TransferExperience]                      AS ttTrExp
                INNER JOIN [Account].[TransferExperienceClient]        AS ttTrExpClient    ON ttTrExpClient.[TransferExperienceID]          = ttTrExp.[TransferExperienceID]
                INNER JOIN [Account].[TransferExperienceClientPayroll] AS ttTrExpClientPay ON ttTrExpClientPay.[TransferExperienceClientID] = ttTrExpClient.[TransferExperienceClientID]
                INNER JOIN #ttAcqEmployers                             AS ttAcqEmployers   ON ttAcqEmployers.[AcquisitionID]                = ttTrExp.[AcquisitionID] 
                        AND ttAcqEmployers.[IsPartial]       = 1 
                        AND ttAcqEmployers.[AcquisitionDate] IS NOT NULL
                WHERE 1=1
                AND ttTrExp.[AcquisitionID] = TT.[AcquisitionID])
            END
FROM #ttTransExp AS TT

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('UPDATE #ttTransExp [ClientTaxablePayroll]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- #ttTransExp Set [PercentTransfer]
SET @StepStart = SYSDATETIME()

UPDATE  TT SET
    TT.[PercentTransfer] =
        CASE WHEN TT.[IsPartial] = 0                                                  THEN 1.00  
             WHEN TT.[TaxablePayRoll]       IS NULL OR [TaxablePayRoll]       <  0.00 THEN 0.00 
             WHEN TT.[ClientTaxablePayroll] IS NULL OR [ClientTaxablePayroll] <= 0.00 THEN 0.00 
             WHEN TT.[ClientTaxablePayroll] > [TaxablePayRoll]                        THEN 1.00 
             ELSE TT.[ClientTaxablePayroll] / [TaxablePayRoll] END
FROM #ttTransExp AS TT

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('UPDATE #ttTransExp [PercentTransfer]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

CREATE TABLE #ttTransExpPayroll
(
    [AnchorEmployerId]              INT,
    [EmployerID]                    INT,
    [AcquisitionID]                 BIGINT,
    [IsPartial]                     BIT,
    [SuccessorEmployerID]           INT,
    [PredecessorEmployerID]         INT,

    [Year]                          SMALLINT,
    [Quarter]                       TINYINT,
    [QtrIsTimely]                   BIT,
    [QtrTaxRateTimely]              BIT,

    [TaxablePayRollTimely]          MONEY,
    [TaxablePayRoll]                MONEY,
    [TotalPayRollTimely]            MONEY,
    [TotalPayRoll]                  MONEY
)

SET @StepStart = SYSDATETIME()

INSERT INTO #ttTransExpPayroll
SELECT -- [Account].[TaxRateExpPayRoll]
    ttAcqEmployers.[AnchorEmployerId],
    ttAcqEmployers.[PredecessorEmployerID],
    ttAcqEmployers.[AcquisitionID],
    ttAcqEmployers.[IsPartial],
    ttAcqEmployers.[SuccessorEmployerID],
    ttAcqEmployers.[PredecessorEmployerID],

    ttData.[Year],
    ttData.[Quarter],
    ttData.[QtrIsTimely],
    ttData.[QtrTaxRateTimely],

    ttData.[TaxablePayRollTimely],
    ttData.[TaxablePayRoll],
    ttData.[TotalPayRollTimely],
    ttData.[TotalPayRoll]

FROM #ttAcqEmployers AS ttAcqEmployers
INNER JOIN [Account].[TaxRateExpPayRoll] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
        AND ttData.[FiscalYear]          = ttAcqEmployers.[FiscalYear]
        AND ttAcqEmployers.[IsPartial]   = 0
        AND ttData.[EmployerID]          = ttAcqEmployers.[PredecessorEmployerID]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttTransExpPayroll: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- #1 DATA (KEEP IN ORDER):  TransferExperience
-- Acquisition experience (predecessor totals + PercentTransfer). The APPLICATION adds this to the Anchor-only
-- ReserveCalc row to calculate the final Reserve, ReserveRatio and rate. PercentTransfer is an input for the
-- application (it decides how to apply it to PARTIAL predecessors); nothing here is scaled by it.
SET @StepStart = SYSDATETIME()

SELECT -- *
     [AnchorEmployerId]
    ,[EmployerID]
    ,[AcquisitionID]
    ,[IsPartial]
    ,[SuccessorEmployerID]
    ,[PredecessorEmployerID]

    ,[TaxablePayRollTimely]
    ,[TaxablePayRoll]
    ,[TotalPayRollTimely]
    ,[TotalPayRoll]

    ,[TaxesPaid]
    ,[TaxesPaidAdjust]

    ,[TaxesPaidPrior]
    ,[TaxesPaidPriorAdjust]

    ,[BenefitsChargedClient]
    ,[BenefitsRelievedClient]
    ,[BenefitsTotalClientAdjust]

    ,[BenefitsChargedClientPrior]
    ,[BenefitsRelievedClientPrior]
    ,[BenefitsTotalClientPriorAdjust]

    ,[Year1]
    ,[TaxablePayRollTimelyYear1]
    ,[TaxablePayRollYear1]
    ,[TotalPayRollTimelyYear1]
    ,[TotalPayRollYear1]

    ,[Year2]
    ,[TaxablePayRollTimelyYear2]
    ,[TaxablePayRollYear2]
    ,[TotalPayRollTimelyYear2]
    ,[TotalPayRollYear2]

    ,[Year3]
    ,[TaxablePayRollTimelyYear3]
    ,[TaxablePayRollYear3]
    ,[TotalPayRollTimelyYear3]
    ,[TotalPayRollYear3]

    ,[ClientTaxablePayRoll]

    ,[Reserve]
    ,[PriorReserve]

    ,[PercentTransfer]
FROM #ttTransExp

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('RESULT SET #1 TransferExperience: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ==== TEMP TABLE NO LONGER UTILIZED ** EXCEPT FOR DEBUG ** : #ttTransExp

-- #2 DATA (KEEP IN ORDER):  TransferExperiencePayroll
SET @StepStart = SYSDATETIME()

SELECT -- *
     [AnchorEmployerId]
    ,[EmployerID]
    ,[AcquisitionID]
    ,[IsPartial]
    ,[SuccessorEmployerID]
    ,[PredecessorEmployerID]

    ,[Year]
    ,[Quarter]
    ,[QtrIsTimely]
    ,[QtrTaxRateTimely]

    ,[TaxablePayRollTimely]
    ,[TaxablePayRoll]
    ,[TotalPayRollTimely]
    ,[TotalPayRoll]
FROM #ttTransExpPayroll

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('RESULT SET #2 TransferExperiencePayroll: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttTransExpPayroll

-- #3 DATA (KEEP IN ORDER):  RateTypeDetermined
-- PROVISIONAL, Anchor-only Rate Type. The APPLICATION re-decides it after adding the acquisition experience
-- (including the 'Max-Rate :No Reserve Calc' fallback row).
SET @StepStart = SYSDATETIME()

SELECT distinct
     [EmployerID] -- INT
    ,[RateTypeDetermined] -- VARCHAR 100
    ,@FebMailingDateCutoff AS FebMailingDateCutoff -- DATE
FROM [Account].[TaxRateExpReserveCalc]
WHERE [AnchorEmployerID] = @AnchorEmployerID AND [EmployerID] = @AnchorEmployerID AND [FiscalYear] = @FiscalYear

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('RESULT SET #3 RateTypeDetermined: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- #4 DATA (KEEP IN ORDER):  StatDetLiability
SET @StepStart = SYSDATETIME()

;WITH CTE_OrderedStatDet AS (
    SELECT 
            [StatusDeterminationID]
        ,[EmployerID]
        ,[LiaStatus]
        ,[FinMeth]
        ,[EffDt]
        ,[EffEndDt]
        ,[ReActivation581Liability]
        ,[CovEffDate]
        ,[StatDetCreatedUtc]
        ,[StatDetRank]
        ,[StatDetOrder]
        ,COALESCE(
             LAG([CovEffDate],01) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],02) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],03) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],04) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],05) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],06) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],07) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],08) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],09) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],10) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],11) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
            ,LAG([CovEffDate],12) OVER (PARTITION BY [EmployerID] ORDER BY [StatDetOrder])
        ) AS [PrevCovEffDate]
    FROM (
        SELECT 
                ttSDRank.[StatusDeterminationID]
            ,ttSDRank.[EmployerID]
            ,ttSDRank.[LiaStatus]
            ,ttSDRank.[FinMeth]
            ,ttSDRank.[EffDt] AS [EffDt]
            ,MAX(ttSDRank.[EffEndDt]) AS [EffEndDt]
            ,MIN(ttSDRank.[ReActivation581Liability]) AS [ReActivation581Liability]
            ,MIN(ttSDRank.[CovEffDate]) AS [CovEffDate]
            ,MIN(ttSDRank.[StatDetCreatedUtc]) AS [StatDetCreatedUtc]
            ,ROW_NUMBER() OVER (PARTITION BY ttSDRank.[EmployerID] ORDER BY MIN(ttSDRank.[EffDt]) DESC) AS [StatDetRank]
            ,ROW_NUMBER() OVER (PARTITION BY ttSDRank.[EmployerID] ORDER BY MIN(ttSDRank.[EffDt]) ASC) AS [StatDetOrder]
        FROM (
            SELECT 
                ttSDOrder.[StatusDeterminationID],
                ttSDOrder.[EmployerID] AS [EmployerID],
                ttSDOrder.[EffectiveDate] AS [EffDt],
                ttSDOrder.[CoverageEffectiveDate],
                ttSDOrder.[CreatedDate],
                ttSDOrder.[LiaStatus] AS [LiaStatus],
                ttSDOrder.[FinMeth] AS [FinMeth],
                CASE 
                    WHEN DateAdd(DAY, -1, LEAD(ttSDOrder.[EffectiveDate], 1, '9999-12-31') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])) < ttSDOrder.[EffectiveDate]
                    THEN ttSDOrder.[EffectiveDate] 
                    ELSE DateAdd(DAY, -1, LEAD(ttSDOrder.[EffectiveDate], 1, '9999-12-31') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]))
                END AS [EffEndDt],
                CASE 
                    WHEN ttSDOrder.[CoverageEffectiveDate] IS NULL AND ttSDOrder.[LiaStatus]     IN ('ACTIVE', 'REACTIVATED') AND LAG(ttSDOrder.[LiaStatus], 1, '') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]) NOT IN ('ACTIVE', 'REACTIVATED') 
                    THEN ttSDOrder.[EffectiveDate] 
                    WHEN ttSDOrder.[CoverageEffectiveDate] IS NOT NULL AND ttSDOrder.[LiaStatus] IN ('ACTIVE', 'REACTIVATED') AND LAG(ttSDOrder.[LiaStatus], 1, '') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]) NOT IN ('ACTIVE', 'REACTIVATED')
                    THEN ttSDOrder.[CoverageEffectiveDate] 
                    WHEN ttSDOrder.[CoverageEffectiveDate] IS NULL AND ttSDOrder.[LiaStatus]     IN ('ACTIVE', 'REACTIVATED') AND LAG(ttSDOrder.[LiaStatus], 1, '') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])  IN ('ACTIVE', 'REACTIVATED')
                    THEN LAG(ttSDOrder.[CoverageEffectiveDate], 1) OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])
                END AS [ReActivation581Liability],
                ttSDOrder.[CoverageEffectiveDate] AS [CovEffDate],
                ttSDOrder.[CreatedDate] AS [StatDetCreatedUtc]
            FROM (
                SELECT 
                    ttSD1.[StatusDeterminationID],
                    ttLiaStat.[LiabilityStatusID], 
                    ttSD1.[EmployerID],
                    ttLiaStat.[Code] AS [LiaStatus],
                    ttFinMeth.[Code] AS [FinMeth],
                    ttSD1.[EffectiveDate],
                    ttSD1.[CoverageEffectiveDate],
                    ttSD1.[CreatedDate],
                    ISNULL(ttFirstDates.[CovEffDt1st], ttFirstDates.[EffDt1st]) AS [LiabilityDate]
                FROM (
                    SELECT 
                        ttSD0.[EmployerID], 
                        MIN(ttSD0.[CoverageEffectiveDate])  AS [CovEffDt1st], 
                        MIN(ttSD0.[EffectiveDate])          AS [EffDt1st]
                    FROM [Account].[StatusDetermination]    AS ttSD0
                    JOIN #ttAcqEmployers                    AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID] = ttSD0.[EmployerID]
                    JOIN [Account].[Employer]                                 ON [Employer].[EmployerID] = ttSD0.[EmployerID]
                    WHERE ttSD0.[IsEnabled] = 1
                    GROUP BY ttSD0.[EmployerID]
                ) AS ttFirstDates
                JOIN [Account].[StatusDetermination]   AS ttSD1     ON ttSD1.[EmployerID]            = ttFirstDates.[EmployerID] AND ttSD1.[IsEnabled] = 1
                JOIN [Account].[Employer]              AS ttEmp     ON ttEmp.[EmployerID]            = ttSD1.[EmployerID]
                JOIN [Configuration].[LiabilityStatus] AS ttLiaStat ON ttLiaStat.[LiabilityStatusID] = ttSD1.[LiabilityStatusID]
                JOIN [Configuration].[FinancingMethod] AS ttFinMeth ON ttFinMeth.[FinancingMethodID] = ttEmp.[CurrentFinancingMethodID]
            ) ttSDOrder
        ) as ttSDRank
        GROUP BY
                ttSDRank.[StatusDeterminationID]
            ,ttSDRank.[EmployerID]
            ,ttSDRank.[EffDt]
            ,ttSDRank.[LiaStatus]
            ,ttSDRank.[FinMeth]
    ) AS ttStatus
),  
CTE_FirstCovEffDate AS (
    SELECT 
        [EmployerID],
        MIN(XX.CoverageEffectiveDate) AS [FirstLiabilityDate]
    FROM [Account].[StatusDetermination] AS XX
    GROUP BY [EmployerID]
), 
CTE_SdLiability as (
    SELECT 
            [StatusDeterminationID]
        ,ttPrevStatus.[EmployerID]
        ,[LiaStatus]
        ,[FinMeth]
        ,[EffDt]
        ,[EffEndDt]
        ,[ReActivation581Liability]
        ,[CovEffDate]
        ,[StatDetCreatedUtc]
        ,[StatDetRank]   -- Stat Det Rank
        ,[StatDetOrder]  -- Stat Det Order
        ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], [EffDt]     ORDER BY [StatDetRank] ) AS [EffDtRank]      -- Stat Det Rank  within Eff Dt
        ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], [EffDt]     ORDER BY [StatDetOrder]) AS [EffDtOrder]     -- Stat Det Order within Eff Dt
        ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], [LiaStatus] ORDER BY [StatDetRank])  AS [LiaStatusRank]  -- Stat Det Rank  within Lia Status
        ,ROW_NUMBER() OVER (PARTITION BY ttPrevStatus.[EmployerID], [LiaStatus] ORDER BY [StatDetOrder]) AS [LiaStatusOrder] -- Stat Det Order within Lia Status
        ,CASE WHEN [CovEffDate] IS NULL THEN [PrevCovEffDate] ELSE [CovEffDate] END AS [LiabilityDate]
        ,ttFirstCovEffDate.[FirstLiabilityDate]
    FROM CTE_OrderedStatDet AS ttPrevStatus
    JOIN CTE_FirstCovEffDate ttFirstCovEffDate ON ttPrevStatus.[EmployerID] = ttFirstCovEffDate.[EmployerID]
)
SELECT -- *
     [StatusDeterminationID]
    ,[EmployerID]
    ,[LiaStatus]
    ,[FinMeth]
    ,[EffDt]
    ,[EffEndDt]
    ,[ReActivation581Liability]
    ,[CovEffDate]
    ,[StatDetCreatedUtc]
    ,[StatDetRank]
    ,[StatDetOrder]
    ,[EffDtRank]
    ,[EffDtOrder]
    ,[LiaStatusRank]
    ,[LiaStatusOrder]
    ,[LiabilityDate]
    ,[FirstLiabilityDate]
FROM CTE_SdLiability

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('RESULT SET #4 StatDetLiability: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- #5 DATA (KEEP IN ORDER):  TaxRateHawaii
-- Returns the [Account].[TaxRateHawaii] rows for every employer in #ttAcqEmployers:
--   1. the Anchor employer            (joined on [AnchorEmployerId])
--   2. each Successor employer        (joined on [SuccessorEmployerID])
--   3. each Predecessor employer      (joined on [PredecessorEmployerID]; also covers the Anchor's own row)
-- A row is returned when its [FiscalYear] is either:
--   - the Fiscal Year being rated (ttAcqEmployers.[FiscalYear]), OR
--   - for acquisition rows ([AcquisitionDate] IS NOT NULL), the calendar year of the Acquisition Date
-- The three sets are combined with UNION ALL, and the outer SELECT DISTINCT removes duplicate rows
-- (e.g. the Anchor matched as both Anchor and Predecessor, or an employer that is in more than one acquisition).
SET @StepStart = SYSDATETIME()

SELECT DISTINCT ttTaxRateHawaii.*
FROM (
    SELECT DISTINCT [TaxRateHawaii].*
        FROM [Account].[TaxRateHawaii] 
        JOIN #ttAcqEmployers AS ttAcqEmployers ON ttAcqEmployers.[AnchorEmployerId] = [TaxRateHawaii].[EmployerID]
        WHERE  
            [TaxRateHawaii].[FiscalYear] = ttAcqEmployers.[FiscalYear]  OR
            (ttAcqEmployers.[AcquisitionDate] IS NOT NULL AND [TaxRateHawaii].[FiscalYear] = YEAR(ttAcqEmployers.[AcquisitionDate]))

    UNION ALL

    SELECT DISTINCT [TaxRateHawaii].*
        FROM [Account].[TaxRateHawaii] 
        JOIN #ttAcqEmployers AS ttAcqEmployers ON ttAcqEmployers.[SuccessorEmployerID] = [TaxRateHawaii].[EmployerID]
        WHERE  
            [TaxRateHawaii].[FiscalYear] = ttAcqEmployers.[FiscalYear]  OR
            (ttAcqEmployers.[AcquisitionDate] IS NOT NULL AND [TaxRateHawaii].[FiscalYear] = YEAR(ttAcqEmployers.[AcquisitionDate]))

    UNION ALL

    SELECT DISTINCT [TaxRateHawaii].*
        FROM [Account].[TaxRateHawaii] 
        JOIN #ttAcqEmployers AS ttAcqEmployers ON ttAcqEmployers.[PredecessorEmployerID] = [TaxRateHawaii].[EmployerID]
        WHERE  
            [TaxRateHawaii].[FiscalYear] = ttAcqEmployers.[FiscalYear]  OR
            (ttAcqEmployers.[AcquisitionDate] IS NOT NULL AND [TaxRateHawaii].[FiscalYear] = YEAR(ttAcqEmployers.[AcquisitionDate])) 

) AS ttTaxRateHawaii

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('RESULT SET #5 TaxRateHawaii: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

PRINT CONCAT('TOTAL elapsed: ', DATEDIFF(MILLISECOND, @ProcStart, SYSDATETIME()), ' ms')

-- ==== TEMP TABLE NO LONGER UTILIZED ** EXCEPT FOR DEBUG ** : #ttAcqEmployers

--
IF @Show_Debug_Data = 'Y'
BEGIN

    PRINT ''
    PRINT '=================================================='
    PRINT ' SHOW DEBUG DATA '
    PRINT '=================================================='
    PRINT ''

    SET @StepStart = SYSDATETIME()

    --PRINT ''
    --PRINT 'RUN/EXECUTE [Account].[RunningReserveCalculate]'
    --PRINT ''

    --EXECUTE [Account].[RunningReserveCalculate] @ParamEmployerID = @ParamEmployerID, @ParamUser = 63005
    --SELECT * FROM [Account].[RunningReserve] WHERE [EmployerID] = @ParamEmployerID

    --SET @StepRows = @@ROWCOUNT
    --PRINT CONCAT('[RunningReserveCalculate]', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

    --PRINT ''
    --PRINT 'DONE -RUN/EXECUTE [Account].[RunningReserveCalculate]'
    --PRINT ''

    SET @StepStart = SYSDATETIME()

    SELECT 

       PriorReserve = ISNULL(TaxesPaidPrior, 0.00) - 
                      (ISNULL(BenefitsChargedClientPrior, 0.00) - ISNULL(BenefitsRelievedClientPrior, 0.00)) +  -- BenefitsTotalClientPrior
                      ISNULL(BenefitsTotalClientPriorAdjust, 0.00),                                             -- BenefitsTotalClientPriorAdjust

       Contributions = ISNULL(TaxesPaid, 0.00),

       Charges       = ISNULL(BenefitsChargedClient, 0.00) - ISNULL(BenefitsRelievedClient, 0.00),


       Reserve       = ISNULL(TaxesPaid, 0.00) - 
                       (ISNULL(BenefitsChargedClient, 0.00) - ISNULL(BenefitsRelievedClient, 0.00)) + -- BenefitsTotalClient
                       ISNULL(BenefitsTotalClientAdjust, 0.00),                                       -- BenefitsTotalClientAdjust

       Timely3Yr    = (ISNULL(TaxablePayRollTimelyYear1, 0.00) + ISNULL(TaxablePayRollTimelyYear2, 0.00) + ISNULL(TaxablePayRollTimelyYear3, 0.00)),
       Timely3YrAvg = (ISNULL(TaxablePayRollTimelyYear1, 0.00) + ISNULL(TaxablePayRollTimelyYear2, 0.00) + ISNULL(TaxablePayRollTimelyYear3, 0.00)) / 3.0,

       '<<< VALUES' AS 'VALUES',


       TaxesPaid,
       TaxesPaidPrior,

       BenefitsChargedClient,
       BenefitsRelievedClient,
       BenefitsTotalClient       = ISNULL(BenefitsChargedClient, 0.00) - ISNULL(BenefitsRelievedClient, 0.00),

       BenefitsTotalClientAdjust,
       --BenefitsTotalClientAdjust = ISNULL(BenefitsTotalClientAdjust, 0.00),

       BenefitsChargedClientPrior,
       BenefitsRelievedClientPrior,
       BenefitsTotalClientPrior       = ISNULL(BenefitsChargedClientPrior, 0.00) - ISNULL(BenefitsRelievedClientPrior, 0.00),

       BenefitsTotalClientPriorAdjust,
       --BenefitsTotalClientPriorAdjust = ISNULL(BenefitsTotalClientPriorAdjust, 0.00),

       TaxablePayRollTimelyYear1,
       TaxablePayRollTimelyYear2,
       TaxablePayRollTimelyYear3,

       '<<< DATA' AS 'DATA'
    FROM #ttTransExp

    SET @StepRows = @@ROWCOUNT
    PRINT CONCAT('Data Check', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

    SET @StepStart = SYSDATETIME()

    SELECT -- [Account].[TaxRateExpTaxesPaid]
         'Debug TaxesPaid' 'Debug TaxesPaid',
         ttData.[AnchorEmployerID]
        ,ttData.[EmployerID]
        ,ttData.[FiscalYear]
        ,ttData.[Year]
        ,ttData.[Quarter]

        ,ttData.[TaxesPaid]
        ,ttData.[TaxesPaidPrior]

        ,ttData.[AcquisitionID]
        ,ttData.[IsPartial]
    FROM #ttAcqEmployers AS ttAcqEmployers
    LEFT JOIN [Account].[TaxRateExpTaxesPaid] AS ttData ON ttData.[AnchorEmployerID] = ttAcqEmployers.[AnchorEmployerID]
            AND ttData.[EmployerID]        = ttAcqEmployers.[PredecessorEmployerID] 
            AND ttAcqEmployers.[IsPartial] = 0
    WHERE  1=1
        AND ttData.[AnchorEmployerId]  = @AnchorEmployerId 
        AND ttData.[FiscalYear]        = ttAcqEmployers.[FiscalYear] 
    ORDER BY 
         ttData.[AnchorEmployerID], 
         ttData.[EmployerID],
         ttData.[FiscalYear]
        ,ttData.[Year]
        ,ttData.[Quarter]

    SET @StepRows = @@ROWCOUNT
    PRINT CONCAT('[Account].[TaxRateExpTaxesPaid]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

END

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttTransExp
-- ==== TEMP TABLE NO LONGER UTILIZED: #ttAcqEmployers

---- Session temp tables: drop if they exist from a prior run in this session
DROP TABLE IF EXISTS #ValidTransferTypes;
DROP TABLE IF EXISTS #PartialTransferTypes;
DROP TABLE IF EXISTS #BasePeriod;
DROP TABLE IF EXISTS #ttAcquistions;
DROP TABLE IF EXISTS #ttAcqEmployers;
DROP TABLE IF EXISTS #EmpolyerSD;
DROP TABLE IF EXISTS #EmplStatDet;
DROP TABLE IF EXISTS #TaxQuartersQwrQwraLateStatus;
DROP TABLE IF EXISTS #MissingIds;
DROP TABLE IF EXISTS #ttTransExp;
DROP TABLE IF EXISTS #ttTransExpPayroll;
DROP TABLE IF EXISTS #ttRC_StatDet;
DROP TABLE IF EXISTS #ttRC_TaxQtr;
DROP TABLE IF EXISTS #ttRC_QtrStatus;
DROP TABLE IF EXISTS #ttRC_QtrFlags;
DROP TABLE IF EXISTS #ttRC_BasePeriodSum;
DROP TABLE IF EXISTS #ttRC_Money;
DROP TABLE IF EXISTS #ttRC_Adjust;
DROP TABLE IF EXISTS #ttRC_Source;

END


