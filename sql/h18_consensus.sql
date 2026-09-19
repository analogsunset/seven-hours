/* If which station you pick barely matters, the limit is the model's 25 km
   cell, not the gauge. In that case a CONSENSUS of every station in the
   neighbourhood should beat any single one: independent sensor noise averages
   out while the real weather signal does not.

   Each station is normalised by its own 80th percentile before averaging, so a
   wet high station cannot dominate a dry low one. */
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
DECLARE @Radius decimal(7,2);

DROP TABLE IF EXISTS #res;
CREATE TABLE #res (Radius decimal(7,2), ResortId int, Stations int, Kappa decimal(5,3), Recall decimal(5,3));

DECLARE @radii TABLE (r decimal(7,2));
INSERT @radii VALUES (10),(20),(35),(60);

DECLARE cur CURSOR FAST_FORWARD FOR SELECT r FROM @radii;
OPEN cur; FETCH NEXT FROM cur INTO @Radius;
WHILE @@FETCH_STATUS = 0
BEGIN
    ;WITH d AS
    (
        SELECT ResortId, Triplet, ObsDate,
               Step = CASE WHEN SweIn - LAG(SweIn) OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate) > 0
                           THEN SweIn - LAG(SweIn) OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate)
                           ELSE 0 END,
               PrevDate = LAG(ObsDate) OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate)
        FROM meteo.SnotelCalib WHERE Km <= @Radius
    ),
    g AS
    (
        SELECT ResortId, Triplet, ObsDate,
               Swe72 = SUM(CASE WHEN DATEDIFF(day, PrevDate, ObsDate) = 1 THEN Step END)
                       OVER (PARTITION BY ResortId, Triplet ORDER BY ObsDate ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
        FROM d
    ),
    n AS   -- each station on its own scale
    (
        SELECT ResortId, Triplet, ObsDate, Swe72,
               Own80 = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY Swe72) OVER (PARTITION BY ResortId, Triplet)
        FROM g WHERE Swe72 IS NOT NULL
    ),
    cons AS
    (
        SELECT ResortId, ObsDate, Stations = COUNT(*),
               Composite = AVG(CASE WHEN Own80 > 0 THEN Swe72 / Own80 END)
        FROM n GROUP BY ResortId, ObsDate
    ),
    j AS
    (
        SELECT c.ResortId, sd.IsFresh, s = CONVERT(float, c.Composite), c.Stations
        FROM meteo.SkiDay sd
        JOIN cons c ON c.ResortId = sd.ResortId AND c.ObsDate = DATEADD(day, -1, sd.ObsDate)
        WHERE c.Composite IS NOT NULL AND MONTH(sd.ObsDate) IN (12,1,2,3,4)
    ),
    cc AS (SELECT *, Cut = PERCENTILE_DISC(0.80) WITHIN GROUP (ORDER BY s) OVER (PARTITION BY ResortId) FROM j),
    f AS (SELECT ResortId, Stations, M = IsFresh, S = CASE WHEN s >= Cut AND s > 0 THEN 1 ELSE 0 END FROM cc),
    a AS (SELECT ResortId, Stations = MAX(Stations), N = COUNT(*),
                 Both = SUM(CASE WHEN M=1 AND S=1 THEN 1 ELSE 0 END),
                 MOnly= SUM(CASE WHEN M=1 AND S=0 THEN 1 ELSE 0 END),
                 SOnly= SUM(CASE WHEN M=0 AND S=1 THEN 1 ELSE 0 END),
                 Neither=SUM(CASE WHEN M=0 AND S=0 THEN 1 ELSE 0 END)
          FROM f GROUP BY ResortId)
    INSERT #res
    SELECT @Radius, a.ResortId, a.Stations,
           CONVERT(decimal(5,3), (1.0*(a.Both+a.Neither)/a.N - e.Pe) / NULLIF(1.0-e.Pe,0)),
           CONVERT(decimal(5,3), 1.0*a.Both/NULLIF(a.Both+a.SOnly,0))
    FROM a CROSS APPLY (SELECT Pe = 1.0*(a.Both+a.MOnly)/a.N * 1.0*(a.Both+a.SOnly)/a.N
                                 + 1.0*(a.SOnly+a.Neither)/a.N * 1.0*(a.MOnly+a.Neither)/a.N) e;
    FETCH NEXT FROM cur INTO @Radius;
END
CLOSE cur; DEALLOCATE cur;

PRINT '=== consensus of all stations within R, vs the single nearest ===';
SELECT r.ResortName,
       Nearest = b.Kappa,
       R10 = MAX(CASE WHEN x.Radius=10 THEN x.Kappa END),
       R20 = MAX(CASE WHEN x.Radius=20 THEN x.Kappa END),
       R35 = MAX(CASE WHEN x.Radius=35 THEN x.Kappa END),
       R60 = MAX(CASE WHEN x.Radius=60 THEN x.Kappa END),
       StationsAt35 = MAX(CASE WHEN x.Radius=35 THEN x.Stations END)
FROM #res x
JOIN ref.Resort r ON r.ResortId = x.ResortId
JOIN meteo.SnotelBenchmark b ON b.ResortId = x.ResortId
GROUP BY r.ResortName, b.Kappa ORDER BY r.ResortName;

PRINT '';
SELECT Radius, MeanKappa = CONVERT(decimal(5,3), AVG(Kappa)), MeanRecall = CONVERT(decimal(5,3), AVG(Recall))
FROM #res GROUP BY Radius ORDER BY Radius;
GO
