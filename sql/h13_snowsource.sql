/* ============================================================================
   Measured snow alongside modelled snow.

   The tiers stay ERA5-derived for every resort, including the nine with a
   station. That is deliberate: the whole point of the within-resort percentile
   is that all 431 resorts stay on one comparable scale, and swapping the snow
   source under nine of them would break exactly that. SNOTEL is carried as a
   second opinion the page can show, plus a per-resort agreement score earned
   against measurement.
   ============================================================================ */
USE SKI_RESORT;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DROP TABLE IF EXISTS meteo.SnotelBenchmark;
CREATE TABLE meteo.SnotelBenchmark
(
    ResortId    int          NOT NULL PRIMARY KEY REFERENCES ref.Resort (ResortId),
    FreshCutIn  decimal(6,2) NOT NULL,  -- 80th pctile of measured 72h water gain
    WinterDays  int          NOT NULL,
    Recall      decimal(5,3) NULL,      -- of measured fresh days, share the model caught
    Precision_  decimal(5,3) NULL,
    Agreement   decimal(5,3) NULL,
    Kappa       decimal(5,3) NULL       -- agreement above chance given the base rates
);
GO

WITH j AS
(
    SELECT d.ResortId, d.IsFresh, s = CONVERT(float, n.Swe72In)
    FROM meteo.SkiDay d
    JOIN meteo.vSnotelDay n ON n.ResortId = d.ResortId
                           AND n.ObsDate  = DATEADD(day, -1, d.ObsDate)
    WHERE n.Swe72In IS NOT NULL AND MONTH(d.ObsDate) IN (12,1,2,3,4)
),
c AS (SELECT ResortId, IsFresh, s,
             Cut = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s) OVER (PARTITION BY ResortId)
      FROM j),
f AS (SELECT ResortId, Cut, M = IsFresh, S = CASE WHEN s >= Cut AND s > 0 THEN 1 ELSE 0 END FROM c),
a AS (SELECT ResortId, Cut = MAX(Cut), N = COUNT(*),
             Both = SUM(CASE WHEN M=1 AND S=1 THEN 1 ELSE 0 END),
             MOnly= SUM(CASE WHEN M=1 AND S=0 THEN 1 ELSE 0 END),
             SOnly= SUM(CASE WHEN M=0 AND S=1 THEN 1 ELSE 0 END),
             Neither=SUM(CASE WHEN M=0 AND S=0 THEN 1 ELSE 0 END)
      FROM f GROUP BY ResortId)
INSERT meteo.SnotelBenchmark (ResortId, FreshCutIn, WinterDays, Recall, Precision_, Agreement, Kappa)
SELECT a.ResortId, CONVERT(decimal(6,2), a.Cut), a.N,
       CONVERT(decimal(5,3), 1.0*a.Both/NULLIF(a.Both+a.SOnly,0)),
       CONVERT(decimal(5,3), 1.0*a.Both/NULLIF(a.Both+a.MOnly,0)),
       CONVERT(decimal(5,3), 1.0*(a.Both+a.Neither)/a.N),
       CONVERT(decimal(5,3), (1.0*(a.Both+a.Neither)/a.N - e.Pe) / NULLIF(1.0-e.Pe,0))
FROM a
CROSS APPLY (SELECT Pe = 1.0*(a.Both+a.MOnly)/a.N * 1.0*(a.Both+a.SOnly)/a.N
                       + 1.0*(a.SOnly+a.Neither)/a.N * 1.0*(a.MOnly+a.Neither)/a.N) e;
GO

/* Every ski day, with the measured second opinion attached where one exists. */
CREATE OR ALTER VIEW meteo.vSkiDaySnow
AS
SELECT  d.*,
        r.ResortName,
        SnowSource     = CASE WHEN sb.ResortId IS NULL THEN 'modelled' ELSE 'measured' END,
        StationName    = x.StationName,
        StationKm      = x.DistanceKm,
        SnotelSwe72In  = n.Swe72In,
        SnotelBaseFt   = CONVERT(decimal(6,2), n.SnowDepthIn / 12.0),
        SnotelFreshCut = sb.FreshCutIn,
        SnotelIsFresh  = CASE WHEN n.Swe72In IS NULL THEN NULL
                              WHEN n.Swe72In >= sb.FreshCutIn AND n.Swe72In > 0 THEN 1 ELSE 0 END
FROM meteo.SkiDay d
JOIN ref.Resort r ON r.ResortId = d.ResortId
LEFT JOIN meteo.SnotelBenchmark sb ON sb.ResortId = d.ResortId
LEFT JOIN ref.ResortSnotel x       ON x.ResortId  = d.ResortId
LEFT JOIN meteo.vSnotelDay n       ON n.ResortId  = d.ResortId
                                  AND n.ObsDate   = DATEADD(day, -1, d.ObsDate);
GO

PRINT 'Snow provenance wired: meteo.SnotelBenchmark, meteo.vSkiDaySnow';
SELECT r.ResortName, b.FreshCutIn, b.WinterDays, b.Recall, b.Precision_, b.Agreement, b.Kappa,
       x.StationName, Km = CONVERT(decimal(5,1), x.DistanceKm)
FROM meteo.SnotelBenchmark b
JOIN ref.Resort r ON r.ResortId = b.ResortId
JOIN ref.ResortSnotel x ON x.ResortId = b.ResortId
ORDER BY b.Kappa DESC;
GO
