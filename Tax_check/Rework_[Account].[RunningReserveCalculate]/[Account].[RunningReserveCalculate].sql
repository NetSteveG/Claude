
/****** Object:  StoredProcedure [Account].[RunningReserveCalculate]    Script Date: 11/10/2026 11:08:00 AM ******/
--SET ANSI_NULLS ON
--GO
--SET QUOTED_IDENTIFIER ON
--GO

--CREATE OR ALTER   PROCEDURE [Account].[RunningReserveCalculate]
--    @ParamEmployerID     INT      = NULL,
--    @ParamUser           INT      = NULL
--WITH RECOMPILE
--AS --- STORED PROCEDURE
BEGIN

-- Called from Tax Inquiry

/*
If some sort of adjustment is needed, it could be added with the fields below.

    --,[Adjustment]                        MONEY         NOT NULL -- Amount Of Adjustment
    --,[AdjustmentNote]                    VARCHAR(250)      NULL -- Note on Adjustment
    --,[AdjustmentEffDate]                 DATE              NULL -- Effective Date 

    --,[Year]    -- Based on [AdjustmentEffDate]
    --,[Quarter] -- Based on [AdjustmentEffDate]                     

EXAMPLE: An Adjustment would be done if 
- all the Receipts Paid Taxes ('TAXCOMPUTED', 'TAXSHAREDCOST', 'TAXOTHERSTATE') or
- all the benefit charges 

are not entered into the application.

The Component would need to distinguish between a recipt adjustment and a benefit ajustment
- could use
- - PAYMENTADJUST 
- - BENEFITADJUST 

The Effective date for
- PAYMENT ADJUST would be the date used for Tax Rate Computation Reserve Balance.
- - This would be equivalent to the Receipt [EffectiveDate] where when computing the tax rate 
- - reserve balance for a fiscal year the the effective date must be BEFORE 02/01/YYYY of the fiscal year.
- - The year and quarter would be the Year and Quarter the paymnet is applicable to.

- BENEFITCHARGE ADJUST would be the date used for Tax Rate Computation Reserve Balance.
- - This would be equivalent to the Benefit Charge System Created Date where when computing the tax rate 
- - reserve balance for a fiscal year the charged benefit must have been create BEFORE the 1st day of the Fiscal Year.
- - The year and quarter would be the Year and Quarter the benefit was created which would be the year and 
- - quarter of the [AdjustmentEffDate]

TAX RATE RESERVE BALANCE:

When computing the TAX RATE RESERVE BALANCE in the tax rate computation processing,
- the Running Reserve Payment Adjustments with an effective date BEFORE 02/01/YYYY of the fiscal year and
- the Benefit Charge Adjustments          with an creaated  date BEFORE the 1st day of the Fiscal Year
would be added to the reserve balance.

Accordingly, when computing the Prior TAX RATE RESERVE BALANCE in the tax rate computation processing
the adjustments for BEFORE the prior fiscal year are used.

The the TAX RATE RESERVE BALANCE, 

*/

DECLARE @ParamEmployerID     INT       = 2110212048 -- 214546710 -- 251658810 -- 213373310 -- 63005 213373310 --
DECLARE @ParamUser           INT       = 63005 -- 63005 --

IF (@ParamEmployerID IS NULL)
  RETURN

DROP TABLE IF EXISTS #DeleteePredNotValid
DROP TABLE IF EXISTS #Employers_PREDECESSORS

DECLARE @CurrentUser    INT = CASE WHEN @ParamUser IS NULL THEN 0 ELSE @ParamUser END

DECLARE @Component_Type                       VARCHAR(50) 

DECLARE @Component_PAYMENT                   VARCHAR(50) = 'PAYMENT'
DECLARE @Component_BENEFITCHARGE             VARCHAR(50) = 'BENEFITCHARGE'
DECLARE @Component_PAYMENT_PREDECESSOR       VARCHAR(50) = 'PAYMENT_PREDECESSOR'
DECLARE @Component_BENEFITCHARGE_PREDECESSOR VARCHAR(50) = 'BENEFITCHARGE_PREDECESSOR'
DECLARE @Component_PREDECESSOR               VARCHAR(50) = 'PREDECESSOR'

-- Step timing (elapsed milliseconds printed after each step)
DECLARE @StepStart                           DATETIME2(7)
DECLARE @StepRows                            INT

CREATE TABLE #Employers_PREDECESSORS  
(
    [EmployerID]            INT, 
	[PredecessorEmployerID] INT,
	[PredLiaStatus]         VARCHAR(100),
    [SuccessorEmployerID]   INT,
	[SuccLiaStatus]         VARCHAR(100),
	[TransferType]          VARCHAR(100),
	[AcquisitionDate]       DATE,
	[ResponseDate]          DATE
)

-------------------- TESTING ***************************************************************************
----------------INSERT INTO #Employers_PREDECESSORS
----------------SELECT DISTINCT SuccessorEmployerID, PredecessorEmployerID
----------------FROM [Account].[Acquisition] 

----------------SELECT COUNT(*) '#Employers_PREDECESSORS' FROM #Employers_PREDECESSORS

INSERT INTO #Employers_PREDECESSORS
SELECT DISTINCT 
    [EmployerID], 
	[PredecessorEmployerID],
	[PredLiaStatus],
    [SuccessorEmployerID],
	[SuccLiaStatus],
	[TransferType],
	[AcquisitionDate],
	[ResponseDate]
FROM [Account].[RunningReserve]
WHERE 1=1
  AND ((@ParamEmployerID IS NULL OR @ParamEmployerID = [EmployerID]))
  AND [Component] = @Component_PREDECESSOR
  AND [Quarter]   = 0
OPTION (RECOMPILE)

CREATE TABLE #DeleteePredNotValid ([RunningReserveID] UNIQUEIDENTIFIER)

SET @StepStart = SYSDATETIME()

INSERT INTO #DeleteePredNotValid
SELECT 
	TT.[RunningReserveID] 
FROM      [Account].[RunningReserve]  AS TT
LEFT JOIN [Account].[RunningReserve]  AS TTPred ON TTPred.[EmployerID] = TT.[EmployerID] AND TTPred.[Component] = @Component_PREDECESSOR
WHERE 1=1
  AND TT.[Component]             != @Component_PREDECESSOR
  AND TT.[PredecessorEmployerID] IS NOT NULL 
  AND TTPred.[RunningReserveID]  IS NULL
  AND ((@ParamEmployerID IS NULL OR @ParamEmployerID = TT.[EmployerID]))

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('INSERT #DeleteePredNotValid: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

SET @StepStart = SYSDATETIME()

DELETE TT FROM [Account].[RunningReserve] AS TT JOIN #DeleteePredNotValid AS XX ON XX.[RunningReserveID] = TT.[RunningReserveID]

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('DELETE predecessor not valid: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Payments =================================================

SET @Component_Type = @Component_PAYMENT
SET @StepStart      = SYSDATETIME()

DROP TABLE IF EXISTS #RunningReserveCalcPayments;

WITH Alloc AS (
    SELECT
         ttRcpt.[EmployerID]
        ,ttTaxQtrRcv.[Year]
        ,ttAllocRcv.[Amount]
        ,ttRcptAlloc.[CreatedDate]  AS [AllocCreated]
        ,ttRcptAlloc.[ModifiedDate] AS [AllocModified]
        ,DENSE_RANK() OVER (PARTITION BY ttRcpt.[ReceiptID]
                            ORDER BY ttRcptRqst.[CreatedDate]  DESC, ttRcptRqst.[ReceiptRequestID]     DESC,
                                     ttRcptAlloc.[CreatedDate] DESC, ttRcptAlloc.[ReceiptAllocationID] DESC) AS [RcptAllocRank]
    FROM       [dbo].[Receipt]                     AS ttRcpt
    INNER JOIN [dbo].[ReceiptRequest]              AS ttRcptRqst  ON ttRcptRqst.[ReceiptID]           = ttRcpt.[ReceiptID]
    INNER JOIN [dbo].[ReceiptAllocation]           AS ttRcptAlloc ON ttRcptAlloc.[ReceiptRequestID]   = ttRcptRqst.[ReceiptRequestID]
    INNER JOIN [dbo].[ReceiptAllocationReceivable] AS ttAllocRcv  ON ttAllocRcv.[ReceiptAllocationID] = ttRcptAlloc.[ReceiptAllocationID]
    INNER JOIN [Account].[Receivable]              AS ttRcv       ON ttRcv.[ReceivableID]             = ttAllocRcv.[ReceivableID]
    INNER JOIN [Configuration].[ReceivableType]    AS ttRcvTyp    ON ttRcvTyp.[ReceivableTypeID]      = ttRcv.[ReceivableTypeID]
    LEFT  JOIN [Account].[TaxQuarter]              AS ttTaxQtrRcv ON ttTaxQtrRcv.[TaxQuarterID]       = ttRcv.[TaxQuarterID]
    WHERE ttRcpt.[EmployerID]  = @ParamEmployerID          -- sargable; NULL already handled by the early RETURN
      AND ttAllocRcv.[Amount] >= 0.00
      AND ttRcvTyp.[Code] IN ('TAXCOMPUTED', 'TAXSHAREDCOST', 'TAXOTHERSTATE')
)
SELECT
     CAST(@Component_Type AS VARCHAR(50))  AS [Component]
    ,0                                     AS [Quarter]
    ,CAST(NULL AS INT)                     AS [PredecessorEmployerID]
    ,CAST(NULL AS VARCHAR(100))            AS [PredLiaStatus]
    ,CAST(NULL AS INT)                     AS [SuccessorEmployerID]
    ,CAST(NULL AS VARCHAR(100))            AS [SuccLiaStatus]
    ,CAST(NULL AS VARCHAR(100))            AS [TransferType]
    ,CAST(NULL AS DATE)                    AS [AcquisitionDate]
    ,CAST(NULL AS DATE)                    AS [ResponseDate]
    ,[EmployerID]
    ,[Year]
    ,SUM([Amount])                         AS [TaxesPaidRcv]          -- Amount >= 0 so never NULL
    ,MAX([AllocCreated])                   AS [MaxRcptAllocCreated]
    ,MAX([AllocModified])                  AS [MaxRcptAllocModified]
    ,CAST(0 AS MONEY)                      AS [BenefitsChargedClient]
    ,CAST(0 AS MONEY)                      AS [BenefitsRelievedClient]
    ,CAST(NULL AS DATETIME)                AS [MaxChargeStatementChargeCreated]
INTO #RunningReserveCalcPayments
FROM Alloc
WHERE [RcptAllocRank] = 1
  AND [Year] IS NOT NULL                   -- same as the outer filter: applied after ranking
GROUP BY [EmployerID], [Year]
OPTION (RECOMPILE);                        -- employer sizes vary widely; plan per call

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('Build ', @Component_Type, ': ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- ======

SET @Component_Type = @Component_PAYMENT
SET @StepStart      = SYSDATETIME()

SET @Component_Type = @Component_PAYMENT
SET @StepStart      = SYSDATETIME()

;WITH Target_Payment AS (
    SELECT *
    FROM [Account].[RunningReserve]
    WHERE [EmployerID] = @ParamEmployerID      -- NULL already handled by the early RETURN
      AND [Component]  = @Component_Type
      AND [Quarter]    = 0
)
MERGE INTO Target_Payment AS Target
USING #RunningReserveCalcPayments AS Source
ON Target.[Component]             = Source.[Component]             AND 
   Target.[EmployerID]            = Source.[EmployerID]            AND 
   Target.[Year]                  = Source.[Year]                  AND
   Target.[Quarter]               = Source.[Quarter]               AND
   (Target.[PredecessorEmployerID] = Source.[PredecessorEmployerID]
    OR (Target.[PredecessorEmployerID] IS NULL AND Source.[PredecessorEmployerID] IS NULL)) AND
   (Target.[SuccessorEmployerID]   = Source.[SuccessorEmployerID]
    OR (Target.[SuccessorEmployerID]   IS NULL AND Source.[SuccessorEmployerID]   IS NULL))
-- If a match is found, update the existing row
WHEN MATCHED 
 AND (Target.[TaxesPaidRcv]                    != Source.[TaxesPaidRcv]                    OR
      Target.[MaxRcptAllocCreated]             != Source.[MaxRcptAllocCreated]             OR
      Target.[MaxRcptAllocModified]            != Source.[MaxRcptAllocModified]            OR

      Target.[BenefitsChargedClient]           != Source.[BenefitsChargedClient]           OR
      Target.[BenefitsRelievedClient]          != Source.[BenefitsRelievedClient]          OR
      Target.[MaxChargeStatementChargeCreated] != Source.[MaxChargeStatementChargeCreated] OR

      Target.[PredLiaStatus]                   != Source.[PredLiaStatus]                   OR
      Target.[SuccLiaStatus]                   != Source.[SuccLiaStatus]                   OR

      Target.[TransferType]                    != Source.[TransferType]                    OR
      Target.[AcquisitionDate]                 != Source.[AcquisitionDate]                 OR
      Target.[ResponseDate]                    != Source.[ResponseDate])
THEN
    UPDATE SET
        Target.[TaxesPaidRcv]                    = Source.[TaxesPaidRcv],
        Target.[MaxRcptAllocCreated]             = Source.[MaxRcptAllocCreated],
        Target.[MaxRcptAllocModified]            = Source.[MaxRcptAllocModified],

        Target.[BenefitsChargedClient]           = Source.[BenefitsChargedClient],
        Target.[BenefitsRelievedClient]          = Source.[BenefitsRelievedClient],
        Target.[MaxChargeStatementChargeCreated] = Source.[MaxChargeStatementChargeCreated],

        Target.[Adjustment]                      = 0.00,
        Target.[AdjustmentUtcDate]               = NULL,

        Target.[PredLiaStatus]                   = Source.[PredLiaStatus],
        Target.[SuccLiaStatus]                   = Source.[SuccLiaStatus],

        Target.[TransferType]                    = Source.[TransferType],
        Target.[AcquisitionDate]                 = Source.[AcquisitionDate],
        Target.[ResponseDate]                    = Source.[ResponseDate],

        Target.[ModifiedDate]                    = GETUTCDATE(),
        Target.[ModifiedBy]                      = @CurrentUser
-- If no match is found, insert new data
WHEN NOT MATCHED THEN 
    INSERT (
        [Component],
        [EmployerID],
        [Year],
        [Quarter],

        [TaxesPaidRcv],
        [MaxRcptAllocCreated],
        [MaxRcptAllocModified],

        [BenefitsChargedClient],
        [BenefitsRelievedClient],
        [MaxChargeStatementChargeCreated],

        [Adjustment],
        [AdjustmentUtcDate],
        
		[PredecessorEmployerID],
		[PredLiaStatus],
        [SuccessorEmployerID],
        [SuccLiaStatus],

		[TransferType],
        [AcquisitionDate],
        [ResponseDate],

        [CreatedDate],
        [CreatedBy],
        [ModifiedDate],
        [ModifiedBy]
    )
    VALUES (
        Source.[Component],
        Source.[EmployerID],
        Source.[Year],
        Source.[Quarter],
        Source.[TaxesPaidRcv],
        Source.[MaxRcptAllocCreated],
        Source.[MaxRcptAllocModified],
        Source.[BenefitsChargedClient],
        Source.[BenefitsRelievedClient],
        Source.[MaxChargeStatementChargeCreated],

        0.00, -- AS [Adjustment]
        NULL, -- AS [AdjustmentUtcDate]

        Source.[PredecessorEmployerID], -- NULL
        Source.[PredLiaStatus],         -- NULL
        Source.[SuccessorEmployerID],   -- NULL
        Source.[SuccLiaStatus],         -- NULL

        Source.[TransferType],
        Source.[AcquisitionDate],
        Source.[ResponseDate],

        GETUTCDATE(),  -- AS 'CreatedDate'
        @CurrentUser,  -- AS 'CreatedBy'
        GETUTCDATE(),  -- AS 'ModifiedDate'
        @CurrentUser   -- AS 'ModifiedBy'

    )
-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE 
 --------AND ((@ParamEmployerID IS NULL OR target.[EmployerID] IN (SELECT [EmployerID] FROM @Employers)))
 AND (@ParamEmployerID IS NULL OR @ParamEmployerID = target.[EmployerId]) 
 AND (@Component_Type  = target.[Component])
 AND (target.[Quarter] = 0)
THEN
    DELETE
 -- MAXDOP 1: Force single-threaded execution
 OPTION (MAXDOP 1, RECOMPILE);  -- RECOMPILE: plan built for this employer's actual row counts

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE ', @Component_Type, ': ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- BENEFITCHARGE =================================================

SET @Component_Type = @Component_BENEFITCHARGE
SET @StepStart      = SYSDATETIME()

MERGE INTO [Account].[RunningReserve] AS Target
USING (
SELECT 
    @Component_Type           AS [Component]
    ,ttChgStmnt.[EmployerID]  AS [EmployerID]
    ,ttChgStmnt.[Year]        AS [Year]
    ,0                        AS [Quarter]

    ,NULL                     AS [PredecessorEmployerID]
    ,NULL                     AS [PredLiaStatus]
    ,NULL                     AS [SuccessorEmployerID]
    ,NULL                     AS [SuccLiaStatus]

	,NULL                     AS [TransferType]  
	,NULL                     AS [AcquisitionDate]
	,NULL                     AS [ResponseDate]

    ,0.00  AS [TaxesPaidRcv]
    ,NULL  AS [MaxRcptAllocCreated]
    ,NULL  AS [MaxRcptAllocModified]

    ,SUM(ISNULL(ttChgStmntChg.[BenefitsCharged],  0.00)) AS [BenefitsChargedClient]
    ,SUM(ISNULL(ttChgStmntChg.[BenefitsRelieved], 0.00)) AS [BenefitsRelievedClient]
    ,MAX(ttChgStmntChg.[CreatedDate])                    AS [MaxChargeStatementChargeCreated]

FROM [Account].[ChargeStatement]                              AS ttChgStmnt

  ------LEFT JOIN @Employers                                        AS ttEmployers ON ttEmployers.[EmployerID] = ttChgStmnt.[EmployerID]

  LEFT JOIN [Account].[ChargeStatementChargeStatementCharge]  AS ttChgStmntChgStmntChg ON ttChgStmntChgStmntChg.[ChargeStatementID] = ttChgStmnt.[ChargeStatementID]
  LEFT JOIN [Account].[ChargeStatementCharge]                 AS ttChgStmntChg         ON ttChgStmntChg.[ChargeStatementChargeID]   = ttChgStmntChgStmntChg.[ChargeStatementChargeID]

WHERE 1=1 
  AND ttChgStmnt.[IsEnabled] = 1
  ------AND ((@ParamEmployerID IS NULL OR ttEmployers.[EmployerID] = ttChgStmnt.[EmployerID]))
  AND ((@ParamEmployerID IS NULL OR @ParamEmployerID = ttChgStmnt.[EmployerID]))
  AND (ttChgStmnt.[BenefitsCharged] != 0.00 OR ttChgStmnt.[BenefitsRelieved] != 0.00)
GROUP BY
     ttChgStmnt.[EmployerID]
    ,ttChgStmnt.[Year]
HAVING 1=1
  AND (SUM(ISNULL(ttChgStmntChg.[BenefitsCharged],  0.00))  != 0.00 OR 
       SUM(ISNULL(ttChgStmntChg.[BenefitsRelieved],  0.00)) != 0.00)
  
) AS Source
ON Target.[Component]             = Source.[Component]             AND 
   Target.[EmployerID]            = Source.[EmployerID]            AND 
   Target.[Year]                  = Source.[Year]                  AND
   Target.[Quarter]               = Source.[Quarter]               AND
   Target.[PredecessorEmployerID] = Source.[PredecessorEmployerID] AND 
   Target.[SuccessorEmployerID]   = Source.[SuccessorEmployerID]
-- If a match is found, update the existing row
WHEN MATCHED 
 AND (Target.[TaxesPaidRcv]                    != Source.[TaxesPaidRcv]                    OR
      Target.[MaxRcptAllocCreated]             != Source.[MaxRcptAllocCreated]             OR
      Target.[MaxRcptAllocModified]            != Source.[MaxRcptAllocModified]            OR

      Target.[BenefitsChargedClient]           != Source.[BenefitsChargedClient]           OR
      Target.[BenefitsRelievedClient]          != Source.[BenefitsRelievedClient]          OR
      Target.[MaxChargeStatementChargeCreated] != Source.[MaxChargeStatementChargeCreated] OR

      Target.[PredLiaStatus]                   != Source.[PredLiaStatus]                   OR
      Target.[SuccLiaStatus]                   != Source.[SuccLiaStatus]                   OR

      Target.[TransferType]                    != Source.[TransferType]                    OR
      Target.[AcquisitionDate]                 != Source.[AcquisitionDate]                 OR
      Target.[ResponseDate]                    != Source.[ResponseDate])
THEN
    UPDATE SET
        Target.[TaxesPaidRcv]                    = Source.[TaxesPaidRcv],
        Target.[MaxRcptAllocCreated]             = Source.[MaxRcptAllocCreated],
        Target.[MaxRcptAllocModified]            = Source.[MaxRcptAllocModified],

        Target.[BenefitsChargedClient]           = Source.[BenefitsChargedClient],
        Target.[BenefitsRelievedClient]          = Source.[BenefitsRelievedClient],
        Target.[MaxChargeStatementChargeCreated] = Source.[MaxChargeStatementChargeCreated],

        Target.[Adjustment]                      = 0.00,
        Target.[AdjustmentUtcDate]               = NULL,

        Target.[PredLiaStatus]                   = Source.[PredLiaStatus],
        Target.[SuccLiaStatus]                   = Source.[SuccLiaStatus],

        Target.[TransferType]                    = Source.[TransferType],
        Target.[AcquisitionDate]                 = Source.[AcquisitionDate],
        Target.[ResponseDate]                    = Source.[ResponseDate],

        Target.[ModifiedDate]                    = GETUTCDATE(),
        Target.[ModifiedBy]                      = @CurrentUser
-- If no match is found, insert new data
WHEN NOT MATCHED THEN 
    INSERT (
        [Component],
        [EmployerID],
        [Year],
        [Quarter],

        [TaxesPaidRcv],
        [MaxRcptAllocCreated],
        [MaxRcptAllocModified],

        [BenefitsChargedClient],
        [BenefitsRelievedClient],
        [MaxChargeStatementChargeCreated],

        [Adjustment],
        [AdjustmentUtcDate],

        [PredecessorEmployerID],
        [PredLiaStatus],
        [SuccessorEmployerID],
        [SuccLiaStatus],

        [TransferType],
        [AcquisitionDate],
        [ResponseDate],

        [CreatedDate],
        [CreatedBy],
        [ModifiedDate],
        [ModifiedBy]
    )
    VALUES (
        Source.[Component],
        Source.[EmployerID],
        Source.[Year],
        0, -- AS Source.[Quarter],
        Source.[TaxesPaidRcv],
        Source.[MaxRcptAllocCreated],
        Source.[MaxRcptAllocModified],
        Source.[BenefitsChargedClient],
        Source.[BenefitsRelievedClient],
        Source.[MaxChargeStatementChargeCreated],

        0.00, -- AS [Adjustment]
        NULL, -- AS [AdjustmentUtcDate]

        Source.[PredecessorEmployerID], -- NULL
        Source.[PredLiaStatus],         -- NULL
        Source.[SuccessorEmployerID],   -- NULL
        Source.[SuccLiaStatus],         -- NULL

        Source.[TransferType],
        Source.[AcquisitionDate],
        Source.[ResponseDate],

        GETUTCDATE(),  -- AS 'CreatedDate'
        @CurrentUser,  -- AS 'CreatedBy'
        GETUTCDATE(),  -- AS 'ModifiedDate'
        @CurrentUser   -- AS 'ModifiedBy'

    )
-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE 
 ------AND ((@ParamEmployerID IS NULL OR target.[EmployerID] IN (SELECT [EmployerID] FROM @Employers)))
 AND (@ParamEmployerID IS NULL OR @ParamEmployerID = target.[EmployerId])
 AND (@Component_Type  = target.[Component])
 AND (target.[Quarter] = 0)
THEN
    DELETE
 -- MAXDOP 1: Force single-threaded execution
 OPTION (MAXDOP 1);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE ', @Component_Type, ': ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- Payments PREDECESSOR ==========================================

SET @Component_Type = @Component_PAYMENT_PREDECESSOR
SET @StepStart      = SYSDATETIME()

MERGE INTO [Account].[RunningReserve] AS Target
USING (
    SELECT DISTINCT
        @Component_Type AS [Component]
        ,ttPayments.*
		,0             AS [Quarter] 
    FROM (
    SELECT 
         CTE_TaxesPaid.[EmployerID] 
        ,CTE_TaxesPaid.[Year]

        ,CTE_TaxesPaid.[PredecessorEmployerID]
        ,CTE_TaxesPaid.[PredLiaStatus]
        ,CTE_TaxesPaid.[SuccessorEmployerID]
        ,CTE_TaxesPaid.[SuccLiaStatus]

        ,CTE_TaxesPaid.[TransferType]
        ,CTE_TaxesPaid.[AcquisitionDate]
        ,CTE_TaxesPaid.[ResponseDate]

        ,SUM(ISNULL(CTE_TaxesPaid.[TaxesPaidRcv],    0.00)) AS [TaxesPaidRcv]

        ,MAX(CTE_TaxesPaid.[MaxRcptAllocCreated])           AS [MaxRcptAllocCreated]
        ,MAX(CTE_TaxesPaid.[MaxRcptAllocModified])          AS [MaxRcptAllocModified]

        ,0.00 AS [BenefitsChargedClient]
        ,0.00 AS [BenefitsRelievedClient]
        ,NULL AS [MaxChargeStatementChargeCreated]

    FROM (
    -- PAYMENTS
    SELECT 
         TTDATA.[EmployerID]
        ,TTDATA.[PredecessorEmployerID]
        ,TTDATA.[PredLiaStatus]
        ,TTDATA.[SuccessorEmployerID]
        ,TTDATA.[SuccLiaStatus]
        ,TTDATA.[TransferType]
        ,TTDATA.[AcquisitionDate]
        ,TTDATA.[ResponseDate]

        ,TTDATA.[EffectiveDate]

        ,TTDATA.[DepositDate] ---------------- AS [EffectiveDate]
    
        ,ISNULL(TTDATA.[TaxesPaidRcv],    0.00) AS [TaxesPaidRcv]

        -- Tax Quarter Year/Quarter
        ,TTDATA.[Year]
        ,TTDATA.[Quarter]

        ,TTDATA.[MaxRcptAllocCreated]
        ,TTDATA.[MaxRcptAllocModified]

        ,TTDATA.[RcptRqstRank]
        ,TTDATA.[RcptAllocRank]
    FROM (
    SELECT

         ttEmployers_PRED.[EmployerID]
        ,ttEmployers_PRED.[PredecessorEmployerID]
        ,ttEmployers_PRED.[PredLiaStatus]
        ,ttEmployers_PRED.[SuccessorEmployerID]
        ,ttEmployers_PRED.[SuccLiaStatus]
        ,ttEmployers_PRED.[TransferType]
        ,ttEmployers_PRED.[AcquisitionDate]
        ,ttEmployers_PRED.[ResponseDate]

        ,CAST((SELECT TOP 1 xxRcptEff.[EffectiveDate] 
                          FROM [dbo].[ReceiptEffective] AS xxRcptEff 
                          WHERE xxRcptEff.[ReceiptID] = ttRcpt.[ReceiptID] 
                          ORDER BY xxRcptEff.[CreatedDate]) AS DATE) as [EffectiveDate]

        ,ttRcpt.[DepositDate] ---------------- AS [EffectiveDate]
    
        ,ISNULL(ttAllocRcv.[Amount], 0.00)   AS [TaxesPaidRcv]

        ,ttTaxQtrRcv.[Year]         AS [Year]
        ,ttTaxQtrRcv.[Quarter]      AS [Quarter]

        ,ttRcptAlloc.[CreatedDate]  AS [MaxRcptAllocCreated]
        ,ttRcptAlloc.[ModifiedDate] AS [MaxRcptAllocModified]


        ,DENSE_RANK() OVER (PARTITION BY ttRcpt.[ReceiptID]
                            ORDER BY 
                                ttRcpt.[ReceiptID]       DESC, ttRcpt.[CreatedDate]          DESC,
                                ttRcptRqst.[CreatedDate] DESC, ttRcptRqst.[ReceiptRequestID] DESC) AS [RcptRqstRank]

        ,DENSE_RANK() OVER (PARTITION BY ttRcpt.[ReceiptID]
                            ORDER BY 
                                ttRcpt.[ReceiptID]        DESC, ttRcpt.[CreatedDate]              DESC,
                                ttRcptRqst.[CreatedDate]  DESC, ttRcptRqst.[ReceiptRequestID]     DESC,
                                ttRcptAlloc.[CreatedDate] DESC, ttRcptAlloc.[ReceiptAllocationID] DESC) AS [RcptAllocRank]

    FROM [dbo].[ReceiptAllocation]          AS ttRcptAlloc
        INNER JOIN [dbo].[ReceiptRequest]   AS ttRcptRqst    ON ttRcptRqst.[ReceiptRequestID] = ttRcptAlloc.[ReceiptRequestID] 
        INNER JOIN [dbo].[Receipt]          AS ttRcpt        ON ttRcpt.[ReceiptID]            = ttRcptRqst.[ReceiptID] 

        INNER JOIN #Employers_PREDECESSORS   AS ttEmployers_PRED ON ttEmployers_PRED.[PredecessorEmployerID] = ttRcpt.[EmployerID]

        -- PAID
        LEFT JOIN [dbo].[ReceiptAllocationReceivable] AS ttAllocRcv  ON ttAllocRcv.[ReceiptAllocationID] = ttRcptAlloc.[ReceiptAllocationID] 
        LEFT JOIN [Account].[Receivable]              AS ttRcv       ON ttRcv.[ReceivableID]             = ttAllocRcv.[ReceivableID] 

        LEFT JOIN [Account].[TaxQuarter]              AS ttTaxQtrRcv ON ttTaxQtrRcv.[TaxQuarterID]       = ttRcv.[TaxQuarterID] 

        LEFT JOIN [Configuration].[ReceivableType]    AS ttRcvTyp    ON ttRcvTyp.[ReceivableTypeID]      = ttRcv.[ReceivableTypeID]

    WHERE 1=1
      AND ttAllocRcv.[Amount] >= 0.00
      AND ttRcvTyp.[Code] IN ('TAXCOMPUTED', 'TAXSHAREDCOST', 'TAXOTHERSTATE')

    ) AS TTDATA
    WHERE 1=1
      AND TTDATA.[RcptRqstRank]  = 1 
      AND TTDATA.[RcptAllocRank] = 1

    ) AS CTE_TaxesPaid
    GROUP BY 
         CTE_TaxesPaid.[EmployerID]
        ,CTE_TaxesPaid.[Year]
        ,CTE_TaxesPaid.[PredecessorEmployerID]
        ,CTE_TaxesPaid.[PredLiaStatus]
        ,CTE_TaxesPaid.[SuccessorEmployerID]
        ,CTE_TaxesPaid.[SuccLiaStatus]
        ,CTE_TaxesPaid.[TransferType]
        ,CTE_TaxesPaid.[AcquisitionDate]
        ,CTE_TaxesPaid.[ResponseDate]
    ) AS ttPayments
    WHERE 1=1
      AND [EmployerID]    IS NOT NULL 
      AND [YEAR]          IS NOT NULL 
) AS Source
ON Target.[Component]             = Source.[Component]             AND 
   Target.[EmployerID]            = Source.[EmployerID]            AND 
   Target.[Year]                  = Source.[Year]                  AND
   Target.[Quarter]               = Source.[Quarter]               AND
   Target.[PredecessorEmployerID] = Source.[PredecessorEmployerID] AND 
   Target.[SuccessorEmployerID]   = Source.[SuccessorEmployerID]

-- If a match is found, update the existing row
WHEN MATCHED 
 AND (Target.[TaxesPaidRcv]                    != Source.[TaxesPaidRcv]                    OR
      Target.[MaxRcptAllocCreated]             != Source.[MaxRcptAllocCreated]             OR
      Target.[MaxRcptAllocModified]            != Source.[MaxRcptAllocModified]            OR

      Target.[BenefitsChargedClient]           != Source.[BenefitsChargedClient]           OR
      Target.[BenefitsRelievedClient]          != Source.[BenefitsRelievedClient]          OR
      Target.[MaxChargeStatementChargeCreated] != Source.[MaxChargeStatementChargeCreated] OR

      Target.[PredLiaStatus]                   != Source.[PredLiaStatus]                   OR
      Target.[SuccLiaStatus]                   != Source.[SuccLiaStatus]                   OR

      Target.[TransferType]                    != Source.[TransferType]                    OR
      Target.[AcquisitionDate]                 != Source.[AcquisitionDate]                 OR
      Target.[ResponseDate]                    != Source.[ResponseDate] 
)
THEN
    UPDATE SET
        Target.[TaxesPaidRcv]                    = Source.[TaxesPaidRcv],
        Target.[MaxRcptAllocCreated]             = Source.[MaxRcptAllocCreated],
        Target.[MaxRcptAllocModified]            = Source.[MaxRcptAllocModified],

        Target.[BenefitsChargedClient]           = Source.[BenefitsChargedClient],
        Target.[BenefitsRelievedClient]          = Source.[BenefitsRelievedClient],
        Target.[MaxChargeStatementChargeCreated] = Source.[MaxChargeStatementChargeCreated],

        Target.[Adjustment]                      = 0.00,
        Target.[AdjustmentUtcDate]               = NULL,

        Target.[PredLiaStatus]                   = Source.[PredLiaStatus],
        Target.[SuccLiaStatus]                   = Source.[SuccLiaStatus],

        Target.[TransferType]                    = Source.[TransferType],
        Target.[AcquisitionDate]                 = Source.[AcquisitionDate],
        Target.[ResponseDate]                    = Source.[ResponseDate],

        Target.[ModifiedDate]                    = GETUTCDATE(),
        Target.[ModifiedBy]                      = @CurrentUser
-- If no match is found, insert new data
WHEN NOT MATCHED THEN 
    INSERT (
        [Component],
        [EmployerID],
        [Year],
        [Quarter],

        [TaxesPaidRcv],
        [MaxRcptAllocCreated],
        [MaxRcptAllocModified],

        [BenefitsChargedClient],
        [BenefitsRelievedClient],
        [MaxChargeStatementChargeCreated],

        [Adjustment],
        [AdjustmentUtcDate],

        [PredecessorEmployerID],
		[PredLiaStatus],
        [SuccessorEmployerID],
		[SuccLiaStatus],

        [TransferType],
        [AcquisitionDate],
        [ResponseDate],

        [CreatedDate],
        [CreatedBy],
        [ModifiedDate],
        [ModifiedBy]
    )
    VALUES (
        Source.[Component],
        Source.[EmployerID],
        Source.[Year],
        Source.[Quarter],
        Source.[TaxesPaidRcv],
        Source.[MaxRcptAllocCreated],
        Source.[MaxRcptAllocModified],
        Source.[BenefitsChargedClient],
        Source.[BenefitsRelievedClient],
        Source.[MaxChargeStatementChargeCreated],

        0.00, -- AS [Adjustment]
        NULL, -- AS [AdjustmentUtcDate]

        Source.[PredecessorEmployerID], 
        Source.[PredLiaStatus],
        Source.[SuccessorEmployerID], 
        Source.[SuccLiaStatus],

        Source.[TransferType],
        Source.[AcquisitionDate],
        Source.[ResponseDate],

        GETUTCDATE(),  -- AS 'CreatedDate'
        @CurrentUser,  -- AS 'CreatedBy'
        GETUTCDATE(),  -- AS 'ModifiedDate'
        @CurrentUser   -- AS 'ModifiedBy'

    )
-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE 
 AND (@ParamEmployerID IS NULL OR target.[EmployerId] IN (SELECT [PredecessorEmployerID] FROM #Employers_PREDECESSORS)) 
 AND (@Component_Type  = target.[Component])
 AND (target.[Quarter] = 0)
THEN
    DELETE
 -- MAXDOP 1: Force single-threaded execution
 OPTION (MAXDOP 1);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE ', @Component_Type, ': ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- BENEFITCHARGE PREDECESSOR =====================================

SET @Component_Type = @Component_BENEFITCHARGE_PREDECESSOR
SET @StepStart      = SYSDATETIME()

MERGE INTO [Account].[RunningReserve] AS Target
USING (
SELECT 
    @Component_Type                           AS [Component]
    ,ttEmployers_PRED.[EmployerID]            AS [EmployerID]
    ,ttChgStmnt.[Year]                        AS [Year]
    ,0                                        AS [Quarter]

    ,ttEmployers_PRED.[PredecessorEmployerID] AS [PredecessorEmployerID]
    ,ttEmployers_PRED.[PredLiaStatus]         AS [PredLiaStatus]
    ,ttEmployers_PRED.[SuccessorEmployerID]   AS [SuccessorEmployerID]
    ,ttEmployers_PRED.[SuccLiaStatus]         AS [SuccLiaStatus]

    ,ttEmployers_PRED.[TransferType]          AS [TransferType]
    ,ttEmployers_PRED.[AcquisitionDate]       AS [AcquisitionDate]
    ,ttEmployers_PRED.[ResponseDate]          AS [ResponseDate]


    ,0.00  AS [TaxesPaidRcv]
    ,NULL  AS [MaxRcptAllocCreated]
    ,NULL  AS [MaxRcptAllocModified]

    ,SUM(ISNULL(ttChgStmntChg.[BenefitsCharged],  0.00)) AS [BenefitsChargedClient]
    ,SUM(ISNULL(ttChgStmntChg.[BenefitsRelieved], 0.00)) AS [BenefitsRelievedClient]
    ,MAX(ttChgStmntChg.[CreatedDate])                    AS [MaxChargeStatementChargeCreated]

FROM [Account].[ChargeStatement]                              AS ttChgStmnt
  INNER JOIN #Employers_PREDECESSORS                          AS ttEmployers_PRED      ON ttEmployers_PRED.[PredecessorEmployerID] = ttChgStmnt.[EmployerID]
  LEFT  JOIN [Account].[ChargeStatementChargeStatementCharge] AS ttChgStmntChgStmntChg ON ttChgStmntChgStmntChg.[ChargeStatementID] = ttChgStmnt.[ChargeStatementID]
  LEFT  JOIN [Account].[ChargeStatementCharge]                AS ttChgStmntChg         ON ttChgStmntChg.[ChargeStatementChargeID]   = ttChgStmntChgStmntChg.[ChargeStatementChargeID]

WHERE 1=1 
  AND ttChgStmnt.[IsEnabled] = 1
  AND (ttChgStmnt.[BenefitsCharged] != 0.00 OR ttChgStmnt.[BenefitsRelieved] != 0.00)
GROUP BY
     ttEmployers_PRED.[EmployerID]
    ,ttEmployers_PRED.[PredecessorEmployerID]
    ,ttEmployers_PRED.[PredLiaStatus]
    ,ttEmployers_PRED.[SuccessorEmployerID]
    ,ttEmployers_PRED.[SuccLiaStatus]
    ,ttEmployers_PRED.[TransferType]
    ,ttEmployers_PRED.[AcquisitionDate]
    ,ttEmployers_PRED.[ResponseDate]
    ,ttChgStmnt.[Year]
HAVING 1=1
  AND (SUM(ISNULL(ttChgStmntChg.[BenefitsCharged],  0.00))  != 0.00 OR 
       SUM(ISNULL(ttChgStmntChg.[BenefitsRelieved],  0.00)) != 0.00)
) AS Source
ON Target.[Component]             = Source.[Component]             AND 
   Target.[EmployerID]            = Source.[EmployerID]            AND 
   Target.[Year]                  = Source.[Year]                  AND
   Target.[Quarter]               = Source.[Quarter]               AND
   Target.[PredecessorEmployerID] = Source.[PredecessorEmployerID] AND 
   Target.[SuccessorEmployerID]   = Source.[SuccessorEmployerID]

-- If a match is found, update the existing row
-- If a match is found, update the existing row
WHEN MATCHED 
 AND (Target.[TaxesPaidRcv]                    != Source.[TaxesPaidRcv]                    OR
      Target.[MaxRcptAllocCreated]             != Source.[MaxRcptAllocCreated]             OR
      Target.[MaxRcptAllocModified]            != Source.[MaxRcptAllocModified]            OR

      Target.[BenefitsChargedClient]           != Source.[BenefitsChargedClient]           OR
      Target.[BenefitsRelievedClient]          != Source.[BenefitsRelievedClient]          OR
      Target.[MaxChargeStatementChargeCreated] != Source.[MaxChargeStatementChargeCreated] OR

      Target.[PredLiaStatus]                   != Source.[PredLiaStatus]                   OR
      Target.[SuccLiaStatus]                   != Source.[SuccLiaStatus]                   OR

      Target.[TransferType]                    != Source.[TransferType]                    OR
      Target.[AcquisitionDate]                 != Source.[AcquisitionDate]                 OR
      Target.[ResponseDate]                    != Source.[ResponseDate] 
)

THEN
    UPDATE SET
        Target.[TaxesPaidRcv]                    = Source.[TaxesPaidRcv],
        Target.[MaxRcptAllocCreated]             = Source.[MaxRcptAllocCreated],
        Target.[MaxRcptAllocModified]            = Source.[MaxRcptAllocModified],

        Target.[BenefitsChargedClient]           = Source.[BenefitsChargedClient],
        Target.[BenefitsRelievedClient]          = Source.[BenefitsRelievedClient],
        Target.[MaxChargeStatementChargeCreated] = Source.[MaxChargeStatementChargeCreated],

        Target.[Adjustment]                      = 0.00,
        Target.[AdjustmentUtcDate]               = NULL,

        Target.[PredLiaStatus]                   = Source.[PredLiaStatus],
        Target.[SuccLiaStatus]                   = Source.[SuccLiaStatus],

        Target.[TransferType]                    = Source.[TransferType],
        Target.[AcquisitionDate]                 = Source.[AcquisitionDate],
        Target.[ResponseDate]                    = Source.[ResponseDate],

        Target.[ModifiedDate]                    = GETUTCDATE(),
        Target.[ModifiedBy]                      = @CurrentUser
-- If no match is found, insert new data
WHEN NOT MATCHED THEN 
    INSERT (
        [Component],
        [EmployerID],
        [Year],
        [Quarter],

        [TaxesPaidRcv],
        [MaxRcptAllocCreated],
        [MaxRcptAllocModified],

        [BenefitsChargedClient],
        [BenefitsRelievedClient],
        [MaxChargeStatementChargeCreated],

        [Adjustment],
        [AdjustmentUtcDate],

        [PredecessorEmployerID],
        [PredLiaStatus],
        [SuccessorEmployerID],
        [SuccLiaStatus],

        [TransferType],
        [AcquisitionDate],
        [ResponseDate],

        [CreatedDate],
        [CreatedBy],
        [ModifiedDate],
        [ModifiedBy]
    )
    VALUES (
        Source.[Component],
        Source.[EmployerID],
        Source.[Year],
        Source.[Quarter],
        Source.[TaxesPaidRcv],
        Source.[MaxRcptAllocCreated],
        Source.[MaxRcptAllocModified],
        Source.[BenefitsChargedClient],
        Source.[BenefitsRelievedClient],
        Source.[MaxChargeStatementChargeCreated],

        0.00, -- AS [Adjustment]
        NULL, -- AS [AdjustmentUtcDate]

        Source.[PredecessorEmployerID],
        Source.[PredLiaStatus],
        Source.[SuccessorEmployerID],
        Source.[SuccLiaStatus],

        Source.[TransferType],
        Source.[AcquisitionDate],
        Source.[ResponseDate],

        GETUTCDATE(),  -- AS 'CreatedDate'
        @CurrentUser,  -- AS 'CreatedBy'
        GETUTCDATE(),  -- AS 'ModifiedDate'
        @CurrentUser   -- AS 'ModifiedBy'

    )
-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE 
 AND (@ParamEmployerID IS NULL OR target.[EmployerId] IN (SELECT [PredecessorEmployerID] FROM #Employers_PREDECESSORS)) 
 AND (@Component_Type  = target.[Component])
 AND (target.[Quarter] = 0)
THEN
    DELETE
 -- MAXDOP 1: Force single-threaded execution
 OPTION (MAXDOP 1);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE ', @Component_Type, ': ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')

-- PREDECESSOR ADJUSTMENTS =====================================

SET @StepStart = SYSDATETIME()

MERGE INTO [Account].[RunningReserve] AS Target
USING (
SELECT
    --rrPred.RunningReserveID,
    rrPred.Component,
    rr.EmployerID,
    rrPred.Year,
    rrPred.Quarter,
    rrPred.TaxesPaidRcv,
    rrPred.MaxRcptAllocCreated,
    rrPred.MaxRcptAllocModified,
    rrPred.BenefitsChargedClient,
    rrPred.BenefitsRelievedClient,
    rrPred.MaxChargeStatementChargeCreated,
    rrPred.Adjustment,
    rrPred.AdjustmentUtcDate,
    rr.PredecessorEmployerID,
    rr.PredLiaStatus,
    rr.SuccessorEmployerID,
    rr.SuccLiaStatus,
    rr.TransferType,
    rr.AcquisitionDate,
    rr.ResponseDate,
    rrPred.CreatedDate,
    rrPred.CreatedBy,
    rrPred.ModifiedDate,
    rrPred.ModifiedBy

FROM       [Account].[RunningReserve] rr
INNER JOIN [Account].[RunningReserve] rrPred           on rrPred.EmployerID = rr.PredecessorEmployerID and rrPred.Component in ('PAYMENTADJUST', 'BENEFITADJUST')
INNER JOIN #Employers_PREDECESSORS AS ttEmployers_PRED ON ttEmployers_PRED.[PredecessorEmployerID] = rr.PredecessorEmployerID
WHERE 1=1 
	AND rr.Component = 'PREDECESSOR'
) AS Source
ON Target.[Component]             = Source.[Component]             AND 
   Target.[EmployerID]            = Source.[EmployerID]            AND 
   Target.[Year]                  = Source.[Year]                  AND
   Target.[Quarter]               = Source.[Quarter]               AND
   Target.[PredecessorEmployerID] = Source.[PredecessorEmployerID] AND 
   Target.[SuccessorEmployerID]   = Source.[SuccessorEmployerID]

-- If a match is found, update the existing row
-- If a match is found, update the existing row
WHEN MATCHED 
 AND (Target.[TaxesPaidRcv]                    != Source.[TaxesPaidRcv]                    OR
      Target.[MaxRcptAllocCreated]             != Source.[MaxRcptAllocCreated]             OR
      Target.[MaxRcptAllocModified]            != Source.[MaxRcptAllocModified]            OR

      Target.[BenefitsChargedClient]           != Source.[BenefitsChargedClient]           OR
      Target.[BenefitsRelievedClient]          != Source.[BenefitsRelievedClient]          OR
      Target.[MaxChargeStatementChargeCreated] != Source.[MaxChargeStatementChargeCreated] OR

      Target.[Adjustment]                      != Source.[Adjustment]                      OR
      Target.[AdjustmentUtcDate]               != Source.[AdjustmentUtcDate]               OR

      Target.[PredLiaStatus]                   != Source.[PredLiaStatus]                   OR
      Target.[SuccLiaStatus]                   != Source.[SuccLiaStatus]                   OR

      Target.[TransferType]                    != Source.[TransferType]                    OR
      Target.[AcquisitionDate]                 != Source.[AcquisitionDate]                 OR
      Target.[ResponseDate]                    != Source.[ResponseDate] 
)

THEN
    UPDATE SET
        Target.[TaxesPaidRcv]                    = Source.[TaxesPaidRcv],
        Target.[MaxRcptAllocCreated]             = Source.[MaxRcptAllocCreated],
        Target.[MaxRcptAllocModified]            = Source.[MaxRcptAllocModified],

        Target.[BenefitsChargedClient]           = Source.[BenefitsChargedClient],
        Target.[BenefitsRelievedClient]          = Source.[BenefitsRelievedClient],
        Target.[MaxChargeStatementChargeCreated] = Source.[MaxChargeStatementChargeCreated],

        Target.[Adjustment]                      = Source.[Adjustment],
        Target.[AdjustmentUtcDate]               = Source.[AdjustmentUtcDate],

        Target.[PredLiaStatus]                   = Source.[PredLiaStatus],
        Target.[SuccLiaStatus]                   = Source.[SuccLiaStatus],

        Target.[TransferType]                    = Source.[TransferType],
        Target.[AcquisitionDate]                 = Source.[AcquisitionDate],
        Target.[ResponseDate]                    = Source.[ResponseDate],

        Target.[ModifiedDate]                    = GETUTCDATE(),
        Target.[ModifiedBy]                      = @CurrentUser
-- If no match is found, insert new data
WHEN NOT MATCHED THEN 
    INSERT (
        [Component],
        [EmployerID],
        [Year],
        [Quarter],

        [TaxesPaidRcv],
        [MaxRcptAllocCreated],
        [MaxRcptAllocModified],

        [BenefitsChargedClient],
        [BenefitsRelievedClient],
        [MaxChargeStatementChargeCreated],

        [Adjustment],
        [AdjustmentUtcDate],

        [PredecessorEmployerID],
        [PredLiaStatus],
        [SuccessorEmployerID],
        [SuccLiaStatus],

        [TransferType],
        [AcquisitionDate],
        [ResponseDate],

        [CreatedDate],
        [CreatedBy],
        [ModifiedDate],
        [ModifiedBy]
    )
    VALUES (
        Source.[Component],
        Source.[EmployerID],
        Source.[Year],
        Source.[Quarter],
        Source.[TaxesPaidRcv],
        Source.[MaxRcptAllocCreated],
        Source.[MaxRcptAllocModified],
        Source.[BenefitsChargedClient],
        Source.[BenefitsRelievedClient],
        Source.[MaxChargeStatementChargeCreated],

        Source.[Adjustment],
        Source.[AdjustmentUtcDate],

        Source.[PredecessorEmployerID],
        Source.[PredLiaStatus],
        Source.[SuccessorEmployerID],
        Source.[SuccLiaStatus],

        Source.[TransferType],
        Source.[AcquisitionDate],
        Source.[ResponseDate],

        GETUTCDATE(),  -- AS 'CreatedDate'
        @CurrentUser,  -- AS 'CreatedBy'
        GETUTCDATE(),  -- AS 'ModifiedDate'
        @CurrentUser   -- AS 'ModifiedBy'

    )
-- If NO match is found, DELETE
WHEN NOT MATCHED BY SOURCE 
 AND (@ParamEmployerID IS NULL OR target.[EmployerId] IN (SELECT [PredecessorEmployerID] FROM #Employers_PREDECESSORS)) 
 AND (@Component_Type  = target.[Component])
 AND (target.[Quarter] = 0)
THEN
    DELETE
 -- MAXDOP 1: Force single-threaded execution
 OPTION (MAXDOP 1);

SET @StepRows = @@ROWCOUNT
PRINT CONCAT('MERGE PREDECESSOR ADJUSTMENTS: ', DATEDIFF(MILLISECOND, @StepStart, SYSDATETIME()), ' ms, ', @StepRows, ' rows')




END;



