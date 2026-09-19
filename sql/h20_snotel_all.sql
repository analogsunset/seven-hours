/* ============================================================================
   SNOTEL, second pass: the whole neighbourhood rather than one station.

   The first pass picked the single nearest station inside a guessed gate of
   6 km / 1200 ft. Calibration (h17) showed the gate was wrong in both
   directions: agreement is flat out to 35 km and near-flat against elevation,
   and the nearest station was the best one at only 2 of 9 resorts. The limit
   is the reanalysis grid cell, not the gauge.

   Calibration also showed (h18) that averaging the neighbourhood beats any
   single station at 8 of 9 resorts, kappa .632 -> .683. Each station is
   normalised by its OWN 80th percentile first, so a wet high station cannot
   drown out a dry low one; the composite is therefore already expressed in
   multiples of "a normal big dump here", the same currency the model side uses.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* meteo.vSkiDaySnow is NOT dropped here. It moved to h05_skiday.sql, which
   owns it beside the table it mirrors, and this script now runs AFTER h05 on
   its second pass -- so dropping it here deleted the view h05 had just built
   and the export died on "Invalid object name meteo.vSkiDaySnow". The drop was
   the last piece of the old arrangement left behind when the view moved.
   vSnotelDay is a genuinely obsolete predecessor and is still cleaned up. */
DROP VIEW IF EXISTS meteo.vSnotelDay;
DROP TABLE IF EXISTS meteo.SnotelConsensus;
DROP TABLE IF EXISTS meteo.SnotelBenchmark;
DROP TABLE IF EXISTS meteo.SnotelDaily;
DROP TABLE IF EXISTS meteo.SnotelStationDaily;
DROP TABLE IF EXISTS ref.ResortSnotel;
DROP TABLE IF EXISTS stg.SnotelAllRaw;
DROP TABLE IF EXISTS stg.SnotelMapAllRaw;
GO

CREATE TABLE stg.SnotelMapAllRaw
    (ResortName nvarchar(200) NULL, Triplet nvarchar(50) NULL,
     Km nvarchar(50) NULL, DeltaFt nvarchar(50) NULL);
CREATE TABLE stg.SnotelAllRaw
    (Triplet nvarchar(50) NULL, ObsDate nvarchar(20) NULL,
     SweIn nvarchar(50) NULL, SnowDepthIn nvarchar(50) NULL);
GO
BULK INSERT stg.SnotelMapAllRaw FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_snotel_map_all.txt'
WITH (FIELDTERMINATOR='|', ROWTERMINATOR='0x0a', CODEPAGE='65001', DATAFILETYPE='char', TABLOCK);
BULK INSERT stg.SnotelAllRaw FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_snotel_all.txt'
WITH (FIELDTERMINATOR='|', ROWTERMINATOR='0x0a', CODEPAGE='65001', DATAFILETYPE='char', TABLOCK);
GO

/* one row per station-day, shared by every resort that station serves */
CREATE TABLE meteo.SnotelStationDaily
(
    Triplet     nvarchar(50) NOT NULL,
    ObsDate     date         NOT NULL,
    SweIn       decimal(7,2) NULL,
    SnowDepthIn decimal(7,1) NULL,
    CONSTRAINT PK_SnotelStationDaily PRIMARY KEY (Triplet, ObsDate)
);
INSERT meteo.SnotelStationDaily (Triplet, ObsDate, SweIn, SnowDepthIn)
SELECT Triplet, TRY_CONVERT(date, ObsDate),
       TRY_CONVERT(decimal(7,2), NULLIF(SweIn,'')),
       TRY_CONVERT(decimal(7,1), NULLIF(SnowDepthIn,''))
FROM stg.SnotelAllRaw
WHERE TRY_CONVERT(date, ObsDate) IS NOT NULL;
GO

CREATE TABLE ref.ResortSnotel
(
    ResortId    int          NOT NULL REFERENCES ref.Resort (ResortId),
    Triplet     nvarchar(50) NOT NULL,
    DistanceKm  decimal(7,2) NOT NULL,
    ElevDeltaFt decimal(8,1) NULL,
    StationRank int          NOT NULL,   -- 1 = nearest
    ElevRank    int          NOT NULL,   -- 1 = closest to mid-mountain elevation
    CONSTRAINT PK_ResortSnotel PRIMARY KEY (ResortId, Triplet)
);
INSERT ref.ResortSnotel (ResortId, Triplet, DistanceKm, ElevDeltaFt, StationRank, ElevRank)
SELECT r.ResortId, m.Triplet, TRY_CONVERT(decimal(7,2), m.Km),
       TRY_CONVERT(decimal(8,1), NULLIF(m.DeltaFt,'')),
       ROW_NUMBER() OVER (PARTITION BY r.ResortId ORDER BY TRY_CONVERT(decimal(7,2), m.Km)),
       /* For SNOWFALL, distance barely matters (h17) and the whole
          neighbourhood is averaged. For BASE DEPTH elevation dominates -- a
          station 2,000 ft below mid-mountain holds a different snowpack -- so
          the base reading comes from the elevation-matched station, falling
          back to the nearest where no mid-elevation is published. */
       ROW_NUMBER() OVER (PARTITION BY r.ResortId
                          ORDER BY ABS(TRY_CONVERT(decimal(8,1), NULLIF(m.DeltaFt,''))),
                                   TRY_CONVERT(decimal(7,2), m.Km))
FROM stg.SnotelMapAllRaw m
JOIN ref.Resort r ON r.ResortName = m.ResortName;
GO

/* Station-level 72h water gain, and each station's own 80th percentile.
   Negative steps are melt and settling, not snowfall, so they clip to zero;
   a gap in the record must not read as a three-day dump. */
CREATE OR ALTER VIEW meteo.vSnotelStationDay
AS
WITH d AS
(
    SELECT Triplet, ObsDate, SweIn, SnowDepthIn,
           Step = CASE WHEN SweIn - LAG(SweIn) OVER (PARTITION BY Triplet ORDER BY ObsDate) > 0
                       THEN SweIn - LAG(SweIn) OVER (PARTITION BY Triplet ORDER BY ObsDate)
                       ELSE 0 END,
           /* Depth gain is the intuitive "how many inches fell" number. It
              under-reads, because the pack settles between the daily readings
              while a resort clears its stake every few hours -- but it is a
              measured depth, not a 7:1 ratio applied to modelled water. */
           DStep = CASE WHEN SnowDepthIn - LAG(SnowDepthIn) OVER (PARTITION BY Triplet ORDER BY ObsDate) > 0
                        THEN SnowDepthIn - LAG(SnowDepthIn) OVER (PARTITION BY Triplet ORDER BY ObsDate)
                        ELSE 0 END,
           PrevDate = LAG(ObsDate) OVER (PARTITION BY Triplet ORDER BY ObsDate)
    FROM meteo.SnotelStationDaily
)
SELECT Triplet, ObsDate, SweIn, SnowDepthIn,
       Swe72In = SUM(CASE WHEN DATEDIFF(day, PrevDate, ObsDate) = 1 THEN Step END)
                 OVER (PARTITION BY Triplet ORDER BY ObsDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
       NewSnow72In = SUM(CASE WHEN DATEDIFF(day, PrevDate, ObsDate) = 1 THEN DStep END)
                 OVER (PARTITION BY Triplet ORDER BY ObsDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
       NewSnow24In = CASE WHEN DATEDIFF(day, PrevDate, ObsDate) = 1 THEN DStep END
FROM d;
GO

/* The neighbourhood consensus, materialised. */
CREATE TABLE meteo.SnotelConsensus
(
    ResortId  int          NOT NULL,
    ObsDate   date         NOT NULL,
    Stations  smallint     NOT NULL,
    Composite   decimal(9,4) NOT NULL, -- mean of each station's gain / its own 80th pctile
    Swe72In     decimal(7,2) NULL,     -- neighbourhood mean water gain, actual inches
    NewSnow72In decimal(7,1) NULL,     -- neighbourhood mean depth gain, actual inches
    NewSnow24In decimal(7,1) NULL,     -- the same over one day
    BaseFt      decimal(6,2) NULL,     -- elevation-matched station's depth, a level
    CONSTRAINT PK_SnotelConsensus PRIMARY KEY (ResortId, ObsDate)
);
GO

WITH n AS
(
    SELECT x.ResortId, x.Triplet, x.ElevRank, s.ObsDate, s.Swe72In, s.NewSnow72In,
           s.NewSnow24In, s.SnowDepthIn,
           /* Plenty of stations report water equivalent but not depth, and not
              on every day. So the base reading falls through the neighbourhood
              in elevation order to the closest-matched station that actually
              reported a depth THAT day -- taking only ElevRank = 1 left
              Whitefish measured on 11% of days and Sun Valley on 44%. */
           DepthRank = ROW_NUMBER() OVER (PARTITION BY x.ResortId, s.ObsDate
                        ORDER BY CASE WHEN s.SnowDepthIn IS NULL THEN 1 ELSE 0 END,
                                 x.ElevRank),
           Own80 = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s.Swe72In)
                   OVER (PARTITION BY x.ResortId, x.Triplet)
    FROM ref.ResortSnotel x
    JOIN meteo.vSnotelStationDay s ON s.Triplet = x.Triplet
    WHERE s.Swe72In IS NOT NULL
)
INSERT meteo.SnotelConsensus (ResortId, ObsDate, Stations, Composite, Swe72In, NewSnow72In, NewSnow24In, BaseFt)
SELECT n.ResortId, n.ObsDate, COUNT(*),
       CONVERT(decimal(9,4), AVG(CASE WHEN n.Own80 > 0 THEN n.Swe72In / n.Own80 END)),
       CONVERT(decimal(7,2), AVG(n.Swe72In)),
       CONVERT(decimal(7,1), AVG(n.NewSnow72In)),
       CONVERT(decimal(7,1), AVG(n.NewSnow24In)),
       CONVERT(decimal(6,2), MAX(CASE WHEN n.DepthRank = 1 THEN n.SnowDepthIn END) / 12.0)
FROM n
GROUP BY n.ResortId, n.ObsDate
HAVING AVG(CASE WHEN n.Own80 > 0 THEN n.Swe72In / n.Own80 END) IS NOT NULL;
GO
CREATE INDEX IX_SnotelConsensus_Date ON meteo.SnotelConsensus (ObsDate) INCLUDE (Composite);
GO

/* Per-resort fresh line on the consensus, and how well the model matched it.
   Only computable where ERA5 hourly exists, i.e. where meteo.SkiDay has rows. */
CREATE TABLE meteo.SnotelBenchmark
(
    ResortId   int          NOT NULL PRIMARY KEY REFERENCES ref.Resort (ResortId),
    FreshCut   decimal(9,4) NOT NULL,
    Stations   smallint     NOT NULL,
    NearestKm  decimal(7,2) NOT NULL,
    WinterDays int          NOT NULL,
    Recall     decimal(5,3) NULL,
    Precision_ decimal(5,3) NULL,
    Agreement  decimal(5,3) NULL,
    Kappa      decimal(5,3) NULL
);
GO
/* BOOTSTRAP. This scores the model against the gauges, so it needs
   meteo.SkiDay -- which h05_skiday.sql creates, and which in turn needs the
   consensus this script builds above. The dependency is genuinely circular, so
   on a fresh database the order is h20, h05, h20: the first pass builds the
   consensus and leaves this table empty, h05 builds the model against it, and
   the second pass fills in the scores. Without the guard the first pass dies
   on "Invalid object name meteo.SkiDay" and the run looks broken when it is
   merely incomplete. */
IF OBJECT_ID('meteo.SkiDay', 'U') IS NULL
BEGIN
    PRINT 'meteo.SkiDay does not exist yet -- SnotelBenchmark left empty.';
    PRINT 'Run h05_skiday.sql, then re-run this script to score the model.';
END
ELSE
BEGIN
;WITH j AS
(
    -- IsFreshModel, deliberately: this measures ERA5 against the gauges, and
    -- SkiDay.IsFresh now defers to the gauges where they exist
    SELECT d.ResortId, IsFresh = d.IsFreshModel, s = CONVERT(float, c.Composite), c.Stations
    FROM meteo.SkiDay d
    JOIN meteo.SnotelConsensus c ON c.ResortId = d.ResortId
                                AND c.ObsDate  = DATEADD(day, -1, d.ObsDate)
    WHERE MONTH(d.ObsDate) IN (12,1,2,3,4)
),
cc AS (SELECT *, Cut = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s) OVER (PARTITION BY ResortId) FROM j),
f  AS (SELECT ResortId, Cut, Stations, M = IsFresh,
              S = CASE WHEN s >= Cut AND s > 0 THEN 1 ELSE 0 END FROM cc),
a  AS (SELECT ResortId, Cut = MAX(Cut), Stations = MAX(Stations), N = COUNT(*),
              Both = SUM(CASE WHEN M=1 AND S=1 THEN 1 ELSE 0 END),
              MOnly= SUM(CASE WHEN M=1 AND S=0 THEN 1 ELSE 0 END),
              SOnly= SUM(CASE WHEN M=0 AND S=1 THEN 1 ELSE 0 END),
              Neither=SUM(CASE WHEN M=0 AND S=0 THEN 1 ELSE 0 END)
       FROM f GROUP BY ResortId)
INSERT meteo.SnotelBenchmark
       (ResortId, FreshCut, Stations, NearestKm, WinterDays, Recall, Precision_, Agreement, Kappa)
SELECT a.ResortId, CONVERT(decimal(9,4), a.Cut), a.Stations,
       (SELECT MIN(DistanceKm) FROM ref.ResortSnotel x WHERE x.ResortId = a.ResortId),
       a.N,
       CONVERT(decimal(5,3), 1.0*a.Both/NULLIF(a.Both+a.SOnly,0)),
       CONVERT(decimal(5,3), 1.0*a.Both/NULLIF(a.Both+a.MOnly,0)),
       CONVERT(decimal(5,3), 1.0*(a.Both+a.Neither)/a.N),
       CONVERT(decimal(5,3), (1.0*(a.Both+a.Neither)/a.N - e.Pe) / NULLIF(1.0-e.Pe,0))
FROM a CROSS APPLY (SELECT Pe = 1.0*(a.Both+a.MOnly)/a.N * 1.0*(a.Both+a.SOnly)/a.N
                             + 1.0*(a.SOnly+a.Neither)/a.N * 1.0*(a.MOnly+a.Neither)/a.N) e;
END
GO

/* meteo.vSkiDaySnow is NOT created here any more -- it lives at the end of
   h05_skiday.sql. The view is SELECT d.*, so SQL Server freezes meteo.SkiDay's
   column list into it at creation time. Every time h05 added a column
   (IsEpic, FailMask, SnotelBaseFt, ...) the view silently kept serving the old
   list and the export failed with "Invalid column name" until somebody
   remembered to re-run this script. Owning it next to the table it mirrors
   means rebuilding the table always refreshes it. */


PRINT 'Neighbourhood consensus built.';
SELECT Resorts = COUNT(DISTINCT ResortId), Stations = COUNT(DISTINCT Triplet),
       Pairs = COUNT(*) FROM ref.ResortSnotel;
SELECT ConsensusResortDays = COUNT(*), Resorts = COUNT(DISTINCT ResortId) FROM meteo.SnotelConsensus;
SELECT r.ResortName, b.Stations, NearestKm = CONVERT(decimal(5,1), b.NearestKm),
       b.Recall, b.Precision_, b.Agreement, b.Kappa
FROM meteo.SnotelBenchmark b JOIN ref.Resort r ON r.ResortId = b.ResortId
ORDER BY b.Kappa DESC;
GO
