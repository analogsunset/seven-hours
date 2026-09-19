/* ============================================================================
   The ski day, built from hours.

   This is the whole point of the hourly feed. A daily aggregate cannot tell
   you any of the following, and each of them decides whether a day is worth
   the lift ticket:

     LIFT HOURS ONLY.  Every comfort and light measure below is computed over
     09:00-15:59 local. A daily maximum temperature that occurs at 16:30, or
     sunshine banked at 07:00, is not something you ski in. The files carry
     local time already, so this needs no conversion.

     WIND.  Gusts are what put lifts on hold and what strips the warmth out of
     a day. Across these nine resorts in Dec-Apr, gusts run 18 mph at the
     median and 35 at the 90th percentile, and the wind chill gap between
     TempF and ApparentF averages 7.6 F, reaching 20.3 F.

     BASE DEPTH.  snow_depth answers "is there anything to ski on". It is
     REPORTED but no longer gates a day: IsCovered, ModelBaseFt and
     SnotelBaseFt still ride on every row, and the cards still print the
     elevation band, but a thin base cannot by itself make a day Meh. Neither
     ERA5 nor SNOTEL can see snowmaking, so the test was rejecting days that a
     resort had in fact opened -- it measured natural cover, not whether you
     could ride.

     FLAT LIGHT.  cloud_cover_low is bimodal: median 9%, 90th percentile 96%.
     You are either in clear air or inside the cloud, and inside it you cannot
     read the terrain. That is a different failure from "not sunny", and only
     the low-cloud layer identifies it.

     RAIN ON SNOW.  rain is separate from snowfall here, so the single worst
     thing that can happen to a snowpack is directly observable.

     WHEN THE SNOW FELL.  Powder is what fell overnight and is waiting at
     opening. Snow falling during lift hours adds up but costs visibility. The
     hourly series separates them; a daily total cannot.

   WHAT RELATIVE MEASURES COST. Judging snow per resort fixes the ranking, but
   it also erases real differences in quantity: Angel Fire counts as "covered"
   above 0.23 ft of modelled base while Steamboat's cut is 2.46 ft. Both are
   the 40th percentile of their own record. So read IsCovered as "normal for
   here", never as "as good as there", and keep ModelBaseFt beside it.

   MATERIALISED, not a view. The 72-hour rolling accumulation and the
   per-resort percentile benchmarks are both expensive over 2.13 M hourly rows,
   and recomputing them per query made the trip function unusable. The day
   model is built once into meteo.SkiDay by meteo.usp_BuildSkiDay and indexed;
   the thresholds live in meteo.ResortBenchmark so the numbers a day was judged
   against stay inspectable.

   DEFAULTS are parameters, not decisions baked in. The gust threshold of
   40 mph sits at about the 95th percentile of lift hours here, and flat light
   at 80% low cloud sits above the bimodal split in cloud_cover_low.
   ============================================================================ */

USE SKI_RESORT;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO


/* the built model, and the per-resort thresholds it was judged against */
DROP TABLE IF EXISTS meteo.SkiDay;
DROP TABLE IF EXISTS meteo.ResortBenchmark;
GO
CREATE TABLE meteo.ResortBenchmark
(
    ResortId      int          NOT NULL CONSTRAINT PK_ResortBenchmark PRIMARY KEY,
    /* The snow lines, in MODEL inches. Each is the inch figure a tier asks for,
       converted into this resort's own modelled scale, because modelled
       snowfall runs anywhere from a third of the measured depth gain to half
       again more depending on the resort. A flat model-inch threshold would
       mean two inches at one mountain and eight at another.
       These are NOT percentiles, and the difference is not academic: a
       per-resort percentile hands every mountain the same quota of big-snow
       days however little it snows. Mt. Lemmon averages 10.7 inches for a whole
       season, and its 94.9th-percentile 24h cut computes to 0.17 inches --
       which scored it more Epic days than Alta.
       Resorts with a gauge are tested on the gauge and never read these
       columns; they exist for the 33 shown resorts that have none. */
    Snow24Cut2In  decimal(6,2) NOT NULL,   -- model inches worth 2" measured over 24h
    Snow24Cut4In  decimal(6,2) NOT NULL,   -- ...        worth 4" measured over 24h
    Snow168Cut5In decimal(6,2) NOT NULL,   -- ...        worth 5" measured over a week
    CoverCutFt    decimal(6,2) NOT NULL,   -- modelled depth = 6in of real base here
    CONSTRAINT FK_ResortBenchmark_Resort FOREIGN KEY (ResortId) REFERENCES ref.Resort (ResortId)
);
GO
CREATE TABLE meteo.SkiDay
(
    ResortId int NOT NULL, ObsDate date NOT NULL, SeasonStartYear int NOT NULL, LiftHours int NOT NULL,
    ModelBaseFt decimal(6,2) NULL, ModelOvernightIn decimal(6,2) NULL,
    ModelDaySnowIn decimal(6,2) NULL, ModelSnow72In decimal(6,2) NULL,
    -- the three windows the tiers test, all ending at the opening bell
    ModelSnow24In decimal(6,2) NULL, ModelSnow168In decimal(7,2) NULL,
    DayRainIn decimal(6,2) NULL, RainOnSnow int NOT NULL,
    MeanTempF decimal(5,1) NULL, MinTempF decimal(5,1) NULL, MaxTempF decimal(5,1) NULL,
    MeanApparentF decimal(5,1) NULL, MinApparentF decimal(5,1) NULL,
    MaxApparentF decimal(5,1) NULL, WindChillGapF decimal(5,1) NULL,
    /* SunFraction is REPORTED ONLY as of the 2026-09 tier rewrite -- the sky
       test now runs on OpaquePct. It stays because the tooltip prints it and
       because the clear-sky calibration was done against it.
       OpaquePct is the mean over lift hours of the greater of low and mid
       cloud. High cirrus is deliberately excluded: it is the transparent kind,
       and counting it made 38% of all Dec-Apr days read as fully overcast
       against 25% when it is left out. */
    SunFraction decimal(5,3) NULL, OpaquePct decimal(5,1) NULL,
    FlatLightHours int NOT NULL, BluebirdHours int NOT NULL,
    MaxGustMph decimal(5,1) NULL, MeanGustMph decimal(5,1) NULL, WindHoldHours int NOT NULL,
    IsCovered int NOT NULL,
    /* IsFreshModel is what ERA5 thinks; IsFreshMeasured is what the SNOTEL
       neighbourhood measured, NULL where there are no gauges. IsFresh is the
       one the tiers use, and it defers to measurement wherever it exists --
       a gauge that weighs the snowpack beats a reanalysis of it. The model's
       own verdict is kept so the validation in h20 still compares ERA5 to the
       gauges rather than the gauges to themselves. */
    IsFreshModel int NOT NULL, IsFreshMeasured int NULL,
    FreshSource varchar(8) NOT NULL,
    IsFresh int NOT NULL, IsGood int NOT NULL, IsGreat int NOT NULL,
    /* Epic is Great's second path with 4 inches in place of 2, so it nests
       inside Great by construction rather than by luck.
       Every snow test in the model is now an ABSOLUTE depth, because that is
       the only kind that ranks resorts against each other rather than each
       against itself. A gauge is no longer required: an ungauged resort is
       tested on modelled inches converted to its own scale (ResortBenchmark).
       CAVEAT: measured depth gain under-reads, because the pack settles
       between daily readings, so gauged resorts are held to a slightly harder
       line than ungauged ones. Alta scores below Bear Mountain on Epic for
       this reason and this reason alone. */
    IsEpic int NOT NULL,
    SnotelSwe72In decimal(7,2) NULL, SnotelNewSnow72In decimal(7,1) NULL,
    SnotelNewSnow24In decimal(7,1) NULL, SnotelNewSnow168In decimal(7,1) NULL,
    SnotelBaseFt decimal(6,2) NULL, BaseSource varchar(8) NOT NULL,
    /* FailReason names the FIRST thing wrong, in priority order. FailMask is
       every Good-tier test the day failed, as bit flags, because a day can be
       freezing, blown out and grey at once and saying only "too cold" hides
       two thirds of the story:
         1 rain on snow   2 wind hold        4 flat light
         8 too cold      16 too warm        32 cloudy and cold
       The bits were renumbered in the 2026-09 rewrite -- the retired thin-base
       slot is finally reclaimed. That is only safe because the whole payload
       is regenerated from this table on every build, so there are no archived
       days to relabel; the page, the packer and _hverify.js must move in the
       same commit. */
    FailMask int NOT NULL,
    FailReason varchar(20) NOT NULL,
    CONSTRAINT PK_SkiDay PRIMARY KEY CLUSTERED (ResortId, ObsDate),
    CONSTRAINT FK_SkiDay_Resort FOREIGN KEY (ResortId) REFERENCES ref.Resort (ResortId)
);
GO
CREATE INDEX IX_SkiDay_Season ON meteo.SkiDay (SeasonStartYear, ResortId) INCLUDE (IsGood, IsGreat);
CREATE INDEX IX_SkiDay_Date   ON meteo.SkiDay (ObsDate);
GO
CREATE OR ALTER PROCEDURE meteo.usp_BuildSkiDay
(
    @OpenHour     int   = 9,     -- first lift hour, local
    @CloseHour    int   = 15,    -- last lift hour (15 = through 15:59)
    /* Felt-temperature bands, in rounded degrees F. The tests run on the
       ROUNDED mean, which is also the value shipped to the page, so a day can
       never read 16F on the card and be rejected as too cold.
         under 10  Bitter Cold        20..32  Comfortable
         10..15    Very Cold          33..45  Warm
         16..19    Chilly             over 45 Very Warm                        */
    @MinApparentF float = 16.0,  -- Chilly floor; below it the day is Meh
    @MaxApparentF float = 45.0,  -- above this it is slush
    @ComfortMinF  float = 20.0,  -- Comfortable floor; gates the cloudy days
    @GustHoldMph  float = 40.0,  -- upper lifts likely on hold
    @FlatLightPct int   = 80,    -- low cloud at or above this = cannot read terrain
    /* Sky, as percent of the sky covered by OPAQUE cloud -- the greater of the
       low and mid layers, with high cirrus excluded because it is the
       transparent kind and you can ski under it perfectly well.
         <=5   Bluebird      <=62.5  Partly Sunny
         <=12.5 Sunny        <=87.5  Mostly Cloudy
         <=37.5 Mostly Sunny  >87.5  Cloudy
       Flat light outranks all six and is tested separately.                   */
    @BluebirdPct    float =  5.0,
    @SunnyPct       float = 12.5,
    @MostlySunnyPct float = 37.5,
    @MostlyCloudPct float = 62.5,
    @CloudyPct      float = 87.5,
    /* The snow lines, in MEASURED inches. Resorts with a gauge are tested on
       these directly; resorts without one are tested on the bias-corrected
       equivalents held in meteo.ResortBenchmark. Every window ends at the
       opening bell.
       WIND, meanwhile, is tested on GUSTS and not on sustained speed, despite
       what the rules say in prose. ERA5's 10m wind is a ~25 km grid-cell mean:
       across 4.4 million lift hours it averages 5.3 mph and touches 40.0 mph
       exactly once, so a sustained-40 rule would never fire in 27 winters. The
       gust field (mean 20.3, max 136) is the one carrying mountain wind.       */
    @Snow24GreatIn float = 2.0,  -- 24h fresh for Great's second path
    @Snow24EpicIn  float = 4.0,  -- 24h fresh for Epic
    @Snow168In     float = 5.0,  -- a week of snow, required by BOTH Great paths
    /* Base is a FLOOR, not a ranking. The old rule wanted base above this
       resort's own 40th percentile, which by construction rejected 40% of days
       everywhere -- including 20% of February and 18% of March, midwinter days
       sitting on plenty of snow that were only below-median for the place. The
       question a rider actually asks is "is there enough to ride on", and that
       is absolute.
       It cannot be applied to the modelled feet directly: modelled base runs
       0.38x to 0.95x of measured depth depending on the resort, so one number
       in model-feet would mean 6 inches at one mountain and 16 at another.
       So each resort gets its own cut, being the modelled depth that
       corresponds to @MinRealBaseFt of real settled snow there.
       CAVEAT: neither ERA5 nor SNOTEL can see SNOWMAKING. This measures
       natural base only, and under-rates resorts that manufacture theirs. */
    @MinRealBaseFt float = 0.5,  -- 6 inches of real settled base
    @FallbackBias  float = 0.65  -- model/measured DEPTH ratio where no gauge
                                 -- exists. Depth only -- the three snowFALL
                                 -- ratios are computed separately below and
                                 -- must never be conflated with this one.
)
AS
BEGIN
SET NOCOUNT ON;

TRUNCATE TABLE meteo.SkiDay;
DELETE FROM meteo.ResortBenchmark;

/* How far the modelled base sits below the measured one, per resort. Levels
   are robust (differences are not), so depth is compared as a level against
   the nearest gauge. Resorts with no gauge take the median of those that have
   one. */
DECLARE @Bias TABLE (ResortId int PRIMARY KEY, Ratio float);
INSERT @Bias (ResortId, Ratio)
SELECT h.ResortId,
       SUM(CONVERT(float, h.SnowDepthFt)) / NULLIF(SUM(g.SnowDepthIn / 12.0), 0)
FROM meteo.HourlyObs h
JOIN ref.ResortSnotel x ON x.ResortId = h.ResortId AND x.StationRank = 1
JOIN meteo.SnotelStationDaily g ON g.Triplet = x.Triplet
                               AND g.ObsDate = CONVERT(date, h.ObsHour)
WHERE h.ObsHourOfDay = @OpenHour AND MONTH(h.ObsHour) IN (12,1,2,3,4)
      AND g.SnowDepthIn IS NOT NULL
GROUP BY h.ResortId
HAVING SUM(g.SnowDepthIn / 12.0) > 0;

/* THE THREE MODEL WINDOWS, built once and reused.

   Every window must be built over EVERY hour and only then sampled at the
   opening bell. Filtering to 9am first and windowing after sums separate 9am
   hours spread over as many days: the right mean, but far too smooth a
   distribution. That bug once put the old fresh line ~25% low.

   `1 PRECEDING` rather than `CURRENT ROW` so the window ends at 08:59 and never
   includes the opening hour itself. 24 hours back is therefore 9am yesterday
   to 8am today, which is what "fresh in the last 24 hours" means to a rider
   standing at the base at nine. */
DROP TABLE IF EXISTS #Win;
SELECT z.ResortId,
       ObsDate = CONVERT(date, z.ObsHour),
       M24  = CONVERT(float, z.S24),
       M72  = CONVERT(float, z.S72),
       M168 = CONVERT(float, z.S168)
INTO #Win
FROM (
    SELECT h.ResortId, h.ObsHour, h.ObsHourOfDay,
           S24  = SUM(h.SnowfallIn) OVER (PARTITION BY h.ResortId ORDER BY h.ObsHour
                                          ROWS BETWEEN 24  PRECEDING AND 1 PRECEDING),
           S72  = SUM(h.SnowfallIn) OVER (PARTITION BY h.ResortId ORDER BY h.ObsHour
                                          ROWS BETWEEN 72  PRECEDING AND 1 PRECEDING),
           S168 = SUM(h.SnowfallIn) OVER (PARTITION BY h.ResortId ORDER BY h.ObsHour
                                          ROWS BETWEEN 168 PRECEDING AND 1 PRECEDING)
    FROM meteo.HourlyObs h
) z
WHERE z.ObsHourOfDay = @OpenHour;
CREATE CLUSTERED INDEX CIX_Win ON #Win (ResortId, ObsDate);

/* The measured side. SnotelConsensus carries 24h and 72h already; the week is a
   seven-day rolling sum of its 24h value. The consensus is dated one day BEHIND
   the ski day it describes -- a SNOTEL day ends at local midnight, the model's
   windows end at the lift opening -- so every join below carries the -1 lag
   that h10 established empirically. */
DROP TABLE IF EXISTS #Meas;
SELECT c.ResortId, c.ObsDate, c.Composite, c.BaseFt, c.Swe72In,
       Me24  = CONVERT(float, c.NewSnow24In),
       Me72  = CONVERT(float, c.NewSnow72In),
       Me168 = SUM(CONVERT(float, c.NewSnow24In))
                 OVER (PARTITION BY c.ResortId ORDER BY c.ObsDate
                       ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
INTO #Meas
FROM meteo.SnotelConsensus c;
CREATE CLUSTERED INDEX CIX_Meas ON #Meas (ResortId, ObsDate);

/* How many modelled inches this resort reports per measured inch, per window.
   Two separate ratios, one per window that a tier actually tests; neither is
   the @Bias above, which is a DEPTH ratio. Modelled snowfall is not uniformly low --
   Alta reads about 0.68 of its gauges while Mt. Baker reads about 1.53 -- which
   is exactly why a flat model-inch threshold cannot work. */
DECLARE @SnowBias TABLE (ResortId int PRIMARY KEY, R24 float, R168 float);
INSERT @SnowBias (ResortId, R24, R168)
SELECT w.ResortId,
       SUM(w.M24)  / NULLIF(SUM(m.Me24),  0),
       SUM(w.M168) / NULLIF(SUM(m.Me168), 0)
FROM #Win w
JOIN #Meas m ON m.ResortId = w.ResortId
            AND m.ObsDate  = DATEADD(day, -1, w.ObsDate)
WHERE MONTH(w.ObsDate) IN (12,1,2,3,4)
GROUP BY w.ResortId
HAVING SUM(m.Me24) > 50;

-- median of the gauged resorts, for the ones with no gauge at all
DECLARE @Fb24 float, @Fb168 float;
SELECT TOP 1 @Fb24  = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY R24)  OVER ()
FROM @SnowBias WHERE R24  IS NOT NULL;
SELECT TOP 1 @Fb168 = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY R168) OVER ()
FROM @SnowBias WHERE R168 IS NOT NULL;

INSERT meteo.ResortBenchmark
    (ResortId, Snow24Cut2In, Snow24Cut4In, Snow168Cut5In, CoverCutFt)
SELECT r.ResortId,
       CONVERT(decimal(6,2), @Snow24GreatIn * ISNULL(sb.R24,  @Fb24)),
       CONVERT(decimal(6,2), @Snow24EpicIn  * ISNULL(sb.R24,  @Fb24)),
       CONVERT(decimal(6,2), @Snow168In     * ISNULL(sb.R168, @Fb168)),
       CONVERT(decimal(6,2), @MinRealBaseFt * ISNULL(bi.Ratio, @FallbackBias))
FROM (SELECT DISTINCT ResortId FROM #Win) r
LEFT JOIN @SnowBias sb ON sb.ResortId = r.ResortId
LEFT JOIN @Bias     bi ON bi.ResortId = r.ResortId;

WITH Lift AS
    (
        -- the hours the lifts turn
        SELECT ResortId, ObsDate, TempF, ApparentF, SnowfallIn, SnowDepthFt, RainIn,
               CloudLowPct, CloudMidPct, SunshineSec, Gust10Mph, IsDaylight, ObsHour
        FROM meteo.HourlyObs
        WHERE ObsHourOfDay BETWEEN @OpenHour AND @CloseHour
    ),
    DayAgg AS
    (
        SELECT  ResortId, ObsDate,
                LiftHours   = COUNT(*),
                DaylightHrs = SUM(CONVERT(int, IsDaylight)),
                MeanTempF      = AVG(TempF),
                MeanApparentF  = AVG(ApparentF),
                MinApparentF   = MIN(ApparentF),
                MaxApparentF   = MAX(ApparentF),
                MinTempF       = MIN(TempF),
                MaxTempF       = MAX(TempF),
                WindChillGapF  = AVG(TempF - ApparentF),
                MaxGustMph     = MAX(Gust10Mph),
                MeanGustMph    = AVG(Gust10Mph),
                WindHoldHours  = SUM(CASE WHEN Gust10Mph >= @GustHoldMph THEN 1 ELSE 0 END),
                FlatLightHours = SUM(CASE WHEN CloudLowPct >= @FlatLightPct THEN 1 ELSE 0 END),
                BluebirdHours  = SUM(CASE WHEN CloudLowPct + CloudMidPct <= 30 THEN 1 ELSE 0 END),
                /* Opaque sky cover: the thicker of the two layers you cannot see
                   through, averaged over the lift day. The GREATER of the two,
                   not the sum: the layers are stacked, not laid side by side, so
                   a sum can exceed 100% and would read every broken sky as
                   overcast. High cirrus is excluded because it is the
                   transparent kind -- counting it made 38% of all Dec-Apr days
                   read as fully cloudy against 25% when it is left out. */
                OpaquePct      = AVG(CONVERT(float, CASE WHEN CloudLowPct > CloudMidPct
                                                         THEN CloudLowPct ELSE CloudMidPct END)),
                SunSec         = SUM(SunshineSec),
                DaySnowIn      = SUM(SnowfallIn),
                DayRainIn      = SUM(RainIn),
                RainHours      = SUM(CASE WHEN RainIn > 0 THEN 1 ELSE 0 END)
        FROM Lift
        GROUP BY ResortId, ObsDate
    ),
    AtOpen AS
    (
        -- base depth as the lifts open, not a daily mean
        SELECT ResortId, ObsDate, BaseDepthFt = SnowDepthFt
        FROM meteo.HourlyObs
        WHERE ObsHourOfDay = @OpenHour
    ),
    Overnight AS
    (
        /* Snow waiting at opening: everything that fell from the previous
           day's close through this morning's open. Attributed to the date the
           lifts open on, which is why the hour is shifted forward rather than
           the date shifted back. */
        SELECT ResortId,
               ObsDate = CONVERT(date, DATEADD(hour, 24 - @OpenHour, ObsHour)),
               OvernightSnowIn = SUM(SnowfallIn)
        FROM meteo.HourlyObs
        WHERE ObsHourOfDay > @CloseHour OR ObsHourOfDay < @OpenHour
        GROUP BY ResortId, CONVERT(date, DATEADD(hour, 24 - @OpenHour, ObsHour))
    ),
    /* Everything the tiers read, gathered once. The tier expressions below then
       read as rules rather than as the same arithmetic copied five times, which
       is how the old version drifted: a threshold changed in IsGood and not in
       FailReason, and a card could disagree with its own tooltip. */
    Calc AS
    (
        SELECT a.ResortId, a.ObsDate, a.LiftHours, a.DaylightHrs,
               a.MeanTempF, a.MinTempF, a.MaxTempF,
               a.MeanApparentF, a.MinApparentF, a.MaxApparentF, a.WindChillGapF,
               a.MaxGustMph, a.MeanGustMph, a.WindHoldHours,
               a.FlatLightHours, a.BluebirdHours,
               a.SunSec, a.DaySnowIn, a.DayRainIn,
               o.BaseDepthFt,
               OvernightSnowIn = ISNULL(n.OvernightSnowIn, 0),
               w.M24, w.M72, w.M168,
               m.Me24, m.Me72, m.Me168, m.Composite, m.Swe72In,
               MeasBaseFt = m.BaseFt,
               b.Snow24Cut2In, b.Snow24Cut4In, b.Snow168Cut5In, b.CoverCutFt,
               /* Quantised to the SAME 2-point grid the page ships, and
                  quantised HERE so the tiers, the band label and the printed
                  percentage all read one number. Ship it finer than you test it
                  and a day reads "Mostly cloudy, 88%" against an 87.5 boundary;
                  the sun test had this exact bug and was fixed the same way. */
               OpaquePct = ROUND(a.OpaquePct / 2.0, 0) * 2,
               App   = ROUND(a.MeanApparentF, 0),
               Flat  = CASE WHEN a.FlatLightHours > a.LiftHours / 2.0 THEN 1 ELSE 0 END,
               -- gusts over HALF the lift day now, not a single hour of it
               Blown = CASE WHEN a.WindHoldHours  > a.LiftHours / 2.0 THEN 1 ELSE 0 END,
               Wet   = CASE WHEN a.DayRainIn > 0.01 AND o.BaseDepthFt > 0.25 THEN 1 ELSE 0 END
        FROM DayAgg a
        JOIN AtOpen o         ON o.ResortId = a.ResortId AND o.ObsDate = a.ObsDate
        LEFT JOIN Overnight n ON n.ResortId = a.ResortId AND n.ObsDate = a.ObsDate
        JOIN #Win w           ON w.ResortId = a.ResortId AND w.ObsDate = a.ObsDate
        JOIN meteo.ResortBenchmark b ON b.ResortId = a.ResortId
        -- -1 lag: a SNOTEL day ends at local midnight, the model's windows end
        -- at the lift opening. Established empirically in h10.
        LEFT JOIN #Meas m     ON m.ResortId = a.ResortId
                             AND m.ObsDate  = DATEADD(day, -1, a.ObsDate)
    ),
    /* The snow tests. Measured wherever a gauge reported that day, modelled
       otherwise -- a gauge that weighs the snowpack beats a reanalysis of it.
       The modelled side is compared against this resort's own bias-corrected
       equivalent of the same inch figure, never against a percentile. */
    Flags AS
    (
        SELECT c.*,
            S24_2  = CASE WHEN c.Me24 IS NOT NULL
                          THEN CASE WHEN c.Me24 >= @Snow24GreatIn THEN 1 ELSE 0 END
                          ELSE CASE WHEN c.M24  >= c.Snow24Cut2In  AND c.M24  > 0 THEN 1 ELSE 0 END END,
            S24_4  = CASE WHEN c.Me24 IS NOT NULL
                          THEN CASE WHEN c.Me24 >= @Snow24EpicIn THEN 1 ELSE 0 END
                          ELSE CASE WHEN c.M24  >= c.Snow24Cut4In  AND c.M24  > 0 THEN 1 ELSE 0 END END,
            S168_5 = CASE WHEN c.Me168 IS NOT NULL
                          THEN CASE WHEN c.Me168 >= @Snow168In THEN 1 ELSE 0 END
                          ELSE CASE WHEN c.M168 >= c.Snow168Cut5In AND c.M168 > 0 THEN 1 ELSE 0 END END,
            -- every test that has nothing to do with sky or snow
            Ride   = CASE WHEN ROUND(c.MeanApparentF, 0) >= @MinApparentF
                           AND ROUND(c.MeanApparentF, 0) <= @MaxApparentF
                           AND c.Flat = 0 AND c.Blown = 0 AND c.Wet = 0
                      THEN 1 ELSE 0 END
        FROM Calc c
    ),
    /* ---- the tiers ----
       GOOD   rideable, and if the sky is Mostly Cloudy or worse then
              Comfortable or better as well
       GREAT  a 5-inch week, PLUS either sun and comfort, or 2 inches today
       EPIC   Great's second path with 4 inches in place of 2

       They nest by construction rather than by coincidence: both Great paths
       satisfy Good's cloud clause, and Epic is a strict tightening of Great's
       second path. The verification asserts this rather than trusting it.      */
    Tiers AS
    (
        SELECT f.*,
            Good = CASE WHEN f.Ride = 1
                         AND (f.OpaquePct <= @MostlyCloudPct OR f.App >= @ComfortMinF)
                    THEN 1 ELSE 0 END,
            Great = CASE WHEN f.Ride = 1 AND f.S168_5 = 1
                          AND ( (f.App >= @ComfortMinF AND f.OpaquePct <= @MostlySunnyPct)
                             OR ((f.OpaquePct <= @SunnyPct OR f.App >= @ComfortMinF)
                                  AND f.S24_2 = 1) )
                     THEN 1 ELSE 0 END,
            Epic  = CASE WHEN f.Ride = 1 AND f.S168_5 = 1
                          AND (f.OpaquePct <= @SunnyPct OR f.App >= @ComfortMinF)
                          AND f.S24_4 = 1
                     THEN 1 ELSE 0 END
        FROM Flags f
    )
INSERT meteo.SkiDay
    (ResortId, ObsDate, SeasonStartYear, LiftHours,
     ModelBaseFt, ModelOvernightIn, ModelDaySnowIn, ModelSnow72In, ModelSnow24In, ModelSnow168In,
     DayRainIn, RainOnSnow,
     MeanTempF, MinTempF, MaxTempF, MeanApparentF, MinApparentF, MaxApparentF, WindChillGapF,
     SunFraction, OpaquePct, FlatLightHours, BluebirdHours,
     MaxGustMph, MeanGustMph, WindHoldHours,
     IsCovered, IsFreshModel, IsFreshMeasured, FreshSource, IsFresh,
     SnotelSwe72In, SnotelNewSnow72In, SnotelNewSnow24In, SnotelNewSnow168In,
     SnotelBaseFt, BaseSource, IsGood, IsGreat, IsEpic, FailReason, FailMask)
    SELECT  t.ResortId,
            t.ObsDate,
            SeasonStartYear = CASE WHEN MONTH(t.ObsDate) >= 7
                                   THEN YEAR(t.ObsDate) ELSE YEAR(t.ObsDate) - 1 END,
            t.LiftHours,

            /* ---- surface ---- */
            ModelBaseFt      = CONVERT(decimal(6,2), t.BaseDepthFt),
            ModelOvernightIn = CONVERT(decimal(6,2), t.OvernightSnowIn),
            ModelDaySnowIn   = CONVERT(decimal(6,2), t.DaySnowIn),
            ModelSnow72In    = CONVERT(decimal(6,2), ISNULL(t.M72,  0)),
            ModelSnow24In    = CONVERT(decimal(6,2), ISNULL(t.M24,  0)),
            ModelSnow168In   = CONVERT(decimal(7,2), ISNULL(t.M168, 0)),
            DayRainIn        = CONVERT(decimal(6,2), t.DayRainIn),
            RainOnSnow       = t.Wet,

            /* ---- comfort ---- */
            MeanTempF      = CONVERT(decimal(5,1), t.MeanTempF),
            MinTempF       = CONVERT(decimal(5,1), t.MinTempF),
            MaxTempF       = CONVERT(decimal(5,1), t.MaxTempF),
            MeanApparentF  = CONVERT(decimal(5,1), t.MeanApparentF),
            MinApparentF   = CONVERT(decimal(5,1), t.MinApparentF),
            MaxApparentF   = CONVERT(decimal(5,1), t.MaxApparentF),
            WindChillGapF  = CONVERT(decimal(5,1), t.WindChillGapF),

            /* ---- light and wind ---- */
            SunFraction    = CONVERT(decimal(5,3),
                                     t.SunSec / NULLIF(t.DaylightHrs * 3600.0, 0)),
            OpaquePct      = CONVERT(decimal(5,1), t.OpaquePct),
            FlatLightHours = t.FlatLightHours,
            BluebirdHours  = t.BluebirdHours,
            MaxGustMph     = CONVERT(decimal(5,1), t.MaxGustMph),
            MeanGustMph    = CONVERT(decimal(5,1), t.MeanGustMph),
            WindHoldHours  = t.WindHoldHours,

            /* ---- snow provenance ----
               IsFresh* now mean "2 inches in 24 hours", the line Great's second
               path tests, rather than the retired 80th-percentile fresh line.
               h20 scores IsFreshModel against the gauges, so the kappa printed
               on the cards now answers the question the tiers actually ask.    */
            IsCovered = CASE WHEN t.MeasBaseFt IS NOT NULL
                            THEN CASE WHEN t.MeasBaseFt >= @MinRealBaseFt THEN 1 ELSE 0 END
                            ELSE CASE WHEN t.BaseDepthFt >= t.CoverCutFt
                                       AND t.BaseDepthFt > 0.10 THEN 1 ELSE 0 END END,
            IsFreshModel = CASE WHEN ISNULL(t.M24, 0) >= t.Snow24Cut2In
                                 AND ISNULL(t.M24, 0) > 0 THEN 1 ELSE 0 END,
            IsFreshMeasured = CASE WHEN t.Me24 IS NULL THEN NULL
                                   WHEN t.Me24 >= @Snow24GreatIn THEN 1 ELSE 0 END,
            FreshSource = CASE WHEN t.Me24 IS NULL THEN 'modelled' ELSE 'measured' END,
            IsFresh     = t.S24_2,
            SnotelSwe72In      = CONVERT(decimal(7,2), t.Swe72In),
            SnotelNewSnow72In  = CONVERT(decimal(7,1), t.Me72),
            SnotelNewSnow24In  = CONVERT(decimal(7,1), t.Me24),
            SnotelNewSnow168In = CONVERT(decimal(7,1), t.Me168),
            SnotelBaseFt = CONVERT(decimal(6,2), t.MeasBaseFt),
            BaseSource   = CASE WHEN t.MeasBaseFt IS NULL THEN 'modelled' ELSE 'measured' END,

            IsGood  = t.Good,
            IsGreat = t.Great,
            IsEpic  = t.Epic,

            /* Why the day is not Great, first reason only, in priority order.
               The six that make a day Meh come first, then the two that stop a
               rideable day short of Great. */
            FailReason = CASE
                WHEN t.Wet   = 1                        THEN 'Rain on snow'
                WHEN t.Blown = 1                        THEN 'Wind hold'
                WHEN t.Flat  = 1                        THEN 'Flat light'
                WHEN t.App < @MinApparentF              THEN 'Too cold'
                WHEN t.App > @MaxApparentF              THEN 'Too warm'
                WHEN t.OpaquePct > @MostlyCloudPct
                 AND t.App < @ComfortMinF               THEN 'Cloudy and cold'
                WHEN t.S168_5 = 0                       THEN 'No week snow'
                WHEN t.Great = 0 AND t.S24_2 = 0        THEN 'No fresh snow'
                WHEN t.Great = 0                        THEN 'Grey'
                ELSE 'Great' END,

            /* Every Good-tier test the day failed, not just the first to trip.
               About a third of Meh days trip more than one. */
            FailMask =
                  CASE WHEN t.Wet   = 1 THEN 1 ELSE 0 END
                + CASE WHEN t.Blown = 1 THEN 2 ELSE 0 END
                + CASE WHEN t.Flat  = 1 THEN 4 ELSE 0 END
                + CASE WHEN t.App < @MinApparentF THEN 8 ELSE 0 END
                + CASE WHEN t.App > @MaxApparentF THEN 16 ELSE 0 END
                + CASE WHEN t.OpaquePct > @MostlyCloudPct
                        AND t.App < @ComfortMinF THEN 32 ELSE 0 END
    FROM Tiers t
;
END
GO

CREATE OR ALTER VIEW meteo.vSkiDay
AS
SELECT d.*, r.ResortName, r.StateOrProv, r.Region, r.MidElevationFt,
       r.GreenPercent, r.GreenAcres, r.PeakDayTicketUsd, r.Acres, r.VerticalFt,
       b.Snow24Cut2In, b.Snow24Cut4In, b.Snow168Cut5In, b.CoverCutFt
FROM meteo.SkiDay d
JOIN ref.Resort r            ON r.ResortId = d.ResortId
JOIN meteo.ResortBenchmark b ON b.ResortId = d.ResortId;
GO

/* ---------------------------------------------------------------------------
   The snow-provenance view lives here, not in h20, and is recreated every time
   this script runs. It is SELECT d.*, which SQL Server resolves ONCE at create
   time: add a column to meteo.SkiDay above and the view goes on serving the old
   column list until it is rebuilt. Keeping it beside the table makes that
   impossible to forget.

   It reads meteo.SnotelConsensus and meteo.SnotelBenchmark, so run h20 first on
   a fresh database.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW meteo.vSkiDaySnow
AS
SELECT  d.*,
        r.ResortName,
        /* What the sky looked like, in percent of it covered by OPAQUE cloud.
           Flat light outranks all six bands because a bright overcast you
           cannot read terrain through is the condition that actually ruins the
           skiing, and it is the one sky state that makes a day Meh outright.

           The bands run on the SAME quantised value the tiers tested and the
           page ships, so a label can never contradict the percentage
           printed beside it -- the failure this replaced, where a day could
           read "Clear" next to a sun figure that said otherwise. */
        Visibility = CASE
            WHEN d.FlatLightHours > d.LiftHours / 2.0 THEN 'Flat light'
            WHEN d.OpaquePct <=  5.0 THEN 'Bluebird'
            WHEN d.OpaquePct <= 12.5 THEN 'Sunny'
            WHEN d.OpaquePct <= 37.5 THEN 'Mostly sunny'
            WHEN d.OpaquePct <= 62.5 THEN 'Partly sunny'
            WHEN d.OpaquePct <= 87.5 THEN 'Mostly cloudy'
            ELSE 'Cloudy' END,
        SnowSource     = CASE WHEN sb.ResortId IS NULL THEN 'modelled' ELSE 'measured' END,
        GaugeCount     = sb.Stations,
        NearestKm      = sb.NearestKm,
        SnotelSwe72Rel = CASE WHEN sb.FreshCut > 0 THEN c.Composite / sb.FreshCut END,
        SnotelIsFresh  = CASE WHEN c.Composite IS NULL THEN NULL
                              WHEN c.Composite >= sb.FreshCut AND c.Composite > 0 THEN 1 ELSE 0 END
FROM meteo.SkiDay d
JOIN ref.Resort r ON r.ResortId = d.ResortId
LEFT JOIN meteo.SnotelBenchmark sb ON sb.ResortId = d.ResortId
LEFT JOIN meteo.SnotelConsensus c  ON c.ResortId  = d.ResortId
                                  AND c.ObsDate   = DATEADD(day, -1, d.ObsDate);
GO

EXEC meteo.usp_BuildSkiDay;
GO

SELECT Days = COUNT(*), Resorts = COUNT(DISTINCT ResortId),
       Seasons = COUNT(DISTINCT SeasonStartYear) FROM meteo.SkiDay;
GO
