
CREATE OR ALTER PROCEDURE [Account].[TaxRateExpAcqEmployers]
    @ParamFiscalYear      SMALLINT, -- Always passed a value
    @ParamEmployerID      INT       -- Always passed a value
WITH RECOMPILE
AS --- STORED PROCEDURE
BEGIN

SET NOCOUNT ON; 

/*
#ttAcquisitions  created by the calling procedure.
#ttAcqEmployers  created by the calling procedure.
*/

--DECLARE @ParamFiscalYear      SMALLINT     = 2026;
--DECLARE @ParamEmployerID      INT          = 2110212048 -- 284477044 --  213373310 284476289

-- Session temp tables: drop if they exist from a prior run in this session
DROP TABLE IF EXISTS #ValidTransferTypes;
DROP TABLE IF EXISTS #PartialTransferTypes;
DROP TABLE IF EXISTS #EmpolyerSD;

-- Step timing: each step sets @StepStart before it runs, captures @@ROWCOUNT immediately after it, and PRINTs the elapsed time
DECLARE @StepStart                           DATETIME2(7)
DECLARE @StepRows                            INT

-- ====================================================================================================

-- SELECT [Code] FROM [Configuration].[TransferType]

DECLARE @TransferTypeUC86        VARCHAR(50) = 'UC86'
DECLARE @TransferTypeSUTAFULL    VARCHAR(50) = 'SUTAFULL'
DECLARE @TransferTypeSUTAPARTIAL VARCHAR(50) = 'SUTAPARTIAL'

CREATE TABLE #ValidTransferTypes ([ValidTransferType] VARCHAR(100) COLLATE DATABASE_DEFAULT)

SET @StepStart = SYSDATETIME()

INSERT INTO #ValidTransferTypes
----------SELECT [Code] FROM [Configuration].[TransferType] WHERE [Code] <> 'NONE' ---------- FOR TESTING
VALUES
 (@TransferTypeUC86)
,(@TransferTypeSUTAFULL)
,(@TransferTypeSUTAPARTIAL)

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ValidTransferTypes: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Partial Transfer Type

CREATE TABLE #PartialTransferTypes ([PartialTransferType] VARCHAR(100) COLLATE DATABASE_DEFAULT)

SET @StepStart = SYSDATETIME()

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

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #PartialTransferTypes: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

DECLARE @LocalTimeZone       SYSNAME -- = 'Hawaiian Standard Time'

SELECT
    @LocalTimeZone        = [LocalTimeZone]
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

DECLARE @MaxAcqProcUtc               DATE   = '9999-12-31'
DECLARE @MaxCreatedAcquistions DATETIME2(2) = '9999-12-31'
DECLARE @MaxCreatedStatDet     DATETIME2(2) = '9999-12-31'
-- ====================================================================================================

-- MAX LENGTH 100                              --123456789012345678901234567890123456789012345678900123456789001234567890123456789012345678901234567890

-- A. - Filed wage reports = zero wages
-- Not Chargeable - To Be Chargeable need to have at least one Non Zero Wage in each Base Period

PRINT '=============================================='
PRINT '[Account].[TaxRateExpAnchorReserveCalcRun] Calculate'
PRINT ''
PRINT '@AnchorEmployerID           : ' + CAST(@AnchorEmployerID   AS VARCHAR)
PRINT '@FiscalYear                 : ' + CAST(@FiscalYear         AS VARCHAR)
PRINT ''
PRINT '@LocalTimeZone              : ' + @LocalTimeZone
PRINT ''
PRINT '=============================================='


/*
Get all the ttAcq records in whech the predecessor is a successor. Walk through all the records, 
if walking through the list starts you find a predecessor that was already fopund don't wlk the list twice
*/

-- original - Anchor as Successor - [RecType] = 0 -- INSERT #ttAcquistions
SET @StepStart = SYSDATETIME()

-- Anchor as Successor - [RecType] = 0 -- INSERT #ttAcquistions
;WITH AnchorAcqSuccessor AS
(
    -- Acquisitions where the Anchor is the Successor, with a valid transfer type,
    -- where both Successor and Predecessor are currently ACTIVE / REACTIVATED / INACTIVE / TERMINATED
    SELECT 
         ttAcq.[AcquisitionID]
        ,ttAcq.[SuccessorEmployerID]
        ,ttAcq.[PredecessorEmployerID]
        ,ttAcq.[AcquisitionDate]
        ,ttAcq.[CreatedDate]            AS [AcquisitionCreated]
        ,ttAcq.[SutaCutoffYear]
        ,ttAcq.[ExperienceTransferID]
        ,ttAcq.[FormApplicationId]
        ,ttTransferType.[Code]          AS [TransferType]
    FROM [Account].[Acquisition]              AS ttAcq
    INNER JOIN [Account].[ExperienceTransfer] AS ttExpTrans     ON ttExpTrans.[ExperienceTransferID] = ttAcq.[ExperienceTransferID]
    INNER JOIN [Configuration].[TransferType] AS ttTransferType ON ttTransferType.[TransferTypeID]   = ttExpTrans.[TransferTypeID]
    WHERE 
        -- only going one DEEP so SuccessorEmployerID = @AnchorEmployerID
            ttAcq.[SuccessorEmployerID] = @AnchorEmployerID
        AND ttTransferType.[Code] IN (SELECT [ValidTransferType] FROM #ValidTransferTypes)
        AND ttAcq.[CreatedDate] < @MaxCreatedAcquistions

        -- Status filters: current liability status of the Successor
        AND (
            SELECT TOP 1 YY.[Code]
            FROM [Account].[StatusDetermination]   AS XX
            JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]
            WHERE XX.[IsEnabled]  = 1 
              AND XX.[EmployerID] = ttAcq.[SuccessorEmployerID]
            ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC
        ) IN ('ACTIVE','REACTIVATED','INACTIVE','TERMINATED')

        -- Status filters: current liability status of the Predecessor
        AND (
            SELECT TOP 1 YY.[Code]
            FROM [Account].[StatusDetermination]   AS XX
            JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]
            WHERE XX.[IsEnabled]  = 1 
              AND XX.[EmployerID] = ttAcq.[PredecessorEmployerID]
            ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC
        ) IN ('ACTIVE','REACTIVATED','INACTIVE','TERMINATED')
),

RecursiveCTE AS
(
    -- Anchor
    SELECT 
         b.*
        ,CAST(',' + CAST(b.[SuccessorEmployerID] AS VARCHAR(20)) + ',' AS VARCHAR(MAX)) AS [NavPath]
    FROM AnchorAcqSuccessor AS b

    UNION ALL

    -- Walk: predecessor becomes next successor
    SELECT 
         b.*
        ,r.[NavPath] + CAST(b.[SuccessorEmployerID] AS VARCHAR(20)) + ','
    FROM AnchorAcqSuccessor AS b
    INNER JOIN RecursiveCTE AS r ON b.[SuccessorEmployerID] = r.[PredecessorEmployerID]
    -- Prevent revisiting (no double walking)
    WHERE r.[NavPath] NOT LIKE '%,' + CAST(b.[SuccessorEmployerID] AS VARCHAR(20)) + ',%'
)
INSERT INTO #ttAcquistions 
(
     [RecType]
    ,[AnchorEmployerId]
    ,[SuccessorEmployerID]
    ,[PredecessorEmployerID]

    -- Additional Fields
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

    -- Stat Det - Liability Status - CURRENT
    ,[SuccCurLiaStat]
    ,[PredCurLiaStat]
)
SELECT DISTINCT 
     0                  AS [RecType]
    ,@AnchorEmployerID  AS [AnchorEmployerId]
    ,R.[SuccessorEmployerID]
    ,R.[PredecessorEmployerID]

    -- Additional Fields
    ,R.[AcquisitionID]
    ,R.[AcquisitionDate]
    ,R.[AcquisitionCreated]
    ,R.[SutaCutoffYear]
    ,R.[ExperienceTransferID]
    ,R.[FormApplicationId]

    ,LEN(R.[NavPath]) - LEN(REPLACE(R.[NavPath], ',', '')) AS [NavLevel] 
    ,R.[NavPath]

    -- Supporting Data 
    ,R.[TransferType]
    ,CASE WHEN ttPartialTransferTypes.[PartialTransferType] IS NOT NULL THEN 1 ELSE 0 END AS [IsPartial]

    -- Stat Det - Liability Status - CURRENT
    ,(SELECT TOP 1 YY.[Code]
        FROM [Account].[StatusDetermination]   AS XX 
        JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]                  
        WHERE XX.[IsEnabled]   = 1
          AND XX.[CreatedDate] < @MaxCreatedAcquistions
          AND XX.[EmployerID]  = R.[SuccessorEmployerID] 
        ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC) AS [SuccCurLiaStat]

    ,(SELECT TOP 1 YY.[Code]
        FROM [Account].[StatusDetermination]   AS XX 
        JOIN [Configuration].[LiabilityStatus] AS YY ON YY.[LiabilityStatusID] = XX.[LiabilityStatusID]                  
        WHERE XX.[IsEnabled]   = 1 
          AND XX.[CreatedDate] < @MaxCreatedAcquistions
          AND XX.[EmployerID]  = R.[PredecessorEmployerID] 
        ORDER BY XX.[EffectiveDate] DESC, XX.[CreatedDate] DESC, XX.[StatusDeterminationID] DESC) AS [PredCurLiaStat]

FROM RecursiveCTE AS R
LEFT JOIN #PartialTransferTypes AS ttPartialTransferTypes ON ttPartialTransferTypes.[PartialTransferType] = R.[TransferType]
OPTION (MAXRECURSION 32767);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttAcquistions (Anchor as Successor): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Anchor as Predecessor - [RecType] = 0 -- INSERT #ttAcquistions
SET @StepStart = SYSDATETIME()

;WITH AnchorAcqPredecessor AS
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
    FROM AnchorAcqPredecessor b
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

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttAcquistions (Anchor as Predecessor): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ==== TEMP TABLE NO LONGER UTILIZED: #ValidTransferTypes
-- ==== TEMP TABLE NO LONGER UTILIZED: #PartialTransferTypes

-- UPDATE -- If the current status of a [PredecessorEmployerID] is NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
-- PredCurLiaStat NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
SET @StepStart = SYSDATETIME()

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

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('UPDATE #ttAcquistions [CurrentStatusExclude]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- REMOVE: SuccessorEmployerID or PredecessorEmployerID if in [CurrentStatusExclude]
-- Will Exclude if not in NOT IN ('ACTIVE', 'REACTIVATED', 'INACTIVE', 'TERMINATED')
SET @StepStart = SYSDATETIME()

DELETE A
FROM #ttAcquistions AS A
CROSS APPLY STRING_SPLIT(A.[CurrentStatusExclude], ',') AS ttExclude
WHERE 
    -- Traversing means that a Successor was one a predecessor so check both
       TRY_CAST(ttExclude.value AS INT) = A.[SuccessorEmployerID]   
    OR TRY_CAST(ttExclude.value AS INT) = A.[PredecessorEmployerID]
OPTION (RECOMPILE);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('DELETE #ttAcquistions predecessor not valid: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

SET @StepStart = SYSDATETIME()

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

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttAcqEmployers (acquisitions): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

SET @StepStart = SYSDATETIME()

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

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttAcqEmployers (Anchor): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

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

SET @StepStart = SYSDATETIME()

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
                    ttSD1.[EmployerID],
                    ttLiaStat.[Code] AS [LiaStatus],
                    ttFinMeth.[Code] AS [FinMeth],
                    ttSD1.[EffectiveDate],
                    ttSD1.[CoverageEffectiveDate],
                    ttSD1.[CreatedDate]
                FROM (
                    SELECT distinct
                        ttSD0.[EmployerID]
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

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #EmpolyerSD: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')


-- Rank the Acquistions....
SET @StepStart = SYSDATETIME()

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

OPTION (RECOMPILE);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttAcquistions (rank by Process Status): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ==== TEMP TABLE NO LONGER UTILIZED: #EmpolyerSD

SET @StepStart = SYSDATETIME()

-- Process Statuses 
-- -- PENDING PENDINGUI PENDINGER 
-- -- APPROVED 
-- -- CANCELLED
-- -- DENIED DENIEDUI DENIEDER

-- Keep the most recent APPROVED Process Status

DELETE FROM #ttAcquistions
WHERE [RecType] = 0 OR ([RecType] = 1 AND [ProcStatRank] != 1) --OR [ProcessStatusCode] NOT IN  ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER')
OPTION (RECOMPILE);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('DELETE #ttAcquistions (RecType 0 / not latest Process Status): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Keep the most recent APPROVED Process Status
SET @StepStart = SYSDATETIME()

DELETE FROM #ttAcquistions
WHERE [ProcessStatusCode] NOT IN  ('APPROVED', 'PENDING', 'PENDINGUI', 'PENDINGER')
OPTION (RECOMPILE);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('DELETE #ttAcquistions (not APPROVED / PENDING): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Re-Rank the Acquistions....
SET @StepStart = SYSDATETIME()

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

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #ttAcquistions (re-rank): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Set the SUTA Cutoff Date on temp table #ttAcquistions
SET @StepStart = SYSDATETIME()

UPDATE TT SET
     [SutaCutoffYear] = CAST(YEAR(TT.[AcquisitionDate]) AS SMALLINT) + 3
FROM #ttAcquistions      AS TT
WHERE 1=1
  AND TT.[TransferType] = @TransferTypeSUTAFULL
  AND TT.[SutaCutoffYear] != CAST(YEAR(TT.[AcquisitionDate]) AS SMALLINT) + 3

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('UPDATE #ttAcquistions [SutaCutoffYear]: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

SET @StepStart = SYSDATETIME()

DELETE TT
FROM #ttAcqEmployers TT
WHERE 1=1
  AND [AcquisitionID] IS NOT NULL
  AND NOT EXISTS ( SELECT 1 FROM #ttAcquistions XX WHERE XX.[AcquisitionID] = TT.[AcquisitionID])
OPTION (RECOMPILE);


SET @StepRows = @@ROWCOUNT
PRINT CONCAT('DELETE #ttAcqEmployers (acquisition removed): ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- At this point we start setting #ttAcqEmployers Data 
SET @StepStart = SYSDATETIME()

-- Same for every row: convert the local cutoffs to UTC once
DECLARE @RcptEffCutoffUtc       DATETIME2(2) = CAST(CAST(DATEFROMPARTS(@FiscalYear, 01, 31) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2));
DECLARE @FebMailingCutoffUtc    DATETIME2(2) = CAST(CAST(@FebMailingDateCutoff              AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2));

-- #ttAcqEmployers --Processing parameters: [FirstYearFy] / [FiscalYear], Feb mailing dates, and the UTC cutoffs
UPDATE TT SET
     TT.[FirstYearFy]                               = Calc.[FirstYearFy]
    ,TT.[FiscalYear]                                = @FiscalYear

    -- USED FOR PAYROLL WAGES
    ,TT.[FebMailingDate]                            = @FebMailingDate
    ,TT.[FebMailingDatePrior]                       = @FebMailingDatePrior
    ,TT.[FebMailingDateCutoff]                      = @FebMailingDateCutoff
    ,TT.[FebMailingDateCutoffPrior]                 = @FebMailingDateCutoffPrior

    ,TT.[RcptEffCutoffDate]                         = @RcptEffCutoffUtc
    ,TT.[RcptCreatedCutoffUtc]                      = @FebMailingCutoffUtc
    ,TT.[TaxQtrCreatedCutoffUtc]                    = @FebMailingCutoffUtc

    -- Per row: depends on FirstYearFy
    ,TT.[MaxPriorYearBenChgCreatedCutoffUtcFY]      = 
        CAST(CAST(DATEFROMPARTS(Calc.[FirstYearFy],     01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
    ,TT.[MaxPriorYearBenChgCreatedCutoffUtcFYPrior] = 
        CAST(CAST(DATEFROMPARTS(Calc.[FirstYearFy] - 1, 01, 01) AS DATETIME2(2)) AT TIME ZONE @LocalTimeZone AT TIME ZONE 'UTC' AS DATETIME2(2))
FROM #ttAcqEmployers AS TT
CROSS APPLY (SELECT CAST(CASE WHEN TT.[IsPartial] = 1 THEN YEAR(TT.[AcquisitionDate]) + 1 ELSE @FiscalYear END AS SMALLINT) AS [FirstYearFy]) AS Calc;

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('UPDATE #ttAcqEmployers processing parameters: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

------ #0 OUTPUT DATA RESULT SET (KEEP IN ORDER):  #ttAcquistions -- Done at beginning ============================================================
----SET @StepStart = SYSDATETIME()

----SELECT DISTINCT
----     ttTaxRateExpAcquisition.[AcquisitionID]            AS [AcquisitionID]
----    ,ttTaxRateExpAcquisition.[AcquisitionDate]          AS [AcquisitionDate]
----    ,ttTaxRateExpAcquisition.[SutaCutoffYear]           AS [SutaCutoffYear]
----    ,ttTaxRateExpAcquisition.[AcquisitionCreated]       AS [AcquisitionCreated]
----    ,ttTaxRateExpAcquisition.[TransferType]             AS [TransferType]
----    ,ttTaxRateExpAcquisition.[IsPartial]                AS [IsPartial]

----    ,ttTaxRateExpAcquisition.[SuccessorEmployerID]      AS [SuccessorEmployerID]
----    ,ttTaxRateExpAcquisition.[PredecessorEmployerID]    AS [PredecessorEmployerID]
----    ,ttTaxRateExpAcquisition.[ProcStatEffDt]            AS [ProcStatEffDt]
----    ,ttTaxRateExpAcquisition.[ProcessCode]              AS [ProcessCode]
----    ,ttTaxRateExpAcquisition.[ProcessStatusCode]        AS [ProcessStatusCode]
----    ,ttTaxRateExpAcquisition.[FormApplicationId]        AS [FormApplicationId]

----    ,ttTaxRateExpAcquisition.[ProcStatID]               AS [ProcStatID]
----    ,ttTaxRateExpAcquisition.[ProcStatCreated]          AS [ProcStatCreated]
----    ,ttTaxRateExpAcquisition.[ProcStatOrder]            AS [ProcStatOrder]
----    ,ttTaxRateExpAcquisition.[ProcStatRank]             AS [ProcStatRank]

----    -- EMPLOYER PORTAL DATA -- CAN'T CROSS DB - EMPLOYER PORTAL DATA NOT ACCESSIBLE
----    --,ttTaxRateExpAcquisition.[AppFormType]              AS [AppFormType]
----    --,ttTaxRateExpAcquisition.[FormReviewAction]         AS [FormReviewAction]
----    --,ttTaxRateExpAcquisition.[ResponseDate]             AS [ResponseDate]
----    --,ttTaxRateExpAcquisition.[IsSystemDecision]         AS [IsSystemDecision]
----    --,ttTaxRateExpAcquisition.[DayCntAcqDtToResponse]    AS [DayCntAcqDtToResponse]

----    ,ttTaxRateExpAcquisition.[SuccLiaEffDate]           AS [SuccLiaEffDate]
----    ,ttTaxRateExpAcquisition.[SuccLiaStatus]            AS [SuccLiaStatus]
----    ,ttTaxRateExpAcquisition.[SuccLiabilityDate]        AS [SuccLiabilityDate]
----    ,ttTaxRateExpAcquisition.[SuccFirstLiabilityDate]   AS [SuccFirstLiabilityDate]

----    ,ttTaxRateExpAcquisition.[PredLiaEffDate]           AS [PredLiaEffDate]
----    ,ttTaxRateExpAcquisition.[PredLiaStatus]            AS [PredLiaStatus]
----    ,ttTaxRateExpAcquisition.[PredLiabilityDate]        AS [PredLiabilityDate]
----    ,ttTaxRateExpAcquisition.[PredFirstLiabilityDate]   AS [PredFirstLiabilityDate]

----FROM #ttAcquistions AS ttTaxRateExpAcquisition
----WHERE 1=1
----    AND ttTaxRateExpAcquisition.[ProcStatRank] = 1

----SET @StepRows = @@ROWCOUNT
----PRINT CONCAT('RESULT SET #0 Acquisitions: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttAcquistions

-- ====================================================================================================
-- TEMP TABLE SUMMARY (as of this point - after RESULT SET #0)
-- ----------------------------------------------------------------------------------------------------
-- NO LONGER UTILIZED:
--   #ValidTransferTypes               last used: INSERT #ttAcquistions (Anchor as Predecessor)
--   #PartialTransferTypes             last used: INSERT #ttAcquistions (Anchor as Predecessor)
--   #EmpolyerSD                       last used: INSERT #ttAcquistions (rank by Process Status)
--   #ttAcquistions                    last used: RESULT SET #0 Acquisitions
--
-- STILL NEEDED:
--   #ttAcqEmployers                   TaxRateExp* MERGEs, late/missing check, ReserveCalc, transfer
--                                     experience, RESULT SETS #4 / #5 (** and DEBUG **)
-- ====================================================================================================

-- ==== TEMP TABLE NO LONGER UTILIZED: #ttTransExp
-- ==== TEMP TABLE NO LONGER UTILIZED: #ttAcqEmployers

END


