/* ============================================================================
   Load the shredded hourly files produced by h02_shred.py.

   Run h02_shred.py first; it writes _hourly.txt (2.13 M rows), _hourly_meta.txt
   and _hourly_units.txt next to the JSON, and validates as it goes that every
   parallel array is the same length, contains no nulls, and reports the units
   this schema assumes.

   Idempotent: the fact is rebuilt for whichever resorts appear in the staged
   file, so re-running after adding resorts to json/hourly is safe.
   ============================================================================ */

USE SKI_RESORT;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

TRUNCATE TABLE stg.HourlyRaw;
GO

BULK INSERT stg.HourlyRaw
FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_hourly.txt'
WITH (FIELDTERMINATOR = '|', ROWTERMINATOR = '0x0a', CODEPAGE = '65001',
      TABLOCK, BATCHSIZE = 250000);
GO

/* -- file headers ---------------------------------------------------------- */

IF OBJECT_ID('tempdb..#Meta') IS NOT NULL DROP TABLE #Meta;
CREATE TABLE #Meta (ResortName nvarchar(80), FileName nvarchar(260), RangeStart date,
                    RangeEnd date, HourCount int, Timezone nvarchar(64), UtcOffsetSec int,
                    GridLatitude decimal(9,6), GridLongitude decimal(9,6), GridElevationM decimal(7,1));
BULK INSERT #Meta FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_hourly_meta.txt'
WITH (FIELDTERMINATOR = '|', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', TABLOCK);

IF OBJECT_ID('tempdb..#Units') IS NOT NULL DROP TABLE #Units;
CREATE TABLE #Units (ResortName nvarchar(80), VariableName varchar(40), UnitText nvarchar(40));
BULK INSERT #Units FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_hourly_units.txt'
WITH (FIELDTERMINATOR = '|', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', TABLOCK);

DELETE meteo.SourceFileUnit
WHERE SourceFileId IN (SELECT sf.SourceFileId FROM meteo.SourceFile sf
                       JOIN ref.Resort r ON r.ResortId = sf.ResortId
                       JOIN #Meta m ON m.ResortName = r.ResortName);
DELETE sf FROM meteo.SourceFile sf
JOIN ref.Resort r ON r.ResortId = sf.ResortId
JOIN #Meta m ON m.ResortName = r.ResortName;

/* Every staged resort must exist in ref.Resort, or the filename rule is wrong.

   Checked against #Meta -- one row per resort -- and NOT against stg.HourlyRaw.
   The same test over the fact table reads 102 million rows to prove a negative,
   and IF EXISTS gives the optimiser a row goal of 1, so it picks a nested-loop
   anti-join and rescans ref.Resort per row: 22 BILLION inner rows and 37
   minutes on the 431-resort build, for an answer that 431 rows settle
   instantly. Same guarantee, because every staged row came from a file that
   wrote exactly one #Meta row. */
IF EXISTS (SELECT 1 FROM #Meta m
           WHERE NOT EXISTS (SELECT 1 FROM ref.Resort r WHERE r.ResortName = m.ResortName))
    THROW 50040, 'Staged hourly data names a resort that is not in ref.Resort.', 1;

INSERT meteo.SourceFile (ResortId, FileName, RangeStart, RangeEnd, HourCount,
                         Timezone, UtcOffsetSec, GridLatitude, GridLongitude, GridElevationM)
SELECT r.ResortId, m.FileName, m.RangeStart, m.RangeEnd, m.HourCount,
       m.Timezone, m.UtcOffsetSec, m.GridLatitude, m.GridLongitude, m.GridElevationM
FROM #Meta m JOIN ref.Resort r ON r.ResortName = m.ResortName;

INSERT meteo.SourceFileUnit (SourceFileId, VariableName, UnitText)
-- is_day has no unit; an empty field arrives as NULL from BULK INSERT
SELECT sf.SourceFileId, u.VariableName, COALESCE(MAX(u.UnitText), '(unitless)')
FROM #Units u
JOIN ref.Resort r      ON r.ResortName = u.ResortName
JOIN meteo.SourceFile sf ON sf.ResortId = r.ResortId
GROUP BY sf.SourceFileId, u.VariableName;

-- record the grid point the request snapped to, alongside the requested point
UPDATE r SET r.GridLatitude = sf.GridLatitude,
             r.GridLongitude = sf.GridLongitude,
             r.GridElevationM = sf.GridElevationM
FROM ref.Resort r JOIN meteo.SourceFile sf ON sf.ResortId = r.ResortId;
GO

/* -- the fact -------------------------------------------------------------- */

/* ONE RESORT PER TRANSACTION, not one statement for the lot.

   At 431 resorts the staged set is 102 million rows. Inserting that in a
   single INSERT...SELECT is one transaction, and SIMPLE recovery cannot
   truncate a log mid-transaction -- so the log has to hold the entire insert
   and grows to tens of GB before it either finishes or fills the disk. Per
   resort it is 236,688 rows, the log stays flat, and a failure costs one
   resort rather than the whole load.

   The clustered index is what makes the loop affordable. stg.HourlyRaw lands
   as a heap (BULK INSERT is fastest into one), so without it each of the 431
   iterations would scan all 16 GB. Building it once costs a single sort and
   turns every iteration into a range seek. It is created here rather than in
   h01_schema.sql because a table that is bulk-loaded first and indexed after
   loads far faster than one indexed up front. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('stg.HourlyRaw') AND name = 'CIX_HourlyRaw_Resort')
    CREATE CLUSTERED INDEX CIX_HourlyRaw_Resort ON stg.HourlyRaw (ResortName, ObsHour);
GO

DECLARE @Todo TABLE (ResortName nvarchar(80) PRIMARY KEY);
INSERT @Todo (ResortName) SELECT DISTINCT ResortName FROM stg.HourlyRaw;

DECLARE @nm nvarchar(80), @done int = 0, @rows bigint = 0, @msg nvarchar(200);
DECLARE @tot int = (SELECT COUNT(*) FROM @Todo);

WHILE EXISTS (SELECT 1 FROM @Todo)
BEGIN
    SELECT TOP (1) @nm = ResortName FROM @Todo ORDER BY ResortName;

    DELETE o FROM meteo.HourlyObs o
    JOIN ref.Resort r ON r.ResortId = o.ResortId
    WHERE r.ResortName = @nm;

    INSERT meteo.HourlyObs
    (ResortId, ObsHour, TempF, ApparentF, DewPointF, RelHumidity,
     SnowfallIn, SnowDepthFt, RainIn,
     CloudTotalPct, CloudLowPct, CloudMidPct, CloudHighPct, SunshineSec,
     DirectNormalWm2, DiffuseWm2, ShortwaveWm2, TerrestrialWm2,
     DirectNormalInstWm2, DiffuseInstWm2, ShortwaveInstWm2, TerrestrialInstWm2,
     WindSpd10Mph, WindSpd100Mph, Gust10Mph, WindDir10Deg, WindDir100Deg,
     WeatherCode, IsDaylight)
SELECT r.ResortId, s.ObsHour, s.TempF, s.ApparentF, s.DewPointF, s.RelHumidity,
       s.SnowfallIn, s.SnowDepthFt, s.RainIn,
       s.CloudTotalPct, s.CloudLowPct, s.CloudMidPct, s.CloudHighPct, s.SunshineSec,
       s.DirectNormalWm2, s.DiffuseWm2, s.ShortwaveWm2, s.TerrestrialWm2,
       s.DirectNormalInstWm2, s.DiffuseInstWm2, s.ShortwaveInstWm2, s.TerrestrialInstWm2,
       s.WindSpd10Mph, s.WindSpd100Mph, s.Gust10Mph, s.WindDir10Deg,
       s.WindDir100Deg, s.WeatherCode, s.IsDaylight
    FROM stg.HourlyRaw s
    JOIN ref.Resort r ON r.ResortName = s.ResortName
    WHERE s.ResortName = @nm;

    SET @rows += @@ROWCOUNT;
    DELETE FROM @Todo WHERE ResortName = @nm;
    SET @done += 1;

    -- SIMPLE recovery reclaims the log at a checkpoint, so this is what keeps
    -- the file flat across 431 resorts instead of letting it grow all run.
    CHECKPOINT;

    IF @done % 25 = 0 OR @done = @tot
    BEGIN
        SET @msg = N'  loaded ' + CONVERT(nvarchar(10), @done) + N' of '
                 + CONVERT(nvarchar(10), @tot) + N' resorts, '
                 + CONVERT(nvarchar(20), @rows) + N' rows';
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END
END
GO

SELECT Resorts = COUNT(DISTINCT ResortId), Hours = COUNT(*),
       FirstHour = MIN(ObsHour), LastHour = MAX(ObsHour)
FROM meteo.HourlyObs;
GO
