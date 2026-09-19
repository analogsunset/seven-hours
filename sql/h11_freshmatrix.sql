/* ============================================================================
   THE TEST. Model IsFresh -- the flag the page actually ships -- against a
   SNOTEL fresh flag built by the identical rule: the 80th percentile of that
   station's own 72h water gain. Same percentile, same days, each series in
   its own units.

   Restricted to Dec-Apr, which is what meteo.ResortBenchmark uses to set the
   model's cut. Scoring the model's winter-derived threshold against a
   year-round percentile would compare two different questions.

   Lag -1: SNOTEL's daily value dated d-1 is the one that aligns with the
   model's 72h window ending at the lift opening on day d. Established
   empirically in h10, not assumed -- it beat lag 0 at all nine stations.
   ============================================================================ */
USE SKI_RESORT;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
WITH j AS
(
    SELECT r.ResortName, d.IsFresh, s = CONVERT(float, n.Swe72In)
    FROM meteo.SkiDay d
    JOIN ref.Resort r       ON r.ResortId = d.ResortId
    JOIN meteo.vSnotelDay n ON n.ResortId = d.ResortId
                           AND n.ObsDate  = DATEADD(day, -1, d.ObsDate)
    WHERE n.Swe72In IS NOT NULL
      AND MONTH(d.ObsDate) IN (12,1,2,3,4)
),
c AS
(
    SELECT ResortName, IsFresh, s,
           Cut = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s) OVER (PARTITION BY ResortName)
    FROM j
),
f AS
(
    -- a cut of zero would flag every dry day, so a fresh day must at minimum
    -- have gained water
    SELECT ResortName, M = IsFresh, Cut,
           S = CASE WHEN s >= Cut AND s > 0 THEN 1 ELSE 0 END
    FROM c
),
a AS
(
    SELECT ResortName, N = COUNT(*),
           Both   = SUM(CASE WHEN M=1 AND S=1 THEN 1 ELSE 0 END),
           MOnly  = SUM(CASE WHEN M=1 AND S=0 THEN 1 ELSE 0 END),
           SOnly  = SUM(CASE WHEN M=0 AND S=1 THEN 1 ELSE 0 END),
           Neither= SUM(CASE WHEN M=0 AND S=0 THEN 1 ELSE 0 END),
           SnotelCut = MAX(Cut)
    FROM f GROUP BY ResortName
)
SELECT  a.ResortName, a.N,
        MFresh = a.Both + a.MOnly, SFresh = a.Both + a.SOnly,
        Both = a.Both, Missed = a.SOnly, FalseFresh = a.MOnly,
        Recall    = CONVERT(decimal(5,3), 1.0 * a.Both / NULLIF(a.Both + a.SOnly, 0)),
        Precision_= CONVERT(decimal(5,3), 1.0 * a.Both / NULLIF(a.Both + a.MOnly, 0)),
        Agreement = CONVERT(decimal(5,3), 1.0 * (a.Both + a.Neither) / a.N),
        Kappa = CONVERT(decimal(5,3),
                  (1.0*(a.Both+a.Neither)/a.N - e.Pe) / NULLIF(1.0 - e.Pe, 0)),
        SnotelCutIn = CONVERT(decimal(5,2), a.SnotelCut),
        ModelCutIn  = CONVERT(decimal(5,2), b.FreshCutIn),
        Km = CONVERT(decimal(5,1), x.DistanceKm), Qual = x.Qualifies
FROM a
CROSS APPLY (SELECT Pe = 1.0*(a.Both+a.MOnly)/a.N * 1.0*(a.Both+a.SOnly)/a.N
                       + 1.0*(a.SOnly+a.Neither)/a.N * 1.0*(a.MOnly+a.Neither)/a.N) e
JOIN ref.Resort r ON r.ResortName = a.ResortName
JOIN meteo.ResortBenchmark b ON b.ResortId = r.ResortId
JOIN ref.ResortSnotel x ON x.ResortId = r.ResortId
ORDER BY Kappa DESC;
GO
