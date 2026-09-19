USE SKI_RESORT;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
WITH j AS
(
    SELECT r.ResortName, d.SeasonStartYear, d.IsFresh,
           Ratio = CONVERT(float, d.ModelSnow72In) / NULLIF(CONVERT(float, b.FreshCutIn),0),
           s = CONVERT(float, n.Swe72In)
    FROM meteo.SkiDay d
    JOIN ref.Resort r ON r.ResortId = d.ResortId
    JOIN meteo.ResortBenchmark b ON b.ResortId = d.ResortId
    JOIN meteo.vSnotelDay n ON n.ResortId = d.ResortId AND n.ObsDate = DATEADD(day,-1,d.ObsDate)
    WHERE n.Swe72In IS NOT NULL AND MONTH(d.ObsDate) IN (12,1,2,3,4)
),
c AS (SELECT *, Cut = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s) OVER (PARTITION BY ResortName) FROM j),
f AS (SELECT ResortName, Ratio, S = CASE WHEN s >= Cut AND s > 0 THEN 1 ELSE 0 END FROM c)
SELECT Band = CASE WHEN Ratio >= 2.0 THEN 'd. model >= 2.0x cut'
                   WHEN Ratio >= 1.5 THEN 'c. 1.5-2.0x'
                   WHEN Ratio >= 1.0 THEN 'b. 1.0-1.5x (just over)'
                   WHEN Ratio >= 0.7 THEN 'a. 0.7-1.0x (just under)'
                   ELSE '0. well under' END,
       Days = COUNT(*),
       SnotelAgrees = SUM(S),
       PctSnotelFresh = CONVERT(decimal(5,3), 1.0*SUM(S)/COUNT(*))
FROM f GROUP BY CASE WHEN Ratio >= 2.0 THEN 'd. model >= 2.0x cut'
                   WHEN Ratio >= 1.5 THEN 'c. 1.5-2.0x'
                   WHEN Ratio >= 1.0 THEN 'b. 1.0-1.5x (just over)'
                   WHEN Ratio >= 0.7 THEN 'a. 0.7-1.0x (just under)'
                   ELSE '0. well under' END
ORDER BY Band;

PRINT '';
PRINT '=== fresh days per season: does the count match, even when the days shuffle? ===';
WITH j AS
(
    SELECT r.ResortName, d.SeasonStartYear, d.IsFresh, s = CONVERT(float, n.Swe72In)
    FROM meteo.SkiDay d
    JOIN ref.Resort r ON r.ResortId = d.ResortId
    JOIN meteo.vSnotelDay n ON n.ResortId = d.ResortId AND n.ObsDate = DATEADD(day,-1,d.ObsDate)
    WHERE n.Swe72In IS NOT NULL AND MONTH(d.ObsDate) IN (12,1,2,3,4)
),
c AS (SELECT *, Cut = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s) OVER (PARTITION BY ResortName) FROM j),
p AS (SELECT ResortName, SeasonStartYear, M = SUM(CONVERT(int,IsFresh)),
             S = SUM(CASE WHEN s >= Cut AND s > 0 THEN 1 ELSE 0 END)
      FROM c GROUP BY ResortName, SeasonStartYear HAVING COUNT(*) > 100)
SELECT ResortName, Seasons = COUNT(*),
       AvgModel  = CONVERT(decimal(5,1), AVG(1.0*M)),
       AvgSnotel = CONVERT(decimal(5,1), AVG(1.0*S)),
       MeanAbsErr= CONVERT(decimal(5,1), AVG(1.0*ABS(M-S))),
       CorrOfSeasonTotals = CONVERT(decimal(5,3),
          (AVG(1.0*M*S) - AVG(1.0*M)*AVG(1.0*S)) / NULLIF(STDEVP(1.0*M)*STDEVP(1.0*S),0))
FROM p GROUP BY ResortName ORDER BY CorrOfSeasonTotals DESC;
GO
