
--CREATE PROCEDURE [Account].[TaxRateExpAnchorReserveCalcRun]
--    @ParamFiscalYear      SMALLINT,
--    @ParamEmployerID      INT          = NULL,
--WITH RECOMPILE
--AS --- STORED PROCEDURE
BEGIN


DECLARE @ParamFiscalYear      SMALLINT     = 2026;
DECLARE @ParamEmployerID      INT          = 2110212048 -- 284477044 --  213373310 284476289

-- ====================================================================================================

-- SELECT [Code] FROM [Configuration].[TransferType]

DECLARE @TransferTypeUC86        VARCHAR(50) = 'UC86'
DECLARE @TransferTypeSUTAFULL    VARCHAR(50) = 'SUTAFULL'
DECLARE @TransferTypeSUTAPARTIAL VARCHAR(50) = 'SUTAPARTIAL'

DECLARE @ValidTransferTypes Table ([ValidTransferType] VARCHAR(100))

INSERT INTO @ValidTransferTypes
----------SELECT [Code] FROM [Configuration].[TransferType] WHERE [Code] <> 'NONE' ---------- FOR TESTING
VALUES 
 (@TransferTypeUC86)
,(@TransferTypeSUTAFULL)
,(@TransferTypeSUTAPARTIAL)

-- Partial Transfer Type

DECLARE @PartialTransferTypes Table ([PartialTransferType] VARCHAR(100))

INSERT INTO @PartialTransferTypes
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

-- @BasePeriod table is used to get the 1st 4 quarter of the prior 5 quarters of the quarter for the calandar year prior to the calandar year processing.
DECLARE @BasePeriod TABLE 
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

        INSERT INTO @BasePeriod
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

DECLARE @BasePeriodDatePriorCommonTable TABLE ([BasePeriodDatePrior] DATE)

INSERT INTO @BasePeriodDatePriorCommonTable
SELECT TOP 1 [BasePeriodDatePrior] FROM @BasePeriod group by [BasePeriodDatePrior] HAVING COUNT(*) = 4
OPTION (RECOMPILE)

DECLARE @BasePeriodDatePriorCommon DATE = (SELECT TOP 1 [BasePeriodDatePrior] FROM @BasePeriodDatePriorCommonTable)

DECLARE @YearQtr1 INT = (SELECT    MIN([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM @BasePeriod)
DECLARE @YearQtr2 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM @BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr1
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr3 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM @BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr2
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr4 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM @BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr3
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr5 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM @BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr4
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr6 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM @BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr5
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))
DECLARE @YearQtr7 INT = (SELECT TOP 1 ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) FROM @BasePeriod 
                         WHERE        ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]) > @YearQtr6
                         ORDER BY     ([BasePeriodDatePriorYear] * 10 + [BasePeriodDatePriorQtr]))

-- ====================================================================================================

PRINT '=============================================='
PRINT '[Account].[TaxRateExpAnchorReserveCalcRun] Calculate'
PRINT ''
PRINT '@AnchorEmployerID           : ' + ISNULL(CAST(@AnchorEmployerID   AS VARCHAR),  '-NULL-') 
PRINT '@FiscalYear                 : ' + CAST(@FiscalYear                AS VARCHAR)
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

DECLARE @ttAcquistions        TABLE 
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
    [TransferType]          VARCHAR(100),
    [IsPartial]             BIT,

    -- Stat Det - Liability Status - CURRENT
    [SuccCurLiaStat]        VARCHAR(100),
    [PredCurLiaStat]        VARCHAR(100),

    -- Processing Status 

    [ProcStatEffDt]         DATE,
    [ProcessCode]           VARCHAR(200),
    [ProcessStatusCode]     VARCHAR(200),
    [ProcStatID]            BIGINT,
    [ProcStatCreated]       DATETIME2,

    [ProcStatOrder]         BIGINT,
    [ProcStatRank]          BIGINT,

    [SuccLiaEffDate]         DATE,
    [SuccLiaStatus]          VARCHAR (100),
    [SuccLiabilityDate]      DATE,
    [SuccFirstLiabilityDate] DATE,

    [PredLiaEffDate]         DATE,
    [PredLiaStatus]          VARCHAR (100),
    [PredLiabilityDate]      DATE,
    [PredFirstLiabilityDate] DATE,

    [NavLevel]               INT,
    [NavPath]                VARCHAR(MAX),

    [CurrentStatusExclude]   VARCHAR(MAX)


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
DECLARE @ttAcquistionsNotPendApp TABLE 
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
    [TransferType]          VARCHAR(100),
    [IsPartial]             BIT,

    -- Stat Det - Liability Status - CURRENT
    [SuccCurLiaStat]        VARCHAR(100),
    [PredCurLiaStat]        VARCHAR(100),

    -- Processing Status 

    [ProcStatEffDt]         DATE,
    [ProcessCode]           VARCHAR(200),
    [ProcessStatusCode]     VARCHAR(200),
    [ProcStatID]            BIGINT,
    [ProcStatCreated]       DATETIME2,

    [ProcStatOrder]         BIGINT,
    [ProcStatRank]          BIGINT,

    [SuccLiaEffDate]         DATE,
    [SuccLiaStatus]          VARCHAR (100),
    [SuccLiabilityDate]      DATE,
    [SuccFirstLiabilityDate] DATE,

    [PredLiaEffDate]         DATE,
    [PredLiaStatus]          VARCHAR (100),
    [PredLiabilityDate]      DATE,
    [PredFirstLiabilityDate] DATE,

    [NavLevel]               INT,
    [NavPath]                VARCHAR(MAX),

    [CurrentStatusExclude]   VARCHAR(MAX)


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
        (@AnchorEmployerID IS NULL OR ttAcq.[SuccessorEmployerID] = @AnchorEmployerID)
        AND ttTransferTypePrev.[Code] IN (SELECT [ValidTransferType] FROM @ValidTransferTypes)
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
INSERT INTO @ttAcquistions 
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
LEFT  JOIN @PartialTransferTypes          AS ttPartialTransferTypes ON ttPartialTransferTypes.PartialTransferType = ttTransferType.[Code]
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
        (@AnchorEmployerID IS NULL OR ttAcq.[PredecessorEmployerID] = @AnchorEmployerID)
        AND ttTransferTypePrev.[Code] IN (SELECT [ValidTransferType] FROM @ValidTransferTypes)
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
INSERT INTO @ttAcquistions 
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
LEFT  JOIN @PartialTransferTypes          AS ttPartialTransferTypes ON ttPartialTransferTypes.PartialTransferType = ttTransferType.[Code]
) AS ttProcessStatus
OPTION (MAXRECURSION 32767);

-- UPDATE -- If the current status of a [PredecessorEmployerID] is NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
-- PredCurLiaStat NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
UPDATE TT SET 
  TT.[CurrentStatusExclude] = ttNotActInActTermList.[CurrentStatusExclude]
FROM @ttAcquistions TT
INNER JOIN 
(SELECT AnchorEmployerId, STRING_AGG(CAST(PredecessorEmployerID AS VARCHAR(20)), ',') WITHIN GROUP (ORDER BY PredecessorEmployerID) AS [CurrentStatusExclude]
   FROM (-- if the Predecessor is not in ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED') then exclude and terminate traversing
         SELECT DISTINCT AnchorEmployerId, PredecessorEmployerID
         FROM @ttAcquistions WHERE 1=1 AND PredCurLiaStat NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
         ) AS DistinctPreds GROUP BY AnchorEmployerId
) AS ttNotActInActTermList ON ttNotActInActTermList.[AnchorEmployerId] = TT.[AnchorEmployerId]
OPTION (RECOMPILE);

-- REMOVE: SuccessorEmployerID or PredecessorEmployerID if in [CurrentStatusExclude]
-- Will Exclude if not in NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
DELETE A
FROM @ttAcquistions AS A
CROSS APPLY STRING_SPLIT(A.[CurrentStatusExclude], ',') AS ttExclude
WHERE 
    -- Traversing means that a Successor was one a predecessor so check both
       TRY_CAST(ttExclude.value AS INT) = A.[SuccessorEmployerID]   
    OR TRY_CAST(ttExclude.value AS INT) = A.[PredecessorEmployerID]
OPTION (RECOMPILE);

-- @ttAcqEmployers will include the employers that we will be processed
DECLARE @ttAcqEmployers TABLE 
(
     [AnchorEmployerId]                 INT
    ,[AcquisitionID]                    BIGINT
    ,[AcquisitionDate]                  DATE
    ,[SutaCutoffYear]                   SMALLINT
    ,[AcquisitionCreated]               DATETIME2(2)
    ,[TransferType]                     VARCHAR(100)
    ,[IsPartial]                        BIT

    ,[SuccessorEmployerID]              INT
    ,[PredecessorEmployerID]            INT
    ,[NavLevel]                         INT
    ,[NavPath]                          VARCHAR(MAX)

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

INSERT INTO @ttAcqEmployers
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

  FROM @ttAcquistions AS ttAcquistions
  WHERE 1=1
OPTION (RECOMPILE)

-- [Account].[Employer]
INSERT INTO @ttAcqEmployers
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
    AND (@AnchorEmployerID IS     NULL OR ttEmp.[EmployerID] = @AnchorEmployerID)
    AND (@AnchorEmployerID IS NOT NULL OR ttLiaStat.[Code]   IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED'))
OPTION (RECOMPILE)


END

