/* ============================================================================
   POWDER DAYS BY SKY AND FELT TEMPERATURE

   Every day with real new snow on it, crossed against the two things a tier
   rule might use to disqualify it. It exists to answer "where should the lines
   go", so it deliberately does NOT apply a temperature or sky rule of its own --
   those are the axes, not the filter.

   WHAT COUNTS AS A POWDER DAY here:
     - RIDEABLE:  no flat light, no wind hold, no rain on snow. These are the
                  tests no snowfall can compensate for, so they filter rather
                  than appear as an axis.
     - FRESH:     @FreshIn inches in the last 24 hours, measured by SNOTEL where
                  a gauge reported and modelled otherwise. The modelled side is
                  this resort's own bias-corrected equivalent, scaled from the
                  stored 4-inch cut -- the cut is linear in inches (the ratio of
                  Snow24Cut4In to Snow24Cut2In is 2.00 across all 431 resorts).
     - WEEK:      optional, @RequireWeek. It removes ~5% of the population and is
                  more a data-quality guard than a rule: it catches the case
                  where a gauge reports the morning but the 7-day window is
                  incomplete.

   Temperature is APPARENT (felt), rounded the same way the tiers round it.
   NOTE: the Bitter Cold / Very Cold line is 8F here. The model and the page
   still split at 10F -- fail_rules.txt, TBANDS in _hscript.js and the band
   comment in h05_skiday.sql all say 10. If 8 is the real boundary, those three
   have to move with it or the page will label a 9F day differently from this.
   Sky is percent of OPAQUE cloud, quantised to the 2-point grid before banding,
   for the same reason. Flat light never appears: it is filtered above, being a
   rideability test rather than a sky band.
   ============================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
USE SKI_RESORT;

DECLARE @FreshIn     float = 4.0,   -- inches in 24h that make it a powder day
        @RequireWeek bit   = 1;     -- also require the 5-inch week

DECLARE @Seasons float =
    (SELECT COUNT(DISTINCT CONCAT(ResortId, '-', SeasonStartYear))
     FROM meteo.SkiDay WHERE MONTH(ObsDate) IN (12,1,2,3,4));

IF OBJECT_ID('tempdb..#P') IS NOT NULL DROP TABLE #P;

SELECT
    App = ROUND(d.MeanApparentF, 0),
    Opq = d.OpaquePct,
    TOrd = CASE WHEN ROUND(d.MeanApparentF,0) <   8 THEN 1
                WHEN ROUND(d.MeanApparentF,0) <= 15 THEN 2
                WHEN ROUND(d.MeanApparentF,0) <= 19 THEN 3
                WHEN ROUND(d.MeanApparentF,0) <= 32 THEN 4
                WHEN ROUND(d.MeanApparentF,0) <= 45 THEN 5
                ELSE 6 END,
    SOrd = CASE WHEN d.OpaquePct <=  5.0 THEN 1
                WHEN d.OpaquePct <= 12.5 THEN 2
                WHEN d.OpaquePct <= 37.5 THEN 3
                WHEN d.OpaquePct <= 62.5 THEN 4
                WHEN d.OpaquePct <= 87.5 THEN 5
                ELSE 6 END
INTO #P
FROM meteo.SkiDay d
JOIN meteo.ResortBenchmark b ON b.ResortId = d.ResortId
WHERE MONTH(d.ObsDate) IN (12,1,2,3,4)
  -- rideable: the three things fresh snow cannot buy you out of
  AND d.FlatLightHours <= d.LiftHours / 2.0
  AND d.WindHoldHours  <= d.LiftHours / 2.0
  AND d.RainOnSnow = 0
  AND (@RequireWeek = 0 OR d.IsWeekSnow = 1)
  -- fresh: gauge where there is one, this resort's own model scale otherwise
  AND CASE WHEN d.SnotelNewSnow24In IS NOT NULL
           THEN CASE WHEN d.SnotelNewSnow24In >= @FreshIn THEN 1 ELSE 0 END
           ELSE CASE WHEN CONVERT(float, d.ModelSnow24In) >= b.Snow24Cut4In * (@FreshIn / 4.0)
                      AND d.ModelSnow24In > 0 THEN 1 ELSE 0 END END = 1;

/* ---- the matrix: felt temperature down, sky across ---------------------- */
SELECT
    [Felt temperature] =
        CASE TOrd WHEN 1 THEN '1  Bitter Cold  under 8F'
                  WHEN 2 THEN '2  Very Cold    8-15F'
                  WHEN 3 THEN '3  Chilly       16-19F'
                  WHEN 4 THEN '4  Comfortable  20-32F'
                  WHEN 5 THEN '5  Warm         33-45F'
                  ELSE        '6  Very Warm    over 45F' END,
    Bluebird   = SUM(CASE WHEN SOrd = 1 THEN 1 ELSE 0 END),
    Sunny      = SUM(CASE WHEN SOrd = 2 THEN 1 ELSE 0 END),
    MostlySun  = SUM(CASE WHEN SOrd = 3 THEN 1 ELSE 0 END),
    PartlySun  = SUM(CASE WHEN SOrd = 4 THEN 1 ELSE 0 END),
    MostlyCld  = SUM(CASE WHEN SOrd = 5 THEN 1 ELSE 0 END),
    Cloudy     = SUM(CASE WHEN SOrd = 6 THEN 1 ELSE 0 END),
    [Total]    = COUNT(*),
    PerSeason  = CONVERT(decimal(8,3), COUNT(*) / @Seasons),
    [Pct]      = CONVERT(decimal(5,1), 100.0 * COUNT(*) / SUM(COUNT(*)) OVER ())
FROM #P
GROUP BY TOrd
UNION ALL
SELECT '   ALL BANDS',
    SUM(CASE WHEN SOrd = 1 THEN 1 ELSE 0 END), SUM(CASE WHEN SOrd = 2 THEN 1 ELSE 0 END),
    SUM(CASE WHEN SOrd = 3 THEN 1 ELSE 0 END), SUM(CASE WHEN SOrd = 4 THEN 1 ELSE 0 END),
    SUM(CASE WHEN SOrd = 5 THEN 1 ELSE 0 END), SUM(CASE WHEN SOrd = 6 THEN 1 ELSE 0 END),
    COUNT(*), CONVERT(decimal(8,3), COUNT(*) / @Seasons), 100.0
FROM #P
ORDER BY [Felt temperature];

/* ---- what each candidate line would cost ------------------------------- */
SELECT [Where a line could go] = Label, [Days kept] = Kept,
       [Days cut] = (SELECT COUNT(*) FROM #P) - Kept,
       [Kept per season] = CONVERT(decimal(8,3), Kept / @Seasons),
       [Pct kept] = CONVERT(decimal(5,1), 100.0 * Kept / (SELECT COUNT(*) FROM #P))
FROM (
    SELECT Ord=1, Label='no temperature floor at all',     Kept=CONVERT(float,COUNT(*)) FROM #P
    UNION ALL SELECT 2, 'floor at -10F',  COUNT(*) FROM #P WHERE App >= -10
    UNION ALL SELECT 3, 'floor at   0F',  COUNT(*) FROM #P WHERE App >=   0
    UNION ALL SELECT 4, 'floor at   5F',  COUNT(*) FROM #P WHERE App >=   5
    UNION ALL SELECT 5, 'floor at   8F  (the Very Cold floor)', COUNT(*) FROM #P WHERE App >=  8
    UNION ALL SELECT 6, 'floor at  10F  (B2 as written)', COUNT(*) FROM #P WHERE App >= 10
    UNION ALL SELECT 7, 'floor at  16F  (today''s Good floor)', COUNT(*) FROM #P WHERE App >= 16
) x ORDER BY Ord;

/* ---- and the same for a sky line, if one were ever wanted -------------- */
SELECT [Sky band] =
        CASE SOrd WHEN 1 THEN '1  Bluebird     <=5%'
                  WHEN 2 THEN '2  Sunny        <=12.5%'
                  WHEN 3 THEN '3  Mostly Sunny <=37.5%'
                  WHEN 4 THEN '4  Partly Sunny <=62.5%'
                  WHEN 5 THEN '5  Mostly Cloudy<=87.5%'
                  ELSE        '6  Cloudy       >87.5%' END,
    Days = COUNT(*),
    PerSeason = CONVERT(decimal(8,3), COUNT(*) / @Seasons),
    [Pct] = CONVERT(decimal(5,1), 100.0 * COUNT(*) / SUM(COUNT(*)) OVER ()),
    [Cumulative pct] = CONVERT(decimal(5,1),
        100.0 * SUM(COUNT(*)) OVER (ORDER BY SOrd) / SUM(COUNT(*)) OVER ())
FROM #P GROUP BY SOrd ORDER BY SOrd;
