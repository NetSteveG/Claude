


--CREATE PROCEDURE [Account].[TaxRateExpAnchorReserveCalcRun]
--    @ParamFiscalYear      SMALLINT, -- Always passed a value
--    @ParamEmployerID      INT,  -- Always passed a value
--WITH RECOMPILE
--AS --- STORED PROCEDURE
BEGIN

-- Session temp tables: drop if they exist from a prior run in this session
DROP TABLE IF EXISTS #ValidTransferTypes;
DROP TABLE IF EXISTS #PartialTransferTypes;
DROP TABLE IF EXISTS #BasePeriod;
DROP TABLE IF EXISTS #BasePeriodDatePriorCommonTable;
DROP TABLE IF EXISTS #ttAcquistions;
DROP TABLE IF EXISTS #ttAcquistionsNotPendApp;
DROP TABLE IF EXISTS #ttAcqEmployers;
DROP TABLE IF EXISTS #EmpolyerSD;
DROP TABLE IF EXISTS #EmplStatDet;
DROP TABLE IF EXISTS #TaxQuartersQwrQwraLateStatus;
DROP TABLE IF EXISTS #MissingIds;
DROP TABLE IF EXISTS #ttTransExp;
DROP TABLE IF EXISTS #ttTransExpPayroll;


DECLARE @ParamFiscalYear      SMALLINT     = 2026;
DECLARE @ParamEmployerID      INT          = 2110212048 -- 284477044 --  213373310 284476289

-- ====================================================================================================

-- SELECT [Code] FROM [Configuration].[TransferType]

DECLARE @TransferTypeUC86        VARCHAR(50) = 'UC86'
DECLARE @TransferTypeSUTAFULL    VARCHAR(50) = 'SUTAFULL'
DECLARE @TransferTypeSUTAPARTIAL VARCHAR(50) = 'SUTAPARTIAL'

CREATE TABLE #ValidTransferTypes ([ValidTransferType] VARCHAR(100) COLLATE DATABASE_DEFAULT)

INSERT INTO #ValidTransferTypes
----------SELECT [Code] FROM [Configuration].[TransferType] WHERE [Code] <> 'NONE' ---------- FOR TESTING
VALUES 
 (@TransferTypeUC86)
,(@TransferTypeSUTAFULL)
,(@TransferTypeSUTAPARTIAL)

-- Partial Transfer Type

CREATE TABLE #PartialTransferTypes ([PartialTransferType] VARCHAR(100) COLLATE DATABASE_DEFAULT)

INSERT INTO #PartialTransferTypes
----------SELECT [Code] FROM [Configuration].[TransferType] WHERE [Code] <> 'NONE' ---------- FOR TESTING
VALUES 
(@TransferTypeSUTAPARTIAL)
------------ FOR TESTING
--,(@TransferTypeSUTAFULL)
--,(@TransferTypeUC86)
--,('FULL')
--,('SSNLIST')
--,('SSNLISTPENDING')
--,('PNCONVERSION')
--,('PBCONVERSION')
--,('PICONVERSION')
--,('PFCONVERSION')

DECLARE @LocalTimeZone        SYSNAME -- = 'Hawaiian Standard Time'
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


DECLARE @FebMailingDate            DATE = [dbo].[GetFebBillStatementMailingDate](@FiscalYear);
DECLARE @FebMailingDateCutoff      DATE = [dbo].[GetFebBillStatementMailingCutoffDate](@FiscalYear);
DECLARE @FebMailingDatePrior       DATE = [dbo].[GetFebBillStatementMailingDate](@FiscalYear - 1);
DECLARE @FebMailingDateCutoffPrior DATE = [dbo].[GetFebBillStatementMailingCutoffDate](@FiscalYear -1);

DECLARE @NumberOfYears     INT   = 3;

DECLARE @maxReserveRatio DECIMAL(19, 4) =  9999.9999;
DECLARE @minReserveRatio DECIMAL(19, 4) = -9999.9999;

DECLARE @MaxAcqProcUtc               DATE   = '9999-12-31'
DECLARE @MaxCreatedAcquistions DATETIME2(2) = '9999-12-31'
DECLARE @MaxCreatedStatDet     DATETIME2(2) = '9999-12-31'
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

CREATE TABLE #BasePeriodDatePriorCommonTable ([BasePeriodDatePrior] DATE)

INSERT INTO #BasePeriodDatePriorCommonTable
SELECT TOP 1 [BasePeriodDatePrior] FROM #BasePeriod group by [BasePeriodDatePrior] HAVING COUNT(*) = 4
OPTION (RECOMPILE)

DECLARE @BasePeriodDatePriorCommon DATE = (SELECT TOP 1 [BasePeriodDatePrior] FROM #BasePeriodDatePriorCommonTable)

DECLARE @YearQtr1 INT = (SELECT    MIN([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM #BasePeriod)
DECLARE @YearQtr2 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM #BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr1
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr3 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM #BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr2
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr4 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM #BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr3
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr5 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM #BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr4
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr6 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM #BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr5
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr7 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM #BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr6
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))

-- ====================================================================================================

PRINT '=============================================='
PRINT '[Account].[TaxRateExpAnchorReserveCalcRun] Calculate'
PRINT ''
PRINT '@AnchorEmployerID           : ' + CAST(@AnchorEmployerID   AS VARCHAR)
PRINT '@FiscalYear                 : ' + CAST(@FiscalYear         AS VARCHAR)
PRINT ''

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

-- Predessors

DECLARE @PathSep    VARCHAR(2)     = ','
DECLARE @PathSepBeg VARCHAR(2)     = ':'

-- =================================================================

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


    ---- Data Filled in from Employer Portal in Application Code
    --[AppFormType]               VARCHAR (100),
    --[FormReviewAction]          VARCHAR (100),  
    --[ResponseDate]              DATETIME2(2),   -- Submission date of the approval
    --[IsSystemDecision]          BIT,            -- 0 ==> indicates it was a manual process that updated.

    ------ Timely:: 
    --[DayCntAcqDtToResponse]     INT,           
    --[EmpFormReviewRuleRank]     BIGINT,
    --[EmpFormReviewRulesCreated] DATETIME2(2),
    --[EmployerFormReviewRulesId] BIGINT,
)
CREATE TABLE #ttAcquistionsNotPendApp 
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


    ---- Data Filled in from Employer Portal in Application Code
    --[AppFormType]               VARCHAR (100),
    --[FormReviewAction]          VARCHAR (100),  
    --[ResponseDate]              DATETIME2(2),   -- Submission date of the approval
    --[IsSystemDecision]          BIT,            -- 0 ==> indicates it was a manual process that updated.

    ------ Timely:: 
    --[DayCntAcqDtToResponse]     INT,           
    --[EmpFormReviewRuleRank]     BIGINT,
    --[EmpFormReviewRulesCreated] DATETIME2(2),
    --[EmployerFormReviewRulesId] BIGINT,
)

/*
Get all the ttAcq records in whech the predecessor is a successor. Walk through all the records, 
if walking through the list starts you find a predecessor that was already fopund don't wlk the list twice
*/


-- Anchor as successor - [RecType] = 0
;WITH AnchorAcq AS
(
    -- Your filtered dataset
    SELECT 
         ttAcq.[AcquisitionID]
        ,ttAcq.[SuccessorEmployerID]
        ,ttAcq.[PredecessorEmployerID]
        ,ttAcq.[AcquisitionDate]        AS [AcquisitionDate]
        ,ttAcq.[CreatedDate]            AS [AcquisitionCreated]
        ,ttAcq.[SutaCutoffYear]
        ,ttAcq.[ExperienceTransferID]
        ,ttAcq.[FormApplicationId]
    FROM [Account].[Acquisition] AS ttAcq
    INNER JOIN [Account].[ExperienceTransfer] AS ttExpTransPrev     ON ttExpTransPrev.[ExperienceTransferID] = ttAcq.[ExperienceTransferID]
    INNER JOIN [Configuration].[TransferType] AS ttTransferTypePrev ON ttTransferTypePrev.[TransferTypeID] = ttExpTransPrev.[TransferTypeID]
    WHERE 
        -- only going one DEEP so SuccessorEmployerID = @AnchorEmployerID
            ttAcq.[SuccessorEmployerID] = @AnchorEmployerID
        AND ttTransferTypePrev.[Code] IN (SELECT [ValidTransferType] FROM #ValidTransferTypes)
        AND ttAcq.[CreatedDate] < @MaxCreatedAcquistions

        -- Status filters 
        AND (
            SELECT TOP 1 YY.[Code]
            FROM [Account].[StatusDetermination] XX
            JOIN [Configuration].[LiabilityStatus] YY 
                ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]
            WHERE XX.IsEnabled = 1 
              AND XX.[EmployerID] = ttAcq.[SuccessorEmployerID]
            ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC
        ) IN ('ACTIVE','REACTIVATED','INACTIVE','TERMINATED')

        AND (
            SELECT TOP 1 YY.[Code]
            FROM [Account].[StatusDetermination]   XX
            JOIN [Configuration].[LiabilityStatus] YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]
            WHERE XX.IsEnabled = 1 
              AND XX.[EmployerID] = ttAcq.[PredecessorEmployerID]
            ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC
        ) IN ('ACTIVE','REACTIVATED','INACTIVE','TERMINATED')
),

RecursiveCTE AS
(
    -- Anchor
    SELECT 
         b.*
        ,CAST(',' + CAST(b.SuccessorEmployerID AS VARCHAR(20)) + ',' AS VARCHAR(MAX)) AS [NavPath]
    FROM AnchorAcq b

    UNION ALL

    -- Walk: predecessor becomes next successor
    SELECT 
         b.*
        ,r.[NavPath] + CAST(b.SuccessorEmployerID AS VARCHAR(20)) + ','
    FROM AnchorAcq b
    INNER JOIN RecursiveCTE r ON b.SuccessorEmployerID = r.PredecessorEmployerID

    -- Prevent revisiting (no double walking)
    WHERE r.[NavPath] NOT LIKE '%,' + CAST(b.SuccessorEmployerID AS VARCHAR(20)) + ',%'
)
--SELECT DISTINCT * FROM RecursiveCTE OPTION (MAXRECURSION 32767);
INSERT INTO #ttAcquistions 
(
     [RecType]
      --,[BaseType]
    ,[AnchorEmployerId]
    ,[SuccessorEmployerID]
    ,[PredecessorEmployerID]

    -- Aditional Fields
    ,[AcquisitionID]
    ,[AcquisitionDate]
    ,[AcquisitionCreated]
    ,[SutaCutoffYear]
    ,[ExperienceTransferID]
    ,[FormApplicationId]

    ,[NavLevel] 
    ,[NavPath]

    -- Supporting Data

    ,[TransferType]
    ,[IsPartial]

    ---- Stat Det - Liability Status - CURRENT
    ,[SuccCurLiaStat]
    ,[PredCurLiaStat]
)
SELECT distinct
    --ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS RowID,
    ttProcessStatus.*
FROM (
SELECT DISTINCT 

     0   AS [RecType]
    --,'S' AS [BaseType]
    ,@AnchorEmployerID AS [AnchorEmployerId]

    ,RecursiveCTE.[SuccessorEmployerID]
    ,RecursiveCTE.[PredecessorEmployerID]

    -- Aditional Fields
    ,RecursiveCTE.[AcquisitionID]
    ,RecursiveCTE.[AcquisitionDate]
    ,RecursiveCTE.[AcquisitionCreated]
    ,RecursiveCTE.[SutaCutoffYear]
    ,RecursiveCTE.[ExperienceTransferID]
    ,RecursiveCTE.[FormApplicationId]

    ,LEN(RecursiveCTE.[NavPath]) - LEN(REPLACE(RecursiveCTE.[NavPath], ',', '')) AS [NavLevel] 
    ,RecursiveCTE.[NavPath]

    -- Supporting Data 

    ,ttTransferType.[Code]                         AS [TransferType]
    ,CASE WHEN ttPartialTransferTypes.[PartialTransferType] IS NOT NULL THEN 1 ELSE 0 END AS [IsPartial]

    --,ttProcStat.[ProcessStatusID] AS [ProcStatID]
    --,ttProcStat.[ProcessId]
    --,ttProcStat.[EffectiveDate]   AS [ProcStatEffDt]
    --,ttProcStat.[CreatedDate]     AS [ProcStatCreated]

    --,ttProcDefn.[ProcessCode]     AS [ProcessCode]
    --,ttStat.[Code]                AS [StatusCode]

    ---- Stat Det - Liability Status - CURRENT

    ,(SELECT TOP 1 YY.[Code]
        FROM [Account].[StatusDetermination]   AS XX 
        JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]                  
        WHERE XX.IsEnabled = 1
          AND XX.[CreatedDate]  < @MaxCreatedAcquistions
          AND XX.[EmployerID]   = RecursiveCTE.[SuccessorEmployerID] 
        ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC) AS SuccCurLiaStat

    ,(SELECT TOP 1 YY.[Code]
        FROM [Account].[StatusDetermination]   AS XX 
        JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]                  
        WHERE XX.IsEnabled = 1 
          AND XX.[CreatedDate]  < @MaxCreatedAcquistions
          AND XX.[EmployerID]   = RecursiveCTE.[PredecessorEmployerID] 
        ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC) AS PredCurLiaStat

FROM RecursiveCTE
INNER JOIN [Account].[ExperienceTransfer] AS ttExpTrans             ON ttExpTrans.[ExperienceTransferID]   = RecursiveCTE.[ExperienceTransferID]
INNER JOIN [Configuration].[TransferType] AS ttTransferType         ON ttTransferType.[TransferTypeID]     = ttExpTrans.[TransferTypeID]
LEFT  JOIN #PartialTransferTypes          AS ttPartialTransferTypes ON ttPartialTransferTypes.PartialTransferType = ttTransferType.[Code]
) AS ttProcessStatus
OPTION (MAXRECURSION 32767);

-- Anchor as predessor - [RecType] = 0
;WITH AnchorAcq AS
(
    -- Your filtered dataset
    SELECT 
         ttAcq.[AcquisitionID]
        ,ttAcq.[SuccessorEmployerID]
        ,ttAcq.[PredecessorEmployerID]
        ,ttAcq.[AcquisitionDate]        AS [AcquisitionDate]
        ,ttAcq.[CreatedDate]            AS [AcquisitionCreated]
        ,ttAcq.[SutaCutoffYear]
        ,ttAcq.[ExperienceTransferID]
        ,ttAcq.[FormApplicationId]
    FROM [Account].[Acquisition] AS ttAcq
    INNER JOIN [Account].[ExperienceTransfer] AS ttExpTransPrev     ON ttExpTransPrev.[ExperienceTransferID] = ttAcq.[ExperienceTransferID]
    INNER JOIN [Configuration].[TransferType] AS ttTransferTypePrev ON ttTransferTypePrev.[TransferTypeID] = ttExpTransPrev.[TransferTypeID]
    WHERE 
            ttAcq.[PredecessorEmployerID] = @AnchorEmployerID
        AND ttTransferTypePrev.[Code] IN (SELECT [ValidTransferType] FROM #ValidTransferTypes)
        AND ttAcq.[CreatedDate] < @MaxCreatedAcquistions

        -- Status filters 
        AND (
            SELECT TOP 1 YY.[Code]
            FROM [Account].[StatusDetermination] XX
            JOIN [Configuration].[LiabilityStatus] YY 
                ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]
            WHERE XX.IsEnabled = 1 
              AND XX.[EmployerID] = ttAcq.[SuccessorEmployerID]
            ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC
        ) IN ('ACTIVE','REACTIVATED','INACTIVE','TERMINATED')

        AND (
            SELECT TOP 1 YY.[Code]
            FROM [Account].[StatusDetermination] XX
            JOIN [Configuration].[LiabilityStatus] YY 
                ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]
            WHERE XX.IsEnabled = 1 
              AND XX.[EmployerID] = ttAcq.[PredecessorEmployerID]
            ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC
        ) IN ('ACTIVE','REACTIVATED','INACTIVE','TERMINATED')
),

RecursiveCTE AS
(
    -- Anchor
    SELECT 
         b.*
        ,CAST(',' + CAST(b.SuccessorEmployerID AS VARCHAR(20)) + ',' AS VARCHAR(MAX)) AS [NavPath]
    FROM AnchorAcq b
)
--SELECT DISTINCT * FROM RecursiveCTE OPTION (MAXRECURSION 32767);
INSERT INTO #ttAcquistions 
(
     [RecType]
      --,[BaseType]
    ,[AnchorEmployerId]
    ,[SuccessorEmployerID]
    ,[PredecessorEmployerID]

    -- Aditional Fields
    ,[AcquisitionID]
    ,[AcquisitionDate]
    ,[AcquisitionCreated]
    ,[SutaCutoffYear]
    ,[ExperienceTransferID]
    ,[FormApplicationId]

    ,[NavLevel] 
    ,[NavPath]

    -- Supporting Data

    ,[TransferType]
    ,[IsPartial]

    ---- Stat Det - Liability Status - CURRENT
    ,[SuccCurLiaStat]
    ,[PredCurLiaStat]
)
SELECT distinct
    --ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS RowID,
    ttProcessStatus.*
FROM (
SELECT DISTINCT 

     0   AS [RecType]
    --,'P' AS [BaseType]
    ,@AnchorEmployerID AS [AnchorEmployerId]

    ,RecursiveCTE.[SuccessorEmployerID]
    ,RecursiveCTE.[PredecessorEmployerID]

    -- Aditional Fields
    ,RecursiveCTE.[AcquisitionID]
    ,RecursiveCTE.[AcquisitionDate]
    ,RecursiveCTE.[AcquisitionCreated]
    ,RecursiveCTE.[SutaCutoffYear]
    ,RecursiveCTE.[ExperienceTransferID]
    ,RecursiveCTE.[FormApplicationId]

    ,LEN(RecursiveCTE.[NavPath]) - LEN(REPLACE(RecursiveCTE.[NavPath], ',', '')) AS [NavLevel] 
    ,RecursiveCTE.[NavPath]

    -- Supporting Data 

    ,ttTransferType.[Code]                         AS [TransferType]
    ,CASE WHEN ttPartialTransferTypes.[PartialTransferType] IS NOT NULL THEN 1 ELSE 0 END AS [IsPartial]

    --,ttProcStat.[ProcessStatusID] AS [ProcStatID]
    --,ttProcStat.[ProcessId]
    --,ttProcStat.[EffectiveDate]   AS [ProcStatEffDt]
    --,ttProcStat.[CreatedDate]     AS [ProcStatCreated]

    --,ttProcDefn.[ProcessCode]     AS [ProcessCode]
    --,ttStat.[Code]                AS [StatusCode]

    ---- Stat Det - Liability Status - CURRENT

    ,(SELECT TOP 1 YY.[Code]
        FROM [Account].[StatusDetermination]   AS XX 
        JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]                  
        WHERE XX.IsEnabled = 1
          AND XX.[CreatedDate]  < @MaxCreatedAcquistions
          AND XX.[EmployerID]   = RecursiveCTE.[SuccessorEmployerID] 
        ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC) AS SuccCurLiaStat

    ,(SELECT TOP 1 YY.[Code]
        FROM [Account].[StatusDetermination]   AS XX 
        JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]                  
        WHERE XX.IsEnabled = 1 
          AND XX.[CreatedDate]  < @MaxCreatedAcquistions
          AND XX.[EmployerID]   = RecursiveCTE.[PredecessorEmployerID] 
        ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC) AS PredCurLiaStat

FROM RecursiveCTE
INNER JOIN [Account].[ExperienceTransfer] AS ttExpTrans             ON ttExpTrans.[ExperienceTransferID]   = RecursiveCTE.[ExperienceTransferID]
INNER JOIN [Configuration].[TransferType] AS ttTransferType         ON ttTransferType.[TransferTypeID]     = ttExpTrans.[TransferTypeID]
LEFT  JOIN #PartialTransferTypes          AS ttPartialTransferTypes ON ttPartialTransferTypes.PartialTransferType = ttTransferType.[Code]
) AS ttProcessStatus
OPTION (MAXRECURSION 32767);

-- UPDATE -- If the current status of a [PredecessorEmployerID] is NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
-- PredCurLiaStat NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
UPDATE TT SET 
  TT.[CurrentStatusExclude] = ttNotActInActTermList.[CurrentStatusExclude]
FROM #ttAcquistions TT
INNER JOIN 
(SELECT AnchorEmployerId, STRING_AGG(CAST(PredecessorEmployerID AS VARCHAR(20)), ',') WITHIN GROUP (ORDER BY PredecessorEmployerID) AS [CurrentStatusExclude]
   FROM (-- if the Predecessor is not in ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED') then exclude and terminate traversing
         SELECT DISTINCT AnchorEmployerId, PredecessorEmployerID
         FROM #ttAcquistions WHERE 1=1 AND PredCurLiaStat NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
         ) AS DistinctPreds GROUP BY AnchorEmployerId
) AS ttNotActInActTermList ON ttNotActInActTermList.[AnchorEmployerId] = TT.[AnchorEmployerId]
OPTION (RECOMPILE);

-- REMOVE: SuccessorEmployerID or PredecessorEmployerID if in [CurrentStatusExclude]
-- Will Exclude if not in NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
DELETE A
FROM #ttAcquistions AS A
CROSS APPLY STRING_SPLIT(A.[CurrentStatusExclude], ',') AS ttExclude
WHERE 
    -- Traversing means that a Successor was one a predecessor so check both
       TRY_CAST(ttExclude.value AS INT) = A.[SuccessorEmployerID]   
    OR TRY_CAST(ttExclude.value AS INT) = A.[PredecessorEmployerID]
OPTION (RECOMPILE);

-- #ttAcqEmployers will include the employers that we will be processed
CREATE TABLE #ttAcqEmployers 
(
     [AnchorEmployerId]                 INT
    ,[AcquisitionID]                    BIGINT
    ,[AcquisitionDate]                  DATE
    ,[SutaCutoffYear]                   SMALLINT
    ,[AcquisitionCreated]               DATETIME2(2)
    ,[TransferType]                     VARCHAR(100) COLLATE DATABASE_DEFAULT
    ,[IsPartial]                        BIT

    ,[SuccessorEmployerID]              INT
    ,[PredecessorEmployerID]            INT
    ,[NavLevel]                         INT
    ,[NavPath]                          VARCHAR(MAX) COLLATE DATABASE_DEFAULT

    -- Processing Parameters
    ,[FirstYearFy]                               SMALLINT
    ,[FiscalYear]                                SMALLINT
    ,[FebMailingDate]                            DATE
    ,[FebMailingDateCutoff]                      DATE
    ,[FebMailingDatePrior]                       DATE
    ,[FebMailingDateCutoffPrior]                 DATE

    ,[RcptEffCutoffDate]                         DATE
    ,[RcptCreatedCutoffUtc]                      DATETIME2(2)
    ,[MaxPriorYearBenChgCreatedCutoffUtcFY]      DATETIME2(2)
    ,[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] DATETIME2(2)
    ,[TaxQtrCreatedCutoffUtc]                    DATETIME2(2)
)

-- PredecessorEmployerID is the employer that is being acquired by the SuccessorEmployerID
INSERT INTO #ttAcqEmployers
SELECT DISTINCT 
     ttAcquistions.[AnchorEmployerId]
    ,ttAcquistions.[AcquisitionID]
    ,ttAcquistions.[AcquisitionDate]
    ,ttAcquistions.[SutaCutoffYear]
    ,ttAcquistions.[AcquisitionCreated]
    ,ttAcquistions.[TransferType]
    ,ttAcquistions.[IsPartial]

    ,ttAcquistions.[SuccessorEmployerID] 
    ,ttAcquistions.[PredecessorEmployerID]
    ,ttAcquistions.[NavLevel]
    ,ttAcquistions.[NavPath]

    ,NULL AS [FirstYearFy]
    ,NULL AS [FiscalYear]
    ,NULL AS [FebMailingDate]
    ,NULL AS [FebMailingDateCutoff]
    ,NULL AS [FebMailingDatePrior]
    ,NULL AS [FebMailingDateCutoffPrior]

    ,NULL AS [RcptEffCutoffDate]
    ,NULL AS [RcptCreatedCutoffUtc]
    ,NULL AS [MaxPriorYearBenChgCreatedCutoffUtcFY]
    ,NULL AS [MaxPriorYearBenChgCreatedCutoffUtcFYPrior]
    ,NULL AS [TaxQtrCreatedCutoffUtc]

  FROM #ttAcquistions AS ttAcquistions
  WHERE 1=1
OPTION (RECOMPILE)

-- [Account].[Employer] -- The Aanchor employer data 
INSERT INTO #ttAcqEmployers
SELECT 
     ttEmp.[EmployerID] -- [AnchorEmployerId]
    ,NULL -- ttAcqPredecessors.[AcquisitionID]
    ,NULL -- ttAcqPredecessors.[AcquisitionDate]
    ,NULL -- ttAcqPredecessors.[SutaCutoffYear]
    ,NULL -- ttAcqPredecessors.[AcquisitionCreated]
    ,NULL -- ttAcqPredecessors.[TransferType]
    ,0 -- [IsPartial]

    ,NULL -- ttAcqPredecessors.[SuccessorEmployerID] 
    ,ttEmp.[EmployerID]    -- [PredecessorEmployerID]

    ,NULL -- [NavLevel]
    ,NULL -- [NavPath]

    ,NULL AS [FirstYearFy]
    ,NULL AS [FiscalYear]
    ,NULL AS [FebMailingDate]
    ,NULL AS [FebMailingDateCutoff]
    ,NULL AS [FebMailingDatePrior]
    ,NULL AS [FebMailingDateCutoffPrior]

    ,NULL AS [RcptEffCutoffDate]
    ,NULL AS [RcptCreatedCutoffUtc]
    ,NULL AS [MaxPriorYearBenChgCreatedCutoffUtcFY]
    ,NULL AS [MaxPriorYearBenChgCreatedCutoffUtcFYPrior]
    ,NULL AS [TaxQtrCreatedCutoffUtc]

  FROM [Account].[Employer]                       AS ttEmp       
    INNER JOIN [Configuration].[LiabilityStatus]  AS ttLiaStat   ON ttLiaStat.[LiabilityStatusID] = ttEmp.[CurrentLiabilityStatusID]
    ----INNER JOIN [Configuration].[FinancingMethod]  AS ttFinMeth   ON ttFinMeth.[FinancingMethodID] = ttEmp.[CurrentFinancingMethodID]
WHERE 1=1
    AND (ttEmp.[EmployerID] = @AnchorEmployerID)
OPTION (RECOMPILE)

-- Employer Status Determination -- The current status of the employer
CREATE TABLE #EmpolyerSD
(
     EmployerID               INT
    ,StatusDeterminationID    BIGINT
    ,LiaStatus                VARCHAR(100) COLLATE DATABASE_DEFAULT
    ,FinMeth                  VARCHAR(100) COLLATE DATABASE_DEFAULT
    ,EffDt                    DATE
    ,EffEndDt                 DATE
    ,ReActivation581Liability DATE
    ,CovEffDate               DATE
    ,StatDetCreatedUtc        DATETIME2(2)
    ,StatDetRank              BIGINT
    ,StatDetOrder             BIGINT
)

;WITH CTE_SuccSD AS (
    SELECT 
         [EmployerID]
        ,[StatusDeterminationID]
        ,[LiaStatus]
        ,[FinMeth]
        ,[EffDt]
        ,[EffEndDt]
        ,[ReActivation581Liability]
        ,[CovEffDate]
        ,[StatDetCreatedUtc]
        ,[StatDetRank]
        ,[StatDetOrder]
    FROM (
        SELECT 
             ttSDRank.[StatusDeterminationID]
            ,ttSDRank.[EmployerID]
            ,ttSDRank.[LiaStatus]
            ,ttSDRank.[FinMeth]
            ,ttSDRank.[EffDt] AS [EffDt]
            ,CAST(MAX(ttSDRank.[EffEndDt])                 AS DATE)         AS [EffEndDt]
            ,CAST(MIN(ttSDRank.[ReActivation581Liability]) AS DATE)         AS [ReActivation581Liability]
            ,CAST(MIN(ttSDRank.[CovEffDate])               AS DATE)         AS [CovEffDate]
            ,CAST(MIN(ttSDRank.[StatDetCreatedUtc])        AS DATETIME2(2)) AS [StatDetCreatedUtc]
            -- Tie-break on CreatedDate, then StatusDeterminationID, to match the "current status" lookups (EffectiveDate, CreatedDate, StatusDeterminationID)
            ,ROW_NUMBER() OVER (PARTITION BY ttSDRank.[EmployerID] ORDER BY MIN(ttSDRank.[EffDt]) DESC, MIN(ttSDRank.[StatDetCreatedUtc]) DESC, ttSDRank.[StatusDeterminationID] DESC) AS [StatDetRank]
            ,ROW_NUMBER() OVER (PARTITION BY ttSDRank.[EmployerID] ORDER BY MIN(ttSDRank.[EffDt]) ASC,  MIN(ttSDRank.[StatDetCreatedUtc]) ASC,  ttSDRank.[StatusDeterminationID] ASC)  AS [StatDetOrder]
        FROM (
            SELECT 
                ttSDOrder.[StatusDeterminationID],
                ttSDOrder.[EmployerID]    AS [EmployerID],
                ttSDOrder.[EffectiveDate] AS [EffDt],
                ttSDOrder.[CoverageEffectiveDate],
                ttSDOrder.[CreatedDate],
                ttSDOrder.[LiaStatus]     AS [LiaStatus],
                ttSDOrder.[FinMeth]       AS [FinMeth],
                CAST(CASE 
                    WHEN DateAdd(DAY, -1, LEAD(ttSDOrder.[EffectiveDate], 1, '9999-12-31') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])) < ttSDOrder.[EffectiveDate]
                    THEN ttSDOrder.[EffectiveDate] 
                    ELSE DateAdd(DAY, -1, LEAD(ttSDOrder.[EffectiveDate], 1, '9999-12-31') OVER (PARTITION BY ttSDOrder.[EmployerID] ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]))
                END AS DATE) AS [EffEndDt],
                CAST(CASE 
                    WHEN ttSDOrder.[CoverageEffectiveDate] IS NULL AND ttSDOrder.[LiaStatus]     IN ('ACTIVE', 'REACTIVATED') 
                     AND LAG(ttSDOrder.[LiaStatus], 1, '') 
                         OVER (PARTITION BY ttSDOrder.[EmployerID] 
                         ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]) NOT IN ('ACTIVE', 'REACTIVATED') 
                    THEN ttSDOrder.[EffectiveDate] 
                    WHEN ttSDOrder.[CoverageEffectiveDate] IS NOT NULL AND ttSDOrder.[LiaStatus] IN ('ACTIVE', 'REACTIVATED') 
                     AND LAG(ttSDOrder.[LiaStatus], 1, '') 
                         OVER (PARTITION BY ttSDOrder.[EmployerID] 
                         ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID]) NOT IN ('ACTIVE', 'REACTIVATED')
                    THEN ttSDOrder.[CoverageEffectiveDate] 
                    WHEN ttSDOrder.[CoverageEffectiveDate] IS NULL AND ttSDOrder.[LiaStatus]     IN ('ACTIVE', 'REACTIVATED') 
                     AND LAG(ttSDOrder.[LiaStatus], 1, '') 
                         OVER (PARTITION BY ttSDOrder.[EmployerID] 
                         ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])  IN ('ACTIVE', 'REACTIVATED')
                    THEN LAG(ttSDOrder.[CoverageEffectiveDate], 1) 
                         OVER (PARTITION BY ttSDOrder.[EmployerID]  
                         ORDER BY ttSDOrder.[EffectiveDate], ttSDOrder.[CreatedDate], ttSDOrder.[StatusDeterminationID])
                END AS DATE) AS [ReActivation581Liability],
                ttSDOrder.[CoverageEffectiveDate] AS [CovEffDate],
                ttSDOrder.[CreatedDate]           AS [StatDetCreatedUtc]
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
                    SELECT distinct
                        ttSD0.[EmployerID], 
                        MIN(ttSD0.[CoverageEffectiveDate]) AS [CovEffDt1st], 
                        MIN(ttSD0.[EffectiveDate])         AS [EffDt1st]
                    FROM [Account].[StatusDetermination] AS ttSD0
                    JOIN #ttAcqEmployers                   AS ttAcqEmployers 
                      ON ttAcqEmployers.[PredecessorEmployerID] = ttSD0.[EmployerID] 
                      OR ttAcqEmployers.[SuccessorEmployerID]   = ttSD0.[EmployerID]
                      OR ttAcqEmployers.[AnchorEmployerId]      = ttSD0.[EmployerID]

                    WHERE 1=1
                      AND ttSD0.[IsEnabled] = 1
                      AND ttSD0.[CreatedDate] < @MaxCreatedStatDet
                    GROUP BY ttSD0.[EmployerID]
                ) AS ttFirstDates
                JOIN [Account].[StatusDetermination]   AS ttSD1     ON ttSD1.[EmployerID]            = ttFirstDates.[EmployerID] 
                 AND ttSD1.[IsEnabled] = 1
                 AND ttSD1.[CreatedDate] < @MaxCreatedStatDet
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
) -- CTE_SuccSD
INSERT INTO #EmpolyerSD 
SELECT * FROM CTE_SuccSD
OPTION (RECOMPILE);

-- Rank the Acquistions.... 
INSERT INTO #ttAcquistions
SELECT 
    ttAcqRecType_1.*
FROM (
SELECT 
    --ttAcqProcess.*,
    --ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS RowID,
    1 AS [RecType],
    --ttAcqProcess.[BaseType],
    ttAcqProcess.[AnchorEmployerId],
    ttAcqProcess.[AcquisitionID],
    ttAcqProcess.[SuccessorEmployerID], 
    ttAcqProcess.[PredecessorEmployerID], 
    ttAcqProcess.[AcquisitionDate],
    ttAcqProcess.[AcquisitionCreated],
    ttAcqProcess.[SutaCutoffYear],
    ttAcqProcess.[ExperienceTransferID],
    ttAcqProcess.[FormApplicationId],

    -- Foreign Tables
    ttAcqProcess.[TransferType],
    ttAcqProcess.[IsPartial],

    -- Stat Det - Liability Status - CURRENT
    ttAcqProcess.[SuccCurLiaStat],
    ttAcqProcess.[PredCurLiaStat],

    ttAcqProcess.[ProcStatEffDt],
    ttAcqProcess.[ProcessCode],
    ttAcqProcess.[ProcessStatusCode],
    ttAcqProcess.[ProcStatID],
    ttAcqProcess.[ProcStatCreated],

    ROW_NUMBER() OVER (
        PARTITION BY 
            ttAcqProcess.[SuccessorEmployerID], 
            ttAcqProcess.[PredecessorEmployerID],
            ttAcqProcess.[AcquisitionID]
         ORDER BY 
            ttAcqProcess.[AcquisitionCreated]   ASC,
            ttAcqProcess.[AcquisitionID]        ASC,
            CASE WHEN ttAcqProcess.[ProcStatCreated] IS NULL THEN 1 ELSE 0 END ASC,
            ttAcqProcess.[ProcStatCreated]      ASC,
            ttAcqProcess.[ProcStatID]           ASC
    ) AS [ProcStatOrder],

    ROW_NUMBER() OVER (
        PARTITION BY 
            ttAcqProcess.[SuccessorEmployerID], 
            ttAcqProcess.[PredecessorEmployerID],
            ttAcqProcess.[AcquisitionID]
        ORDER BY 
            ttAcqProcess.[AcquisitionCreated]   DESC,
            ttAcqProcess.[AcquisitionID]        DESC,
            CASE WHEN ttAcqProcess.[ProcStatCreated] IS NULL THEN 1 ELSE 0 END ASC,
            ttAcqProcess.[ProcStatCreated]      DESC,
            ttAcqProcess.[ProcStatID]           DESC
    ) AS [ProcStatRank],

    ttSuccSD.[EffDt]      AS [SuccLiaEffDate],
    ttSuccSD.[LiaStatus]  AS [SuccLiaStatus],

    CASE WHEN ttSuccSD.[CovEffDate] IS NOT NULL THEN ttSuccSD.[CovEffDate]
         ELSE (SELECT TOP 1 XX.[CovEffDate] FROM #EmpolyerSD AS XX WHERE XX.[EmployerID] = ttSuccSD.[EmployerID] AND XX.[StatDetRank] > ttSuccSD.[StatDetRank] ORDER BY XX.[StatDetRank])   
         END AS [SuccLiabilityDate],
    (SELECT MIN(XX.[CovEffDate]) FROM #EmpolyerSD AS XX WHERE XX.[EmployerID] = ttSuccSD.[EmployerID] AND XX.[CovEffDate] IS NOT NULL) [SuccFirstLiabilityDate],

    ttPredSD.[EffDt]      AS [PredLiaEffDate],
    ttPredSD.[LiaStatus]  AS [PredLiaStatus],
    CASE WHEN ttPredSD.[CovEffDate] IS NOT NULL THEN ttPredSD.[CovEffDate]
         ELSE (SELECT TOP 1 XX.[CovEffDate] FROM #EmpolyerSD AS XX WHERE XX.[EmployerID] = ttPredSD.[EmployerID] AND XX.[StatDetRank] > ttPredSD.[StatDetRank] ORDER BY XX.[StatDetRank])   
         END AS [PredLiabilityDate],
    (SELECT MIN(XX.[CovEffDate]) FROM #EmpolyerSD AS XX WHERE XX.[EmployerID] = ttPredSD.[EmployerID] AND XX.[CovEffDate] IS NOT NULL) [PredFirstLiabilityDate],

    ttAcqProcess.[NavLevel],
    ttAcqProcess.[NavPath],
    ttAcqProcess.[CurrentStatusExclude]

FROM (
SELECT 
    ttAcq.[RecType],
    --ttAcq.[BaseType],
    ttAcq.[AnchorEmployerId],
    ttAcq.[AcquisitionID],
    ttAcq.[SuccessorEmployerID], 
    ttAcq.[PredecessorEmployerID], 
    ttAcq.[AcquisitionDate],
    ttAcq.[AcquisitionCreated],
    ttAcq.[SutaCutoffYear],
    ttAcq.[ExperienceTransferID],
    ttAcq.[FormApplicationId],

    -- Foreign Tables
    ttAcq.[TransferType],
    ttAcq.[IsPartial],

    -- Stat Det - Liability Status - CURRENT
    ttAcq.[SuccCurLiaStat],
    ttAcq.[PredCurLiaStat],

    ttProcStat.[EffectiveDate]   AS [ProcStatEffDt],
    ttProcDefn.[ProcessCode]     AS [ProcessCode] ,
    ttStat.[Code]                AS [ProcessStatusCode],
    ttProcStat.[ProcessStatusID] AS [ProcStatID],
    ttProcStat.[CreatedDate]     AS [ProcStatCreated],

    ttAcq.[NavLevel],
    ttAcq.[NavPath],
    ttAcq.[CurrentStatusExclude]
    
FROM #ttAcquistions AS ttAcq
  LEFT  JOIN [Account].[ProcessStatus]            AS ttProcStat ON ttProcStat.[ProcessId]            = ttAcq.[AcquisitionID]
         AND ttProcStat.[CreatedDate] < @MaxAcqProcUtc -- @CreatedDateCutoffUtc
  LEFT  JOIN [Configuration].[ProcessDefinition]  AS ttProcDefn ON ttProcDefn.[ProcessDefinitionId]  = ttProcStat.[ProcessDefinitionId]
  LEFT  JOIN [Configuration].[Status]             AS ttStat     ON ttStat.[StatusId]                 = ttProcStat.[StatusId]

  -- select * from [Configuration].[Status] 

WHERE 1=1
  AND ttAcq.[RecType] = 0
) ttAcqProcess
  LEFT JOIN #EmpolyerSD AS ttSuccSD ON ttSuccSD.[EmployerID] = ttAcqProcess.[SuccessorEmployerID]   AND ttSuccSD.[StatDetRank] = 1
  LEFT JOIN #EmpolyerSD AS ttPredSD ON ttPredSD.[EmployerID] = ttAcqProcess.[PredecessorEmployerID] AND ttPredSD.[StatDetRank] = 1
) AS ttAcqRecType_1
WHERE 1=1
order by
        ttAcqRecType_1.[SuccessorEmployerID], 
        ttAcqRecType_1.[PredecessorEmployerID]

OPTION (RECOMPILE);

-- Process Statuses 
-- -- PENDING PENDINGUI PENDINGER 
-- -- APPROVED 
-- -- CANCELLED
-- -- DENIED DENIEDUI DENIEDER

-- Keep the most recent APPROVED Process Status 
DELETE FROM #ttAcquistions 
WHERE [RecType] = 0 OR ([RecType] = 1 AND [ProcStatRank] != 1) --OR [ProcessStatusCode] NOT IN  ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER')
OPTION (RECOMPILE);

-- Hold Onto Not Pending or Approved 
INSERT INTO #ttAcquistionsNotPendApp
SELECT * FROM #ttAcquistions
WHERE [ProcessStatusCode] NOT IN  ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER')
OPTION (RECOMPILE);

-- Keep the most recent APPROVED Process Status 
DELETE FROM #ttAcquistions 
WHERE [ProcessStatusCode] NOT IN  ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER')
OPTION (RECOMPILE);


-- Re-Rank the Acquistions.... 
INSERT INTO #ttAcquistions
SELECT 
    0 AS [RecType],
    --[BaseType],

    [AnchorEmployerId],
    [AcquisitionID],
    [SuccessorEmployerID], 
    [PredecessorEmployerID], 
    [AcquisitionDate],
    [AcquisitionCreated],
    [SutaCutoffYear],
    [ExperienceTransferID],
    [FormApplicationId],

    -- Foreign Tables
    [TransferType],
    [IsPartial],

    -- Stat Det - Liability Status - CURRENT
    [SuccCurLiaStat],
    [PredCurLiaStat],

    -- Processing Status 

    [ProcStatEffDt],
    [ProcessCode],
    [ProcessStatusCode],
    [ProcStatID],
    [ProcStatCreated],

    CASE WHEN [IsPartial] = 1 THEN NULL ELSE 
    ROW_NUMBER() OVER (
        PARTITION BY 
            [SuccessorEmployerID], 
            [PredecessorEmployerID]
            --[AcquisitionID]
         ORDER BY 
            [AcquisitionCreated]   ASC,
            [AcquisitionID]        ASC,
            CASE WHEN [ProcStatCreated] IS NULL THEN 1 ELSE 0 END ASC,
            [ProcStatCreated]      ASC,
            [ProcStatID]           ASC
    ) END AS [ProcStatOrder],

    CASE WHEN [IsPartial] = 1 THEN NULL ELSE 
    ROW_NUMBER() OVER (
        PARTITION BY 
            [SuccessorEmployerID], 
            [PredecessorEmployerID]
            --[AcquisitionID]
        ORDER BY 
            [AcquisitionCreated]   DESC,
            [AcquisitionID]        DESC,
            CASE WHEN [ProcStatCreated] IS NULL THEN 1 ELSE 0 END ASC,
            [ProcStatCreated]      DESC,
            [ProcStatID]           DESC
    ) END AS [ProcStatRank],

    [SuccLiaEffDate],
    [SuccLiaStatus],
    [SuccLiabilityDate],
    [SuccFirstLiabilityDate],

    [PredLiaEffDate],
    [PredLiaStatus],
    [PredLiabilityDate],
    [PredFirstLiabilityDate],

    [NavLevel],
    [NavPath],

    [CurrentStatusExclude]   
FROM #ttAcquistions
OPTION (RECOMPILE);

-- Set the SUTA Cutoff Date on temp table #ttAcquistions

UPDATE TT SET
     [SutaCutoffYear] = CAST(YEAR(TT.[AcquisitionDate]) AS SMALLINT) + 3
FROM #ttAcquistions      AS TT 
WHERE 1=1
  AND TT.[TransferType] = @TransferTypeSUTAFULL
  AND TT.[SutaCutoffYear] != CAST(YEAR(TT.[AcquisitionDate]) AS SMALLINT) + 3


DELETE TT
FROM #ttAcqEmployers TT
WHERE 1=1
  AND [AcquisitionID] IS NOT NULL
  AND NOT EXISTS ( SELECT 1 FROM #ttAcquistions XX WHERE XX.[AcquisitionID] = TT.[AcquisitionID])
OPTION (RECOMPILE);


UPDATE TT SET 
    TT.[FirstYearFy]  = CASE WHEN TT.[IsPartial] = 1 THEN YEAR(TT.[AcquisitionDate]) + 1 ELSE @FiscalYear END,
    TT.[FiscalYear]   = @FiscalYear
FROM #ttAcqEmployers TT;

-- [FebMailingDate] and [FebMailingDatePrior] --- USED FOR PAYROLL WAGES
-- [RcptCreatedCutoffUtc], [MaxPriorYearBenChgCreatedCutoffUtcFY], [MaxPriorYearBenChgCreatedCutoffUtcFYPrior]
UPDATE TT SET 
    TT.[FebMailingDate]            = @FebMailingDate,
    TT.[FebMailingDatePrior]       = @FebMailingDatePrior,
    TT.[FebMailingDateCutoff]      = @FebMailingDateCutoff,
    TT.[FebMailingDateCutoffPrior] = @FebMailingDateCutoffPrior,
    TT.[RcptEffCutoffDate] = 
        CAST(CAST(DATEFROMPARTS(@FiscalYear, 01, 31)      AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
    ,TT.[RcptCreatedCutoffUtc]                 = 
        CAST(CAST(@FebMailingDateCutoff                   AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
    ,TT.[MaxPriorYearBenChgCreatedCutoffUtcFY] = 
        CAST(CAST(DATEFROMPARTS(TT.[FirstYearFy], 01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
    ,TT.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] = 
        CAST(CAST(DATEFROMPARTS(TT.[FirstYearFy] - 1, 01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
    ,TT.[TaxQtrCreatedCutoffUtc] = 
        CAST(CAST(@FebMailingDateCutoff                       AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
FROM #ttAcqEmployers TT;

-- #0 OUTPUT DATA RESULT SET (KEEP IN ORDER):  @ttAcquistions -- Done at beginning ============================================================
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

    -- EMPLOYER PORTAL DATA -- CAN'T CROSS DB - EMPLOYER PORTAL DATA NOT ACCESSIBLE
    --,ttTaxRateExpAcquisition.[AppFormType]              AS [AppFormType]
    --,ttTaxRateExpAcquisition.[FormReviewAction]         AS [FormReviewAction]
    --,ttTaxRateExpAcquisition.[ResponseDate]             AS [ResponseDate]
    --,ttTaxRateExpAcquisition.[IsSystemDecision]         AS [IsSystemDecision]
    --,ttTaxRateExpAcquisition.[DayCntAcqDtToResponse]    AS [DayCntAcqDtToResponse]

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
-- #0 OUTPUT DATA RESULT SET (KEEP IN ORDER):  @ttAcquistions -- Done at beginning ============================================================

-- Keep the most recent ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER') Process Status 
INSERT INTO #ttAcquistionsNotPendApp
SELECT * FROM #ttAcquistions
WHERE [ProcessStatusCode] NOT IN  ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER')
OPTION (RECOMPILE);


-- Keep the most recent ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER') Process Status 
DELETE FROM #ttAcquistions 
WHERE [ProcessStatusCode] NOT IN  ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER')
OPTION (RECOMPILE);


-- [Account].[TaxRateExpTaxesPaid] -- All Wages for  { Successor, FULL Predecessor }, Aquistion Year Wages for {Partial Predecessor} 
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
-- PAYMENTS
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
    AND ttAllocRcv.[Amount] >= 0.00
    AND ttRcvTyp.[Code] IN ('TAXCOMPUTED', 'TAXSHAREDCOST', 'TAXOTHERSTATE')

    AND ttRcptAlloc.[CreatedDate] <  ttAcqEmployers.[RcptCreatedCutoffUtc]

) AS TTDATA
WHERE 1=1
  AND TTDATA.[EffectiveDate] <= TTDATA.[RcptEffCutoffDate]
  AND TTDATA.[RcptRqstRank]  = 1 
  AND TTDATA.[RcptAllocRank] = 1
  AND ((TTDATA.[IsPartial]   = 1 AND TTDATA.[Year] < Year(TTDATA.[AcquisitionDate])) OR TTDATA.[Year] < TTDATA.[FiscalYear])

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

-- [Account].[TaxRateExpBenChg] -- All Charges for  { Successor, FULL Predecessor }, Aquistion Year Charges for {Partial Predecessor} 
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

    ,CASE WHEN ttChgStmntChg.[CreatedDate] <  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] --AND ttAcqEmployers.[IsPartial] = 0
          THEN  ISNULL(ttChgStmntChg.[BenefitsCharged],  0.00) ELSE 0.00 END AS [BenefitsChargedClientPrior]

    ,CASE WHEN ttChgStmntChg.[CreatedDate] <  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] --AND ttAcqEmployers.[IsPartial] = 0
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
  --AND ((ttAcqEmployers.[IsPartial] = 1 AND Year(ttChgStmntChg.[CreatedDate]) = Year(ttAcqEmployers.[AcquisitionDate])) OR 
  --      ttChgStmntChg.[CreatedDate] <  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFY])
  AND (ttChgStmntChg.[CreatedDate] <  ttAcqEmployers.[MaxPriorYearBenChgCreatedCutoffUtcFY])


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



/*

The checking for late reports in building [Account].[TaxRateExpReserveCalc] it only checks on quarters on the base period.
- need to look at all quarters back to the liability date. 

QUICK FIX - Look at all Quarters back to Liability Date And if employer was active in any of those quarters
            the quarter needs to have filed an Tax Quarter Report - QWR / QWRA

*/


DECLARE @FirstDayOfYear DATE = DATEADD(DAY,-1, DATEFROMPARTS(@FiscalYear, 1, 1));

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

INSERT INTO #EmplStatDet
SELECT f.* 
FROM [Account].[fn_StatusDeterminationFlattened_ForEmployer](@AnchorEmployerID) AS f
WHERE f.[EffDt] <= @FirstDayOfYear AND f.[EffEndDt] >= @FirstDayOfYear AND f.[EffDtRank] = 1

DECLARE @LiabilityDateLate DATE = 
        (SELECT TOP 1 f.LiabilityDate
            FROM #EmplStatDet AS f
            WHERE f.[EffDt] <= @FirstDayOfYear AND f.[EffEndDt] >= @FirstDayOfYear AND f.[EffDtRank] = 1)

;WITH CTE_TaxQuarters AS (
SELECT 
    --TQ.*
     TQ.EmployerID
    ,TQ.TaxQuarterID
    ,TQ.TaxRateTimely
    ,TQ.Year
    ,TQ.Quarter
    ,QuarterStartDate
    ,QuarterEndDate

    ,ROW_NUMBER() OVER (PARTITION BY TQ.[TaxQuarterID] ORDER BY ttTQRept.[EffectiveDate] DESC, ttTQRept.[CreatedDate] DESC, ttTQRept.[TaxQuarterReportId] DESC) AS [TqRptRowRank]
    ,ttTQRept.[EffectiveDate]
    ,ttTQRept.[CreatedDate]
    ,ttTQRept.[TaxQuarterReportId]

    ,ttTQRept.[ReceivedDate]
    ,ttTQRept.[ReportTypeId]
    ,ttTQRept.IsEnabled
FROM (
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
    LEFT JOIN [Account].[TaxQuarterReports] AS ttTQRept   ON ttTQRept.[TaxQuarterID]   = TQ.[TaxQuarterID] 
    LEFT JOIN [Configuration].[ReportType]  AS ttReptType ON ttReptType.[ReportTypeId] = ttTQRept.[ReportTypeId]
WHERE 1=1
  AND (ttTQRept.TaxQuarterReportID IS NULL)
   OR (ttTQRept.IsEnabled = 1 
       AND ttTQRept.[ReceivedDate]  IS NOT NULL
       AND (ttTQRept.[ReceivedDate] <= @FebMailingDateCutoff OR TQ.[TaxRateTimely] = 1))
)
,CTE_StatusFlattened AS (
    SELECT *
    --FROM [Account].[fn_StatusDeterminationFlattened_ForEmployer](@AnchorEmployerID)
    FROM #EmplStatDet
    WHERE [EffDtRank] = 1
      AND [LiaStatus] IN ('ACTIVE', 'REACTIVATED')
      --AND [EffDt] <= @FirstDayOfYear AND [EffEndDt] >= @FirstDayOfYear
)
-- Step 1: clamp each overlapping status row's range to the quarter's range.
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
  AND CTE_TaxQuarters.TqRptRowRank  = 1
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

    ,ISNULL(SUM(DATEDIFF(DAY, CTE_ClampedOverlap.[ClampedStart], CTE_ClampedOverlap.[ClampedEnd]) + 1), 0) AS [ActiveDaysInRange]

    ,CTE_ClampedOverlap.[ClampedStart]
    ,CTE_ClampedOverlap.[ClampedEnd]

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
    ,CTE_ClampedOverlap.[ClampedStart]
    ,CTE_ClampedOverlap.[ClampedEnd]

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
 
    ,ttTQRept.[ReceivedDate]        AS [RptRcvd]     -- DATETIME
    ,ttTQ.[ReportDueDate]           AS [RptDue]      -- DATETIME

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
    INNER JOIN [Account].[TaxQuarterReports]      AS ttTQRept       ON ttTQRept.[TaxQuarterID]  = ttTQ.[TaxQuarterID]

    INNER JOIN [Configuration].[ReportType]       AS ttRptType      ON ttRptType.[ReportTypeId] = ttTQRept.[ReportTypeId]

    INNER JOIN [Account].[Employer]               AS ttEmp          ON ttEmp.[EmployerID]                     = ttTQ.[EmployerID]
    INNER JOIN [Configuration].[LiabilityStatus]  AS ttLiaStat      ON ttLiaStat.[LiabilityStatusID]          = ttEmp.[CurrentLiabilityStatusID]
    INNER JOIN [Configuration].[FinancingMethod]                    ON [FinancingMethod].[FinancingMethodID]  = ttEmp.[CurrentFinancingMethodID]

 WHERE 1=1 
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


-- We only want to do this for the ANCHOR Employer

DECLARE @RcptCreatedCutoffUtc                  DATETIME2(2) = CAST(CAST(@FebMailingDateCutoff              AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
DECLARE @MaxPriorYearBenChgCreatedCutoffUtcFY  DATETIME2(2) = CAST(CAST(DATEFROMPARTS(@FiscalYear, 01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))

DECLARE @TaxQtrCreatedCutoffUtc        DATETIME2(2) = CAST(CAST(@FebMailingDateCutoff AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
DECLARE @StatDetCreatedCutoffUtc       DATETIME2(2) = CAST(CAST(@FebMailingDateCutoff AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))


DECLARE @RcptCreatedCutoffUtcPrior     DATETIME2(2)             = CAST(CAST(@FebMailingDateCutoffPrior             AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
DECLARE @MaxPriorYearBenChgCreatedCutoffUtcFYPrior DATETIME2(2) = CAST(CAST(DATEFROMPARTS(@FiscalYear - 1, 01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))

DECLARE @AnyLateMissingReports BIT = 0;

IF EXISTS (SELECT 1 FROM #TaxQuartersQwrQwraLateStatus WHERE IsLate = 1)
BEGIN
    SET @AnyLateMissingReports = 1;
END;

-- building [Account].[TaxRateExpReserveCalc]
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
    [EmployerID],
    MIN(XX.CoverageEffectiveDate) AS [FirstLiabilityDate]
FROM [Account].[StatusDetermination] AS XX
GROUP BY [EmployerID]
),
CTE_StatusDetermination AS (
SELECT 
    ttSdResults.*
FROM (
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
) as ttSdResults
) ---  CTE_StatusDetermination =======================================================================================
MERGE INTO [Account].[TaxRateExpReserveCalc] AS TARGET 
USING (
SELECT -- ttReserveCalc
     @FiscalYear       AS [FiscalYear]
    ,@AnchorEmployerID AS  [AnchorEmployerID]
    ,ttReserveCalc.[EmployerID]  

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
    ,CASE WHEN [ReserveRatio] IS NULL THEN NULL 
            WHEN [ReserveRatio] > @maxReserveRatio THEN CAST(@maxReserveRatio AS DECIMAL(8, 4))
            WHEN [ReserveRatio] < @minReserveRatio THEN CAST(@minReserveRatio AS DECIMAL(8, 4))
            ELSE                                        CAST([ReserveRatio]   AS DECIMAL(8, 4)) 
            END AS [ReserveRatio]

    -- If any quarterly wage report required to be filed from initial liability date has not been filed by the cut-off date,
    -- -- These employers will be assigned the maximum rate.

    ,CASE --WHEN [ReserveRatio] IS NULL   THEN  @RateTypeMaxRate0 -- MAX RATE: [TaxablePayRoll3YearTimelyAvg] <= 0.00 -- 3 year timely wages <= 0.00
            WHEN @AnyLateMissingReports  > 0 THEN  @RateTypeMaxRate1 -- MAX RATE: Has at least one late report
            WHEN [SUM_IsLate]            > 0 THEN  @RateTypeMaxRate1 -- MAX RATE: Has at least one late report
            /* 
            NOT RATEABLE AND WILL HAVE A NEW EMPLOYER OR MAX RATE
            - If the employer has 4 consecutive quarters in any base period from CY preceding rate year in any combination of the following:
                A. - Filed wage reports = zero wages
                B. - Inactive status 
                C. - Not liable (based on liability date)
            */
            WHEN -- B. - Inactive status  C. - Not liable (based on liability date)
                [SUM_NotRateableQtrCntBasePeriod1] = 4 OR 
                [SUM_NotRateableQtrCntBasePeriod2] = 4 OR 
                [SUM_NotRateableQtrCntBasePeriod3] = 4 OR 
                [SUM_NotRateableQtrCntBasePeriod4] = 4
            THEN CASE WHEN ([Reserve] >= 0.00) THEN  @RateTypeNewRate1  ELSE @RateTypeMaxRate2 END -- Base Period Criteria Not Met ===> { NEW RATE: [Reserve] >= 0.00, MAX RATE: [Reserve] < 0.00 }

            WHEN -- A. - Filed wage reports = zero wages
                -- Not Chargeable - To Be Chargeable need to have at least one Non Zero Wage in each Base Period
                ([MAX_NonZeroWageBasePeriod1] + [MAX_NonZeroWageBasePeriod2] + 
                 [MAX_NonZeroWageBasePeriod3] + [MAX_NonZeroWageBasePeriod4] ) <> 4

            THEN CASE WHEN ([Reserve] >= 0.00) THEN  @RateTypeNewRate2  ELSE @RateTypeMaxRate3 END -- Base Period Criteria Not Met ===> { NEW RATE: [Reserve] >= 0.00, MAX RATE: [Reserve] < 0.00 }
            --THEN CASE WHEN ([Reserve] > 0.00) THEN  @RateTypeNewRate2  ELSE @RateTypeMaxRate3 END -- Base Period Criteria Not Met ===> { NEW RATE: [Reserve] >= 0.00, MAX RATE: [Reserve] < 0.00 }

            WHEN [ReserveRatio] IS NULL   THEN  @RateTypeMaxRate0 -- MAX RATE: [TaxablePayRoll3YearTimelyAvg] <= 0.00 -- 3 year timely wages <= 0.00
          
            -- One quarter in each of the 4 Base periods above has a quarterly report filed with wages > 0. 
            WHEN [MAX_NonZeroWageBasePeriod1] = 1 AND [MAX_NonZeroWageBasePeriod2] = 1 AND
                 [MAX_NonZeroWageBasePeriod3] = 1 AND [MAX_NonZeroWageBasePeriod4] = 1 THEN @RateTypeIsRated -- EXPERIENCE RATED: Reserve Ratio Lookup
               
            ELSE @RateTypeUndetermined
            END AS [RateTypeDetermined] 
FROM ( -- ttReserveCalc

SELECT DISTINCT -- ttMoney
     ttMoney.[EmployerID]  

    ,[MAX_NonZeroWageBasePeriod1]
    ,[MAX_NonZeroWageBasePeriod2]
    ,[MAX_NonZeroWageBasePeriod3]
    ,[MAX_NonZeroWageBasePeriod4]

    ,[SUM_NotRateableQtrCntBasePeriod1]
    ,[SUM_NotRateableQtrCntBasePeriod2]
    ,[SUM_NotRateableQtrCntBasePeriod3]
    ,[SUM_NotRateableQtrCntBasePeriod4]

    ,[SUM_IsLate]

    -- -- [PriorReserve]
    ,([TaxesPaidPrior] - [BenefitsTotalClientPrior])

    + ISNULL(
        (SELECT SUM(ISNULL(XX.[Adjustment], 0.00) * CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN 1.00 ELSE -1.00 END)
        FROM [Account].[RunningReserve] AS XX 
        WHERE XX.[EmployerID] = ttMoney.[EmployerID] 
            AND XX.[Component] IN ('PAYMENTADJUST', 'BENEFITADJUST')
            AND XX.[YEAR] <= @FiscalYear - 2
            AND XX.[AdjustmentUtcDate] < 
                CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN @RcptCreatedCutoffUtcPrior ELSE @MaxPriorYearBenChgCreatedCutoffUtcFYPrior END)
        , 0.00) AS [PriorReserve]

    -- -- [Reserve]
    ,([TaxesPaidPrior] - [BenefitsTotalClientPrior]) + ([TaxesPaid] - [BenefitsTotalClient]) 

    + ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00) * CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN 1.00 ELSE -1.00 END)
        FROM [Account].[RunningReserve] AS XX 
        WHERE XX.[EmployerID] = ttMoney.[EmployerID] 
            AND XX.[Component] IN ('PAYMENTADJUST', 'BENEFITADJUST')
            AND XX.[YEAR] = @FiscalYear - 1
            AND XX.[AdjustmentUtcDate] <  CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN @RcptCreatedCutoffUtc      ELSE @MaxPriorYearBenChgCreatedCutoffUtcFY      END), 0.00)
    AS [Reserve]

    ,CASE WHEN [TaxablePayRollTimely3YrAvg] <=  0.00 THEN NULL
          
            WHEN -- -- [Reserve]
                ([TaxesPaidPrior] - [BenefitsTotalClientPrior]) + ([TaxesPaid] - [BenefitsTotalClient]) 
                + ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00) * CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN 1.00 ELSE -1.00 END)
                    FROM [Account].[RunningReserve] AS XX 
                    WHERE XX.[EmployerID] = ttMoney.[EmployerID] 
                        AND XX.[Component] IN ('PAYMENTADJUST', 'BENEFITADJUST')
                        AND XX.[YEAR] <= @FiscalYear - 1
                        AND XX.[AdjustmentUtcDate] <  CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN @RcptCreatedCutoffUtc      ELSE @MaxPriorYearBenChgCreatedCutoffUtcFY      END), 0.00)
            = 0.00 THEN 0.00 

            ELSE ROUND(((([TaxesPaidPrior] - [BenefitsTotalClientPrior]) + ([TaxesPaid] - [BenefitsTotalClient])
                        + ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00) * CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN 1.00 ELSE -1.00 END)
                            FROM [Account].[RunningReserve] AS XX 
                            WHERE XX.[EmployerID] = ttMoney.[EmployerID] 
                                AND XX.[Component] IN ('PAYMENTADJUST', 'BENEFITADJUST')
                                AND XX.[YEAR] <= @FiscalYear - 1
                                AND XX.[AdjustmentUtcDate] <  CASE WHEN XX.[Component] = 'PAYMENTADJUST' THEN @RcptCreatedCutoffUtc      ELSE @MaxPriorYearBenChgCreatedCutoffUtcFY      END), 0.00)
    ) / [TaxablePayRollTimely3YrAvg]), 4)

    END AS [ReserveRatio]

    -- ttTaxesPaid
    ,[TaxesPaid]
    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttMoney.[EmployerID] 
            AND XX.[Component] IN ('PAYMENTADJUST')
            AND XX.[YEAR] = @FiscalYear - 1
            AND XX.[AdjustmentUtcDate] <  @RcptCreatedCutoffUtc      -- 2025 2025-03-01 10:00:00.00
        ), 0.00) AS [TaxesPaidAdjust]

    ,[TaxesPaidPrior]
    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttMoney.[EmployerID] 
            AND XX.[Component] IN ('PAYMENTADJUST')
            AND XX.[YEAR] <= @FiscalYear - 2
            AND XX.[AdjustmentUtcDate] < @RcptCreatedCutoffUtcPrior
        ), 0.00) AS [TaxesPaidPriorAdjust]

        -- ttBenChg
    ,[BenefitsChargedClient]
    ,[BenefitsRelievedClient]
    ,[BenefitsTotalClient]
    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttMoney.[EmployerID] 
            AND XX.[Component] IN ('BENEFITADJUST')
            AND XX.[YEAR] = @FiscalYear - 1
            AND XX.[AdjustmentUtcDate] >= @MaxPriorYearBenChgCreatedCutoffUtcFYPrior
            AND XX.[AdjustmentUtcDate] <  @MaxPriorYearBenChgCreatedCutoffUtcFY
        ), 0.00) AS [BenefitsTotalClientAdjust]

    ,[BenefitsChargedClientPrior]
    ,[BenefitsRelievedClientPrior]
    ,[BenefitsTotalClientPrior]
    ,ISNULL((SELECT SUM(ISNULL(XX.[Adjustment], 0.00))
        FROM [Account].[RunningReserve] AS XX 
        WHERE 1=1
            AND XX.[EmployerID] = ttMoney.[EmployerID] 
            AND XX.[Component] IN ('BENEFITADJUST')
            AND XX.[YEAR] <= @FiscalYear - 2
            AND XX.[AdjustmentUtcDate] < @MaxPriorYearBenChgCreatedCutoffUtcFYPrior
        ), 0.00) AS [BenefitsTotalClientPriorAdjust]

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

FROM 
( -- ttMoney

SELECT ttSumBenChg.*
    -- ttPayRoll
    ,CAST(SUM(ISNULL(ttPayRoll.[TaxablePayRoll],       0.00))        AS MONEY) AS [TaxablePayRoll]
    ,CAST(SUM(ISNULL(ttPayRoll.[TaxablePayRollTimely], 0.00))        AS MONEY) AS [TaxablePayRollTimely]
    ,CAST(SUM(ISNULL(ttPayRoll.[TaxablePayRoll],       0.00) / 3.00) AS MONEY) AS [TaxablePayRoll3YrAvg]
    ,CAST(SUM(ISNULL(ttPayRoll.[TaxablePayRollTimely], 0.00) / 3.00) AS MONEY) AS [TaxablePayRollTimely3YrAvg]

    ,@FiscalYear - 3 as [Year1]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 3 THEN ISNULL(ttPayRoll.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollTimelyYear1]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 3 THEN ISNULL(ttPayRoll.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollYear1]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 3 THEN ISNULL(ttPayRoll.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollTimelyYear1]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 3 THEN ISNULL(ttPayRoll.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollYear1]

    ,@FiscalYear - 2 as [Year2]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 2 THEN ISNULL(ttPayRoll.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollTimelyYear2]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 2 THEN ISNULL(ttPayRoll.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollYear2]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 2 THEN ISNULL(ttPayRoll.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollTimelyYear2]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 2 THEN ISNULL(ttPayRoll.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollYear2]

    ,@FiscalYear - 1 as [Year3]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 1 THEN ISNULL(ttPayRoll.[TaxablePayRollTimely], 0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollTimelyYear3]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 1 THEN ISNULL(ttPayRoll.[TaxablePayRoll],       0.00) ELSE 0.00 END) AS MONEY) AS [TaxablePayRollYear3]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 1 THEN ISNULL(ttPayRoll.[TotalPayRollTimely],   0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollTimelyYear3]
    ,CAST(SUM(CASE WHEN ttPayRoll.[Year] = @FiscalYear - 1 THEN ISNULL(ttPayRoll.[TotalPayRoll],         0.00) ELSE 0.00 END) AS MONEY) AS [TotalPayRollYear3]
FROM ( -- ttSumBenChg
SELECT ttSumTaxesPaid.*
    -- ttBenChg
    ,CAST(SUM(ISNULL(ttBenChg.[BenefitsChargedClient],       0.00)) AS MONEY)                                                        AS [BenefitsChargedClient]
    ,CAST(SUM(ISNULL(ttBenChg.[BenefitsRelievedClient],      0.00)) AS MONEY)                                                        AS [BenefitsRelievedClient]
    ,CAST(SUM(ISNULL(ttBenChg.[BenefitsChargedClient],       0.00) - ISNULL(ttBenChg.[BenefitsRelievedClient],      0.00)) AS MONEY) AS [BenefitsTotalClient]

    ,CAST(SUM(ISNULL(ttBenChg.[BenefitsChargedClientPrior],  0.00)) AS MONEY)                                                        AS [BenefitsChargedClientPrior]
    ,CAST(SUM(ISNULL(ttBenChg.[BenefitsRelievedClientPrior], 0.00)) AS MONEY)                                                        AS [BenefitsRelievedClientPrior]
    ,CAST(SUM(ISNULL(ttBenChg.[BenefitsChargedClientPrior],  0.00) - ISNULL(ttBenChg.[BenefitsRelievedClientPrior], 0.00)) AS MONEY) AS [BenefitsTotalClientPrior]
FROM ( -- ttSumTaxesPaid
SELECT DISTINCT
        ttDataSum.[EmployerID]

    ,ttDataSum.[MAX_NonZeroWageBasePeriod1]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod2]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod3]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod4]

    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod1]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod2]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod3]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod4]

    ,ttDataSum.[SUM_IsLate]

    -- ttTaxesPaid
    ,CAST(SUM(ISNULL(ttTaxesPaid.[TaxesPaid],      0.00)) AS MONEY) AS [TaxesPaid]
    ,CAST(SUM(ISNULL(ttTaxesPaid.[TaxesPaidPrior], 0.00)) AS MONEY) AS [TaxesPaidPrior]

FROM (  -- ttDataSum

SELECT distinct -- ttData
        ttData.[EmployerID]
    ----,ttData.[BasePeriodDateQtr]

    ----,ttData.[FirstDayTaxQtr]
    ----,ttData.[LastDayTaxQtr]
    ----,ttData.[TaxQtrRcvDate]
    ----,ttData.[TaxRateTimely]

    ----,ttData.[EffDt]
    ----,ttData.[EffEndDt]
    ----,ttData.[UseCovEffDate]
    ----,ttData.[CovEffDate]
    ----,ttData.[UseCovEffDateActive]

    ----,ttData.[TaxableWagesQtrTotal]
    ----,ttData.[TaxableWagesQtrTimely]

    -- Base Period Has WAges
    ,MAX([NonZeroWageBasePeriod1]) AS [MAX_NonZeroWageBasePeriod1]
    ,MAX([NonZeroWageBasePeriod2]) AS [MAX_NonZeroWageBasePeriod2]
    ,MAX([NonZeroWageBasePeriod3]) AS [MAX_NonZeroWageBasePeriod3]
    ,MAX([NonZeroWageBasePeriod4]) AS [MAX_NonZeroWageBasePeriod4]

    ,SUM([NotRateableQtrCntBasePeriod1]) AS [SUM_NotRateableQtrCntBasePeriod1]
    ,SUM([NotRateableQtrCntBasePeriod2]) AS [SUM_NotRateableQtrCntBasePeriod2]
    ,SUM([NotRateableQtrCntBasePeriod3]) AS [SUM_NotRateableQtrCntBasePeriod3]
    ,SUM([NotRateableQtrCntBasePeriod4]) AS [SUM_NotRateableQtrCntBasePeriod4]

    ,SUM([IsLate])   AS [SUM_IsLate]
    --,@AnyLateMissingReports    AS [SUM_IsLate]


FROM ( -- ttData
SELECT DISTINCT 
        ttBpTqStat.[EmployerID]

    --------------------,ttBasePeriod.[BasePeriodDateQtr]

    --------------------,ttBpTqStat.[FirstDayTaxQtr]
    --------------------,ttBpTqStat.[LastDayTaxQtr]
    --------------------,ttBpTqStat.[TaxQtrRcvDate]
    --------------------,ttBpTqStat.[TaxRateTimely]

    --------------------,ttBpTqStat.[EffDt]
    --------------------,ttBpTqStat.[EffEndDt]
    --------------------,ttBpTqStat.[UseCovEffDate]
    --------------------,ttBpTqStat.[CovEffDate]
    --------------------,ttBpTqStat.[UseCovEffDateActive]

    --------------------,ttBpTqStat.[TaxableWagesQtrTotal]
    --------------------,ttBpTqStat.[TaxableWagesQtrTimely]

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
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

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
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

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
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

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
                CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END NOT IN ('ACTIVE', 'REACTIVATED') OR ttBpTqStat.[TotalActiveCnt] <=  0 OR

                -- C. - Not liable (based on liability date)
                -- Not Liable - Liability Date > [LastDayTaxQtr]
                ttBpTqStat.[LiabilityDate] IS NULL OR ttBpTqStat.[LiabilityDate] > ttBpTqStat.[LastDayTaxQtr]

            THEN 1 ELSE 0 END AS [NotRateableQtrCntBasePeriod4]

    ,CASE WHEN ttBpTqStat.[LiabilityDate] <= ttBpTqStat.[LastDayTaxQtr] AND ttBpTqStat.[TotalActiveCnt] > 0      THEN 1 ELSE 0 END AS [IsLiable]

    -- If any quarterly wage report required to be filed from initial liability date has not been filed by the cut-off date or not received,
    -- -- These employers will be assigned the maximum rate.
    ,CASE WHEN (ttBpTqStat.[LiabilityDate] <= ttBpTqStat.[LastDayTaxQtr] AND ttBpTqStat.[TotalActiveCnt] > 0 AND 
                (ttBpTqStat.[TaxQtrRcvDate] IS NULL OR ttBpTqStat.[TaxQtrRcvDate] > @FebMailingDateCutoff))   AND
                (ttBpTqStat.[TaxRateTimely] IS NULL OR ttBpTqStat.[TaxRateTimely] = 0)
               
                THEN 1 ELSE 0 END AS [IsLate]

    ,CASE WHEN ttBpTqStat.[LiaStatusEnd] IS NOT NULL THEN ttBpTqStat.[LiaStatusEnd] ELSE ttBpTqStat.[LiaStatusBegin] END [QtrLiaStatusEnd] 

    --,ttBpTqStat.[TotalActiveCnt]

FROM (

SELECT DISTINCT
        ttTaxQtrStatus.[EmployerID]

    ,ttTaxQtrStatus.[FirstDayTaxQtr]
    ,ttTaxQtrStatus.[LastDayTaxQtr]
    ,ttTaxQtrStatus.[TaxQtrRcvDate]
    ,ttTaxQtrStatus.[TaxRateTimely]

    --------------------,ttTaxQtrStatus.[TaxableWagesQtrTotal]
    ,ttTaxQtrStatus.[TaxableWagesQtrTimely]

    ,MIN(ttStatus.[EffDt])         AS [EffDt]
    ,MAX(ttStatus.[EffEndDt])      AS [EffEndDt]
    ,MIN(ttStatus.[ReActivation581Liability]) AS [UseCovEffDate]
    ,MIN(ttStatus.[CovEffDate])    AS [CovEffDate]

    ,MIN(CASE WHEN ttStatus.[LiaStatus] IN ('ACTIVE', 'REACTIVATED') THEN  ttStatus.[LiabilityDate] ELSE NULL END) AS [LiabilityDate]

    ,MAX(CASE WHEN ttStatus.[StatDetOrder]  = 1 THEN ttStatus.[LiaStatus] ELSE NULL END) AS [LiaStatusBegin] 
    ,MAX(CASE WHEN ttStatus.[StatDetOrder]  = 1 THEN ttStatus.[LiaStatus] ELSE NULL END) AS [LiaStatusEnd] 

    ,SUM(CASE WHEN ttStatus.[LiaStatus] IN ('ACTIVE', 'REACTIVATED') THEN  1 ELSE 0 END) AS [TotalActiveCnt]

FROM (
SELECT DISTINCT
        ttTaxQtrData.[EmployerID]
    ,ttTaxQtrData.[FirstDayTaxQtr]
    ,ttTaxQtrData.[LastDayTaxQtr]
    ,ttTaxQtrData.[TaxQtrRcvDate]
    ,ttTaxQtrData.[TaxRateTimely]
    --------------------,SUM(ISNULL(ttTaxQtrData.[TaxableWagesQtrTotal], 0.00))  AS [TaxableWagesQtrTotal]
    ,CAST(SUM(ISNULL(ttTaxQtrData.[TaxableWagesQtrTimely], 0.00)) AS MONEY) AS [TaxableWagesQtrTimely]

FROM (

SELECT DISTINCT
     ttTaxQtrRank.[EmployerID]
    ,ttTaxQtrRank.[FirstDayTaxQtr]
    ,ttTaxQtrRank.[LastDayTaxQtr]

    ,ttTaxQtrRank.[TaxQtrRcvDate]
    ,ttTaxQtrRank.[TaxRateTimely]
    --------------------,ttTaxQtrRank.[TaxableWagesQtrTotal]
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
   
    LEFT JOIN [Account].[TaxQuarterReports]       AS ttTQRept   ON ttTQRept.[TaxQuarterID]   = ttTaxQtr.[TaxQuarterID]
    LEFT JOIN [Configuration].[ReportType]        AS ttReptType ON ttReptType.[ReportTypeId] = ttTQRept.[ReportTypeId]

    WHERE 1=1
      AND ttTQRept.IsEnabled       = 1
      AND ttTaxQtr.[Year]          <= @FiscalYear - 1
      AND ttTQRept.[ReceivedDate]  IS NOT NULL
      AND (ttTQRept.[ReceivedDate] <= ttAcqEmployers.[FebMailingDateCutoff] OR ttTaxQtr.[TaxRateTimely] = 1)
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
) AS ttTaxQtrStatus
    INNER JOIN CTE_StatusDetermination AS ttStatus ON ttStatus.[EmployerID] = ttTaxQtrStatus.[EmployerID]
                AND ttTaxQtrStatus.[FirstDayTaxQtr] <= ttStatus.[EffEndDt] 
                AND ttTaxQtrStatus.[LastDayTaxQtr]  >= ttStatus.[EffDt]  
    GROUP BY
        ttTaxQtrStatus.[EmployerID]
    ,ttTaxQtrStatus.[FirstDayTaxQtr]
    ,ttTaxQtrStatus.[LastDayTaxQtr]
    ,ttTaxQtrStatus.[TaxQtrRcvDate]
    ,ttTaxQtrStatus.[TaxRateTimely]
    --------------------,ttTaxQtrStatus.[TaxableWagesQtrTotal]
    ,ttTaxQtrStatus.[TaxableWagesQtrTimely]
) AS ttBpTqStat -- Base Period Tax Quarter Status 
        LEFT JOIN #BasePeriod AS ttBasePeriod ON ttBasePeriod.[BasePeriodDatePrior] = ttBpTqStat.[FirstDayTaxQtr] AND ttBasePeriod.[BasePeriodDatePriorEnd] = ttBpTqStat.[LastDayTaxQtr]

) AS ttData

GROUP BY
    ttData.[EmployerID]  
) AS ttDataSum
INNER JOIN #ttAcqEmployers                 AS ttAcqEmployers  ON ttAcqEmployers.[PredecessorEmployerID] = ttDataSum.[EmployerID]
        AND ttAcqEmployers.[IsPartial] = 0 AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER
LEFT  JOIN [Account].[TaxRateExpTaxesPaid] AS ttTaxesPaid     ON ttTaxesPaid.[AnchorEmployerId] = ttAcqEmployers.[AnchorEmployerId]
       AND ttAcqEmployers.[IsPartial]       = 0 
       AND ttAcqEmployers.[AcquisitionDate] IS NULL -- ONLY ANCHOR EMPLOYER
       AND ttTaxesPaid.[EmployerID]         = ttDataSum.[EmployerID] 
       AND ttTaxesPaid.[FiscalYear]         = ttAcqEmployers.[FiscalYear]

GROUP BY
        ttDataSum.[EmployerID]  
    ,ttDataSum.[MAX_NonZeroWageBasePeriod1]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod2]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod3]
    ,ttDataSum.[MAX_NonZeroWageBasePeriod4]

    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod1]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod2]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod3]
    ,ttDataSum.[SUM_NotRateableQtrCntBasePeriod4]
    
    ,ttDataSum.[SUM_IsLate]

) AS ttSumTaxesPaid
LEFT JOIN [Account].[TaxRateExpBenChg] AS ttBenChg ON ttBenChg.[AnchorEmployerID] = @AnchorEmployerID 
        AND ttBenChg.[IsPartial] = 0 
        AND ttBenChg.[EmployerID] = ttSumTaxesPaid.[EmployerID] 
        AND ttBenChg.[FiscalYear] = @FiscalYear 
        --AND ttBenChg.TaxRateExpBenChgID         is null
      
GROUP BY
        ttSumTaxesPaid.[EmployerID]  
    ,[MAX_NonZeroWageBasePeriod1]
    ,[MAX_NonZeroWageBasePeriod2]
    ,[MAX_NonZeroWageBasePeriod3]
    ,[MAX_NonZeroWageBasePeriod4]

    ,[SUM_NotRateableQtrCntBasePeriod1]
    ,[SUM_NotRateableQtrCntBasePeriod2]
    ,[SUM_NotRateableQtrCntBasePeriod3]
    ,[SUM_NotRateableQtrCntBasePeriod4]
    
    ,[SUM_IsLate]

    ,[TaxesPaid]
    ,[TaxesPaidPrior]
) AS ttSumBenChg
LEFT JOIN [Account].[TaxRateExpPayRoll] AS ttPayRoll ON ttPayRoll.[AnchorEmployerID] = @AnchorEmployerID
        AND ttPayRoll.[IsPartial]           = 0
        AND ttPayRoll.[EmployerID]          = ttSumBenChg.EmployerID
        AND ttPayRoll.[FiscalYear]          = @FiscalYear
        --AND ttPayRoll.]TaxRateExpPayRollID] is null
GROUP BY
     ttSumBenChg.[EmployerID]  
    ,[MAX_NonZeroWageBasePeriod1]
    ,[MAX_NonZeroWageBasePeriod2]
    ,[MAX_NonZeroWageBasePeriod3]
    ,[MAX_NonZeroWageBasePeriod4]

    ,[SUM_NotRateableQtrCntBasePeriod1]
    ,[SUM_NotRateableQtrCntBasePeriod2]
    ,[SUM_NotRateableQtrCntBasePeriod3]
    ,[SUM_NotRateableQtrCntBasePeriod4]
    
    ,[SUM_IsLate]
    
    ,[TaxesPaid]
    ,[TaxesPaidPrior]

    ,[BenefitsChargedClient]
    ,[BenefitsRelievedClient]
    ,[BenefitsTotalClient]
    ,[BenefitsChargedClientPrior]
    ,[BenefitsRelievedClientPrior]
    ,[BenefitsTotalClientPrior]

) AS ttMoney
) AS ttReserveCalc
LEFT JOIN [Account].[vw_EmployerStatusDetFromToLiability] AS ttStatDetLiability on ttStatDetLiability.[EmployerID] = ttReserveCalc.[EmployerID]
        AND ttStatDetLiability.[StatDetCreatedUtc] < @StatDetCreatedCutoffUtc 
        AND ttStatDetLiability.[StatDetRank] = 1
) AS SOURCE -- SOURCE ===============================================
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
        TARGET.[ReserveRatio]                <> SOURCE.[ReserveRatio]                              OR

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
            AND XX.[AdjustmentUtcDate] >= MaxPriorYearBenChgCreatedCutoffUtcFYPrior
            AND XX.[AdjustmentUtcDate] <  MaxPriorYearBenChgCreatedCutoffUtcFY
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

    ,(mi.[TaxesPaidPrior])
    - (mi.[BenefitsChargedClientPrior]  - mi.[BenefitsRelievedClientPrior]) 
    + mi.TaxesPaidPriorAdjust - mi.[BenefitsTotalClientPriorAdjust]
    as [PriorReserve]

    ,(mi.[TaxesPaidPrior])                                                    -- ADD      [TaxesPaidPrior]
    - (mi.[BenefitsChargedClientPrior] - mi.[BenefitsRelievedClientPrior])    -- SUBTRACT [BenefitsTotalClientPrior]
    + mi.TaxesPaidPriorAdjust - mi.[BenefitsTotalClientPriorAdjust]

    + (mi.[TaxesPaid])                                                        -- ADD      [TaxesPaid]
    - (mi.[BenefitsChargedClient]      - mi.[BenefitsRelievedClient])         -- SUBTRACT [BenefitsTotalClient]
    + mi.TaxesPaidPriorAdjust - mi.[BenefitsTotalClientPriorAdjust]
    AS [Reserve]

    ,NULL --,SOURCE.[ReserveRatio]

    ,@RateTypeMaxRate4 -- ISNULL(SOURCE.[RateTypeDetermined], @RateTypeUndetermined)
    ,@FebMailingDateCutoff -- [FebMailingDateCutoff]

    ,GETUTCDATE()  --AS 'CreatedDate'
    ,GETUTCDATE()  --AS 'ModifiedDate'

FROM #MissingIds AS mi
WHERE [EmployerId] = @AnchorEmployerID

-- TransferExperience

CREATE TABLE #ttTransExp 
(
    [AnchorEmployerId]                  INT,
    [EmployerID]                         INT,
    [AcquisitionID]                     BIGINT,
    [IsPartial]                            BIT,
    [SuccessorEmployerID]               INT,
    [PredecessorEmployerID]             INT,

    [TaxablePayRollTimely]                MONEY,
    [TaxablePayRoll]                    MONEY,
    [TotalPayRollTimely]                MONEY,
    [TotalPayRoll]                        MONEY,

    [TaxesPaid]                            MONEY,
    [TaxesPaidAdjust]                   MONEY,

    [TaxesPaidPrior]                    MONEY,
    [TaxesPaidPriorAdjust]              MONEY,

    [BenefitsChargedClient]                MONEY,
    [BenefitsRelievedClient]            MONEY,
    [BenefitsTotalClientAdjust]          MONEY,

    [BenefitsChargedClientPrior]        MONEY,
    [BenefitsRelievedClientPrior]        MONEY,
    [BenefitsTotalClientPriorAdjust]     MONEY,

    [Year1]                          SMALLINT,
    [TaxablePayRollTimelyYear1]            MONEY,
    [TaxablePayRollYear1]                MONEY,
    [TotalPayRollTimelyYear1]            MONEY,
    [TotalPayRollYear1]                    MONEY,

    [Year2]                          SMALLINT,
    [TaxablePayRollTimelyYear2]            MONEY,
    [TaxablePayRollYear2]                MONEY,
    [TotalPayRollTimelyYear2]            MONEY,
    [TotalPayRollYear2]                    MONEY,

    [Year3]                         SMALLINT,
    [TaxablePayRollTimelyYear3]            MONEY,
    [TaxablePayRollYear3]                MONEY,
    [TotalPayRollTimelyYear3]            MONEY,
    [TotalPayRollYear3]                    MONEY,

    [ClientTaxablePayRoll]                MONEY,

    [Reserve]                             MONEY,
    [PriorReserve]                         MONEY,

    [PercentTransfer]            DECIMAL(8, 4)


)

-- Employer and Full Transfer Experience -- [IsPartial] = 0

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

-- Partial Transfer Experience -- [IsPartial] = 1

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

-- MISSING ACQUISTION DATA
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

-- #ttTransExp SET RESERVE 
UPDATE  TT SET
    TT.[Reserve]      = TT.[TaxesPaid]      - (TT.[BenefitsChargedClient]      - TT.[BenefitsRelievedClient]),
    TT.[PriorReserve] = TT.[TaxesPaidPrior] - (TT.[BenefitsChargedClientPrior] - TT.[BenefitsRelievedClientPrior])
FROM #ttTransExp AS TT

-- #ttTransExp Set [ClientTaxablePayroll] 
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

-- #ttTransExp Set [PercentTransfer] 
UPDATE  TT SET
    TT.[PercentTransfer] =
        CASE WHEN TT.[IsPartial] = 0                                                  THEN 1.00  
            WHEN TT.[TaxablePayRoll]       IS NULL OR [TaxablePayRoll]       <  0.00 THEN 0.00 
            WHEN TT.[ClientTaxablePayroll] IS NULL OR [ClientTaxablePayroll] <= 0.00 THEN 0.00 
            WHEN TT.[ClientTaxablePayroll] > [TaxablePayRoll]                        THEN 1.00 
            ELSE TT.[ClientTaxablePayroll] / [TaxablePayRoll] END 
FROM #ttTransExp AS TT

CREATE TABLE #ttTransExpPayroll
(
    [AnchorEmployerId]              INT,
    [EmployerID]                    INT,
    [AcquisitionID]                    BIGINT,
    [IsPartial]                        BIT,
    [SuccessorEmployerID]           INT,
    [PredecessorEmployerID]         INT,

    [Year]                          SMALLINT,
    [Quarter]                       TINYINT,
    [QtrIsTimely]                   BIT,
    [QtrTaxRateTimely]              BIT,

    [TaxablePayRollTimely]            MONEY,
    [TaxablePayRoll]                MONEY,
    [TotalPayRollTimely]            MONEY,
    [TotalPayRoll]                    MONEY

)

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

-- #1 DATA (KEEP IN ORDER):  TransferExperience 
SELECT * FROM #ttTransExp

-- #2 DATA (KEEP IN ORDER):  TransferExperiencePayroll 
SELECT * FROM #ttTransExpPayroll

-- #3 DATA (KEEP IN ORDER):  RateTypeDetermined
SELECT distinct
     [EmployerID] -- INT
    ,[RateTypeDetermined] -- VARCHAR 100
    ,@FebMailingDateCutoff AS FebMailingDateCutoff -- DATE
FROM [Account].[TaxRateExpReserveCalc] 
WHERE [AnchorEmployerID] = @AnchorEmployerID AND [EmployerID] = @AnchorEmployerID AND [FiscalYear] = @FiscalYear

-- #4 DATA (KEEP IN ORDER):  StatDetLiability
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
SELECT * FROM CTE_SdLiability  

-- #5 DATA (KEEP IN ORDER):  TaxRateHawaii
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

-- 
SELECT * FROM #ttTransExp;
SELECT 


   PriorReserve = ISNULL(TaxesPaidPrior, 0.00) - 
                  (ISNULL(BenefitsChargedClientPrior, 0.00) - ISNULL(BenefitsRelievedClientPrior, 0.00)) +  -- BenefitsTotalClientPrior
                  ISNULL(BenefitsTotalClientPriorAdjust, 0.00),                                             -- BenefitsTotalClientPriorAdjust

   Contributions = ISNULL(TaxesPaid, 0.00),


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
   BenefitsTotalClientAdjust = ISNULL(BenefitsTotalClientAdjust, 0.00),

   BenefitsChargedClientPrior,
   BenefitsRelievedClientPrior,
   BenefitsTotalClientPrior       = ISNULL(BenefitsChargedClientPrior, 0.00) - ISNULL(BenefitsRelievedClientPrior, 0.00),

   BenefitsTotalClientPriorAdjust,
   BenefitsTotalClientPriorAdjust = ISNULL(BenefitsTotalClientPriorAdjust, 0.00),

   TaxablePayRollTimelyYear1,
   TaxablePayRollTimelyYear2,
   TaxablePayRollTimelyYear3,

   '<<< DATA' AS 'DATA'
FROM #ttTransExp

SELECT -- [Account].[TaxRateExpTaxesPaid]

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

---- Session temp tables: drop if they exist from a prior run in this session
--DROP TABLE IF EXISTS #ValidTransferTypes;
--DROP TABLE IF EXISTS #PartialTransferTypes;
--DROP TABLE IF EXISTS #BasePeriod;
--DROP TABLE IF EXISTS #BasePeriodDatePriorCommonTable;
--DROP TABLE IF EXISTS #ttAcquistions;
--DROP TABLE IF EXISTS #ttAcquistionsNotPendApp;
--DROP TABLE IF EXISTS #ttAcqEmployers;
--DROP TABLE IF EXISTS #EmpolyerSD;
--DROP TABLE IF EXISTS #EmplStatDet;
--DROP TABLE IF EXISTS #TaxQuartersQwrQwraLateStatus;
--DROP TABLE IF EXISTS #MissingIds;
--DROP TABLE IF EXISTS #ttTransExp;




END


