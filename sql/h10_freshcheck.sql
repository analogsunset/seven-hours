/* ============================================================================
   Does the modelled fresh line pick the same days as the measured one?

   Method. Restrict to winter days where both series exist. Within each resort,
   take the 80th percentile of the model's 72h snowfall and the 80th percentile
   of SNOTEL's 72h water gain -- the same rule, applied to each series in its
   own units. Then cross-tab. If the model's inches are wrong by a per-resort
   constant, the percentile survives it and the two flags land on the same days.

   Lag is tested because the two clocks differ: the model's window ends at the
   lift opening, SNOTEL's daily value ends at local midnight. Whichever lag
   agrees best is the honest alignment, not a thumb on the scale.
   ============================================================================ */
USE SKI_RESORT;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @Lag int;

DROP TABLE IF EXISTS #lagfit;
CREATE TABLE #lagfit (Lag int, Resort nvarchar(200), N int, Corr decimal(6,3));

SET @Lag = -1;
WHILE @Lag <= 1
BEGIN
    ;WITH j AS
    (
        SELECT r.ResortName, m = CONVERT(float, d.ModelSnow72In), s = CONVERT(float, n.Swe72In)
        FROM meteo.SkiDay d
        JOIN ref.Resort r      ON r.ResortId = d.ResortId
        JOIN meteo.vSnotelDay n ON n.ResortId = d.ResortId
                              AND n.ObsDate  = DATEADD(day, @Lag, d.ObsDate)
        WHERE n.Swe72In IS NOT NULL
    )
    INSERT #lagfit
    SELECT @Lag, ResortName, COUNT(*),
           CONVERT(decimal(6,3),
             (AVG(m*s) - AVG(m)*AVG(s)) /
             NULLIF(STDEVP(m) * STDEVP(s), 0))
    FROM j GROUP BY ResortName;
    SET @Lag += 1;
END

PRINT '=== correlation of modelled 72h snow vs measured 72h water, by lag ===';
SELECT Resort,
       [-1] = MAX(CASE WHEN Lag = -1 THEN Corr END),
       [0]  = MAX(CASE WHEN Lag =  0 THEN Corr END),
       [+1] = MAX(CASE WHEN Lag =  1 THEN Corr END),
       Days = MAX(N)
FROM #lagfit GROUP BY Resort ORDER BY Resort;
GO
