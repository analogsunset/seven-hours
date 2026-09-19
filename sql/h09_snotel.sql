/* ============================================================================
   SNOTEL: measured snow alongside the modelled snow.

   Purpose, in order:
     1. Load the NRCS record for the resorts that have a station close enough
        and high enough to represent the ski terrain.
     2. TEST THE FRESH LINE. The model's snowfall is 4-5x low, so the whole
        design leans on the claim that a within-resort 80th percentile still
        picks the right DAYS even when the inches are wrong. SNOTEL is the
        only way to check that, because it is a measurement rather than a
        reanalysis of one.

   Water equivalent is the comparison quantity: it is conserved, and it does
   not depend on how often somebody clears a stake. Depth is loaded too but
   only read as a level (base depth), never differenced.
   ============================================================================ */

USE SKI_RESORT;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DROP TABLE IF EXISTS meteo.SnotelDaily;
DROP TABLE IF EXISTS ref.ResortSnotel;
DROP TABLE IF EXISTS stg.SnotelDailyRaw;
DROP TABLE IF EXISTS stg.SnotelMapRaw;
GO

CREATE TABLE stg.SnotelMapRaw
(
    ResortName    nvarchar(200) NULL,
    StationTriplet nvarchar(50) NULL,
    StationName   nvarchar(200) NULL,
    DistanceKm    nvarchar(50)  NULL,
    StationElevFt nvarchar(50)  NULL,
    ElevDeltaFt   nvarchar(50)  NULL,
    Qualifies     nvarchar(10)  NULL
);

CREATE TABLE stg.SnotelDailyRaw
(
    ResortName     nvarchar(200) NULL,
    StationTriplet nvarchar(50)  NULL,
    ObsDate        nvarchar(20)  NULL,
    SweIn          nvarchar(50)  NULL,   -- WTEQ, snow water equivalent
    SnowDepthIn    nvarchar(50)  NULL,   -- SNWD
    PrecipAccumIn  nvarchar(50)  NULL,   -- PREC, cumulative water year precip
    TempAvgF       nvarchar(50)  NULL    -- TAVG
);
GO

BULK INSERT stg.SnotelMapRaw
FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_snotel_map.txt'
WITH (FIELDTERMINATOR = '|', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', DATAFILETYPE = 'char', TABLOCK);

BULK INSERT stg.SnotelDailyRaw
FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_snotel_daily.txt'
WITH (FIELDTERMINATOR = '|', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', DATAFILETYPE = 'char', TABLOCK);
GO

CREATE TABLE ref.ResortSnotel
(
    ResortId       int           NOT NULL PRIMARY KEY
        REFERENCES ref.Resort (ResortId),
    StationTriplet nvarchar(50)  NOT NULL,
    StationName    nvarchar(200) NOT NULL,
    DistanceKm     decimal(7,2)  NOT NULL,
    StationElevFt  decimal(8,1)  NULL,
    ElevDeltaFt    decimal(8,1)  NULL,
    -- close enough AND near enough in elevation to stand in for mid-mountain
    Qualifies      bit           NOT NULL
);
GO

INSERT ref.ResortSnotel (ResortId, StationTriplet, StationName, DistanceKm,
                         StationElevFt, ElevDeltaFt, Qualifies)
SELECT r.ResortId, m.StationTriplet, m.StationName,
       TRY_CONVERT(decimal(7,2), m.DistanceKm),
       TRY_CONVERT(decimal(8,1), m.StationElevFt),
       TRY_CONVERT(decimal(8,1), NULLIF(m.ElevDeltaFt, '')),
       TRY_CONVERT(bit, m.Qualifies)
FROM stg.SnotelMapRaw m
JOIN ref.Resort r ON r.ResortName = m.ResortName;
GO

CREATE TABLE meteo.SnotelDaily
(
    ResortId      int          NOT NULL REFERENCES ref.Resort (ResortId),
    ObsDate       date         NOT NULL,
    SweIn         decimal(7,2) NULL,
    SnowDepthIn   decimal(7,1) NULL,
    PrecipAccumIn decimal(7,2) NULL,
    TempAvgF      decimal(6,2) NULL,
    CONSTRAINT PK_SnotelDaily PRIMARY KEY (ResortId, ObsDate)
);
GO

INSERT meteo.SnotelDaily (ResortId, ObsDate, SweIn, SnowDepthIn, PrecipAccumIn, TempAvgF)
SELECT r.ResortId,
       TRY_CONVERT(date, s.ObsDate),
       TRY_CONVERT(decimal(7,2), NULLIF(s.SweIn, '')),
       TRY_CONVERT(decimal(7,1), NULLIF(s.SnowDepthIn, '')),
       TRY_CONVERT(decimal(7,2), NULLIF(s.PrecipAccumIn, '')),
       TRY_CONVERT(decimal(6,2), NULLIF(s.TempAvgF, ''))
FROM stg.SnotelDailyRaw s
JOIN ref.Resort r ON r.ResortName = s.ResortName
WHERE TRY_CONVERT(date, s.ObsDate) IS NOT NULL;
GO

/* --------------------------------------------------------------------------
   Derived measured series.

   Swe24In  : one day's water gain, negative steps clipped to zero (melt and
              settling are not snowfall).
   Swe72In  : three of those, the measured analogue of the model's 72h window.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW meteo.vSnotelDay
AS
WITH d AS
(
    SELECT ResortId, ObsDate, SweIn, SnowDepthIn, TempAvgF,
           Swe24In = CASE WHEN SweIn IS NULL THEN NULL
                          ELSE CASE WHEN SweIn - LAG(SweIn) OVER (PARTITION BY ResortId ORDER BY ObsDate) > 0
                                    THEN SweIn - LAG(SweIn) OVER (PARTITION BY ResortId ORDER BY ObsDate)
                                    ELSE 0 END END,
           PrevDate = LAG(ObsDate) OVER (PARTITION BY ResortId ORDER BY ObsDate)
    FROM meteo.SnotelDaily
)
SELECT ResortId, ObsDate, SweIn, SnowDepthIn, TempAvgF,
       -- a gap in the record must not become a fake three-day dump
       Swe24In = CASE WHEN DATEDIFF(day, PrevDate, ObsDate) = 1 THEN Swe24In END,
       Swe72In = SUM(CASE WHEN DATEDIFF(day, PrevDate, ObsDate) = 1 THEN Swe24In END)
                 OVER (PARTITION BY ResortId ORDER BY ObsDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
FROM d;
GO

PRINT 'SNOTEL loaded';
SELECT Stations = COUNT(*), Qualifying = SUM(CONVERT(int, Qualifies)) FROM ref.ResortSnotel;
SELECT Resorts = COUNT(DISTINCT ResortId), Days = COUNT(*),
       FirstDay = MIN(ObsDate), LastDay = MAX(ObsDate) FROM meteo.SnotelDaily;
GO
