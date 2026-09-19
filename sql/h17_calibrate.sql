/* ============================================================================
   Where should the SNOTEL qualification gate actually sit?

   Every station within 60 km of a resort that has ERA5 hourly data is scored
   against the SAME model output by the SAME rule. That converts "does distance
   matter" from an opinion into a decay curve. 54 resort-station pairs.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DROP TABLE IF EXISTS stg.SnotelCalibRaw;
DROP TABLE IF EXISTS meteo.SnotelCalib;
GO
CREATE TABLE stg.SnotelCalibRaw
(
    ResortName nvarchar(200) NULL, Triplet nvarchar(50) NULL,
    Km nvarchar(50) NULL, DeltaFt nvarchar(50) NULL, ObsDate nvarchar(20) NULL,
    SweIn nvarchar(50) NULL, SnowDepthIn nvarchar(50) NULL
);
GO
BULK INSERT stg.SnotelCalibRaw
FROM 'D:\TFS\JTDEV\python\ski_resort_stats\_snotel_calib.txt'
WITH (FIELDTERMINATOR = '|', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', DATAFILETYPE = 'char', TABLOCK);
GO

CREATE TABLE meteo.SnotelCalib
(
    ResortId int NOT NULL, Triplet nvarchar(50) NOT NULL, ObsDate date NOT NULL,
    Km decimal(7,2) NOT NULL, DeltaFt decimal(8,1) NULL, SweIn decimal(7,2) NULL,
    CONSTRAINT PK_SnotelCalib PRIMARY KEY (ResortId, Triplet, ObsDate)
);
GO
INSERT meteo.SnotelCalib (ResortId, Triplet, ObsDate, Km, DeltaFt, SweIn)
SELECT r.ResortId, c.Triplet, TRY_CONVERT(date, c.ObsDate),
       TRY_CONVERT(decimal(7,2), c.Km), TRY_CONVERT(decimal(8,1), NULLIF(c.DeltaFt,'')),
       TRY_CONVERT(decimal(7,2), NULLIF(c.SweIn,''))
FROM stg.SnotelCalibRaw c
JOIN ref.Resort r ON r.ResortName = c.ResortName
WHERE TRY_CONVERT(date, c.ObsDate) IS NOT NULL;
GO

/* the measured 72h water gain, per resort-station pair */
WITH d AS
(
    SELECT ResortId, Triplet, ObsDate, Km, DeltaFt, SweIn,
           Step = CASE WHEN SweIn - LAG(SweIn) OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate) > 0
                       THEN SweIn - LAG(SweIn) OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate)
                       ELSE 0 END,
           PrevDate = LAG(ObsDate) OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate)
    FROM meteo.SnotelCalib
),
g AS
(
    SELECT ResortId, Triplet, ObsDate, Km, DeltaFt,
           Swe72 = SUM(CASE WHEN DATEDIFF(day, PrevDate, ObsDate) = 1 THEN Step END)
                   OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
    FROM d
),
j AS
(
    SELECT g.ResortId, g.Triplet, g.Km, g.DeltaFt, sd.IsFresh, s = CONVERT(float, g.Swe72)
    FROM meteo.SkiDay sd
    JOIN g ON g.ResortId = sd.ResortId AND g.ObsDate = DATEADD(day, -1, sd.ObsDate)
    WHERE g.Swe72 IS NOT NULL AND MONTH(sd.ObsDate) IN (12,1,2,3,4)
),
c AS (SELECT *, Cut = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s)
                     OVER (PARTITION BY ResortId, Triplet) FROM j),
f AS (SELECT ResortId, Triplet, Km, DeltaFt, M = IsFresh,
             S = CASE WHEN s >= Cut AND s > 0 THEN 1 ELSE 0 END FROM c),
a AS (SELECT ResortId, Triplet, Km = MAX(Km), DeltaFt = MAX(DeltaFt), N = COUNT(*),
             Both = SUM(CASE WHEN M=1 AND S=1 THEN 1 ELSE 0 END),
             MOnly= SUM(CASE WHEN M=1 AND S=0 THEN 1 ELSE 0 END),
             SOnly= SUM(CASE WHEN M=0 AND S=1 THEN 1 ELSE 0 END),
             Neither=SUM(CASE WHEN M=0 AND S=0 THEN 1 ELSE 0 END)
      FROM f GROUP BY ResortId, Triplet)
SELECT r.ResortName, a.Triplet, Km = CONVERT(decimal(5,1), a.Km),
       DeltaFt = CONVERT(int, a.DeltaFt), a.N,
       Recall = CONVERT(decimal(5,3), 1.0*a.Both/NULLIF(a.Both+a.SOnly,0)),
       Kappa  = CONVERT(decimal(5,3), (1.0*(a.Both+a.Neither)/a.N - e.Pe) / NULLIF(1.0-e.Pe,0)),
       Rank_  = ROW_NUMBER() OVER (PARTITION BY a.ResortId ORDER BY a.Km)
INTO #k
FROM a
CROSS APPLY (SELECT Pe = 1.0*(a.Both+a.MOnly)/a.N * 1.0*(a.Both+a.SOnly)/a.N
                       + 1.0*(a.SOnly+a.Neither)/a.N * 1.0*(a.MOnly+a.Neither)/a.N) e
JOIN ref.Resort r ON r.ResortId = a.ResortId;

PRINT '=== kappa by distance band ===';
SELECT Band = CASE WHEN Km <=  5 THEN 'a. 0-5 km'   WHEN Km <= 10 THEN 'b. 5-10 km'
                   WHEN Km <= 20 THEN 'c. 10-20 km' WHEN Km <= 35 THEN 'd. 20-35 km'
                   ELSE 'e. 35-60 km' END,
       Pairs = COUNT(*), MeanKappa = CONVERT(decimal(5,3), AVG(Kappa)),
       MinKappa = MIN(Kappa), MaxKappa = MAX(Kappa)
FROM #k GROUP BY CASE WHEN Km <=  5 THEN 'a. 0-5 km'   WHEN Km <= 10 THEN 'b. 5-10 km'
                   WHEN Km <= 20 THEN 'c. 10-20 km' WHEN Km <= 35 THEN 'd. 20-35 km'
                   ELSE 'e. 35-60 km' END
ORDER BY Band;

PRINT '';
PRINT '=== kappa by elevation offset (station minus mid-mountain) ===';
SELECT Band = CASE WHEN ABS(DeltaFt) <=  500 THEN 'a. within 500 ft'
                   WHEN ABS(DeltaFt) <= 1000 THEN 'b. 500-1000 ft'
                   WHEN ABS(DeltaFt) <= 1500 THEN 'c. 1000-1500 ft'
                   ELSE 'd. over 1500 ft' END,
       Pairs = COUNT(*), MeanKappa = CONVERT(decimal(5,3), AVG(Kappa)),
       MinKappa = MIN(Kappa), MaxKappa = MAX(Kappa)
FROM #k WHERE DeltaFt IS NOT NULL
GROUP BY CASE WHEN ABS(DeltaFt) <=  500 THEN 'a. within 500 ft'
              WHEN ABS(DeltaFt) <= 1000 THEN 'b. 500-1000 ft'
              WHEN ABS(DeltaFt) <= 1500 THEN 'c. 1000-1500 ft'
              ELSE 'd. over 1500 ft' END
ORDER BY Band;

PRINT '';
PRINT '=== is the NEAREST station the best one? ===';
SELECT Rank_, Pairs = COUNT(*), MeanKappa = CONVERT(decimal(5,3), AVG(Kappa))
FROM #k GROUP BY Rank_ ORDER BY Rank_;

PRINT '';
PRINT '=== best station per resort vs the nearest ===';
SELECT k.ResortName,
       NearestKm = CONVERT(decimal(5,1), MIN(CASE WHEN k.Rank_=1 THEN k.Km END)),
       NearestKappa = MAX(CASE WHEN k.Rank_=1 THEN k.Kappa END),
       BestKm = CONVERT(decimal(5,1), MAX(CASE WHEN k.Kappa = m.MK THEN k.Km END)),
       BestKappa = m.MK
FROM #k k
JOIN (SELECT ResortName, MK = MAX(Kappa) FROM #k GROUP BY ResortName) m
     ON m.ResortName = k.ResortName
GROUP BY k.ResortName, m.MK ORDER BY k.ResortName;
GO
