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
    Snow72Cut5In  decimal(6,2) NOT NULL,   -- ...        worth 5" measured over 72h
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
    /* The two MEANS carry three decimals; the mins and maxes stay at one.
       A mean rounded to 0.1 and then rounded again to a whole degree is not the
       same number as the mean rounded once: 19.457 stores as 19.5 and displays
       as 20, while the tier test on the unrounded mean says 19. That split put
       a different integer on the card than the model had judged on 78,304 days,
       4,647 of them across a tier boundary -- a card reading "Comfortable,
       20F" on a day rejected for being Chilly.
       Min and Max are MIN()/MAX() of values already stored at 0.1, so they lose
       nothing and stay as they are. */
    MeanTempF decimal(6,3) NULL, MinTempF decimal(5,1) NULL, MaxTempF decimal(5,1) NULL,
    MeanApparentF decimal(6,3) NULL, MinApparentF decimal(5,1) NULL,
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
    IsFresh int NOT NULL,
    /* Did the 5-inch week clear -- measured where a gauge reported, modelled
       otherwise. STORED rather than left implicit because both page builds used
       to re-derive it in their own language, and the hosted one got it wrong:
       it read modelled snow only, so a gauged resort's card disagreed with its
       own tiers on 98,896 days. Worse, the verifier re-derived it the same
       wrong way and passed. SQL decides; everything downstream serialises. */
    IsWeekSnow int NOT NULL,
    IsGood int NOT NULL, IsGreat int NOT NULL,
    /* EPIC IS NOT THE TOP OF THE LADDER. It is a separate verdict -- a
       rideable powder day -- and it does NOT nest inside Good or Great. It
       accepts a day down to 8F where Good stops at 16F, and it lets Chilly
       through heavy cloud where Good asks for Comfortable. 7,293 days across
       the record are Epic without being Good, and they are the biggest days
       in it: 37 inches at Taos at 12F, the whole Tahoe basin under 30 inches
       on 2023-01-01. Anything reading these three flags as a ladder must read
       Epic FIRST -- which is what every consumer already does, since a day's
       tier is derived as epic ? 3 : great ? 2 : good ? 1 : 0.
       Every snow test in the model is an ABSOLUTE depth, because that is
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
    /* What a day that CLEARED its tier fell short of on the next one up.
       FailMask answers "why is this Meh"; MissMask answers "why is this only
       Good" and "why is this only Great", which the tooltip had no way to say:
         1  no 5-inch week            (a Good day)
         2  nothing fresh, and not sunny and comfortable enough without it
                                      (a Good day)
         4  under 4 inches this morning   (ANY non-Epic day that cleared every
                                          other Epic test -- Meh days included)
       Bits 1 and 2 are set only on Good days. Bit 4 is set at whatever tier
       the day landed in, because Epic no longer sits at the top of a ladder:
       a Meh day can be one morning short of it. Epic itself sets nothing.    */
    MissMask int NOT NULL,
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
    /* Felt-temperature bands, in rounded degrees F. The tests run on
       ROUND(MeanApparentF, 0), and MeanApparentF is stored at the precision it
       was computed at, so the integer the page prints is the integer the rule
       judged. That was not true until 2026-09-19: the mean was stored at one
       decimal and rounded again for display, so 19.457 was tested as 19 and
       printed as 20.
         under 8   Bitter Cold        20..32  Comfortable
         8..15     Very Cold          33..45  Warm
         16..19    Chilly             over 45 Very Warm                        */
    @MinApparentF float = 16.0,  -- Chilly floor; below it an ordinary day is Meh
    /* EPIC's own floor, and the reason it exists: four inches of new snow buys
       eight degrees of tolerance. The 16F line is about whether a day is
       ENJOYABLE, which is the right question for Good and Great and the wrong
       one for a powder morning -- it was ranking 30.8 inches of gauge-measured
       snow at 14F under a 14% sky as Meh (Alpine Meadows, 2023-01-01), on a
       FailMask of 8: one bit, too cold, and nothing else wrong at all.
       8F is the bottom of Very Cold, not an arbitrary softening: below it the
       day is Bitter Cold and no amount of snow is claimed to fix that. */
    @EpicMinF     float =  8.0,  -- Very Cold floor; EPIC only
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
    @Snow24GreatIn float = 2.0,  -- 24h fresh, the first door on Great's snow path
    @Snow24EpicIn  float = 4.0,  -- 24h fresh for Epic
    @Snow72In      float = 5.0,  -- 72h fresh, the second door on the same path
    @Snow168In     float = 5.0,  -- a week of snow, required by EVERY Great path
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
       /* Seven COMPLETE CONSECUTIVE days or nothing. SUM() skips NULLs, and
          ROWS counts rows rather than dates, so the obvious version returns a
          three-day total as a week whenever the consensus has gaps -- an
          under-count wearing a measurement's label, which then fails the 5-inch
          test instead of deferring to the model. COUNT() says how many of the
          seven are real; DATEDIFF against the frame's first date says whether
          they are consecutive. */
       Me168 = CASE
           WHEN COUNT(c.NewSnow24In) OVER (PARTITION BY c.ResortId ORDER BY c.ObsDate
                                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) = 7
            AND DATEDIFF(day, MIN(c.ObsDate) OVER (PARTITION BY c.ResortId ORDER BY c.ObsDate
                                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),
                         c.ObsDate) = 6
           THEN SUM(CONVERT(float, c.NewSnow24In))
                OVER (PARTITION BY c.ResortId ORDER BY c.ObsDate
                      ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
           END
INTO #Meas
FROM meteo.SnotelConsensus c;
CREATE CLUSTERED INDEX CIX_Meas ON #Meas (ResortId, ObsDate);

/* How many modelled inches this resort reports per measured inch, per window.
   Two separate ratios, one per window that a tier actually tests; neither is
   the @Bias above, which is a DEPTH ratio. Modelled snowfall is not uniformly low --
   Alta reads about 0.68 of its gauges while Mt. Baker reads about 1.53 -- which
   is exactly why a flat model-inch threshold cannot work. */
DECLARE @SnowBias TABLE (ResortId int PRIMARY KEY, R24 float, R72 float, R168 float);
INSERT @SnowBias (ResortId, R24, R72, R168)
/* Numerator and denominator over the SAME days. SUM() drops NULLs on each side
   independently, so a day the model saw but the gauge did not would add to the
   modelled total and nothing to the measured one -- inflating every ratio, and
   with it the model-inch thresholds the ungauged resorts are judged against.
   Matters far more now that a missing reading is honestly NULL. */
SELECT w.ResortId,
       SUM(CASE WHEN m.Me24  IS NOT NULL THEN w.M24  END) / NULLIF(SUM(m.Me24),  0),
       SUM(CASE WHEN m.Me72  IS NOT NULL THEN w.M72  END) / NULLIF(SUM(m.Me72),  0),
       SUM(CASE WHEN m.Me168 IS NOT NULL THEN w.M168 END) / NULLIF(SUM(m.Me168), 0)
FROM #Win w
JOIN #Meas m ON m.ResortId = w.ResortId
            AND m.ObsDate  = DATEADD(day, -1, w.ObsDate)
WHERE MONTH(w.ObsDate) IN (12,1,2,3,4)
GROUP BY w.ResortId
HAVING SUM(m.Me24) > 50;

-- median of the gauged resorts, for the ones with no gauge at all
DECLARE @Fb24 float, @Fb72 float, @Fb168 float;
SELECT TOP 1 @Fb24  = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY R24)  OVER ()
FROM @SnowBias WHERE R24  IS NOT NULL;
SELECT TOP 1 @Fb72  = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY R72)  OVER ()
FROM @SnowBias WHERE R72  IS NOT NULL;
SELECT TOP 1 @Fb168 = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY R168) OVER ()
FROM @SnowBias WHERE R168 IS NOT NULL;

INSERT meteo.ResortBenchmark
    (ResortId, Snow24Cut2In, Snow24Cut4In, Snow72Cut5In, Snow168Cut5In, CoverCutFt)
SELECT r.ResortId,
       CONVERT(decimal(6,2), @Snow24GreatIn * ISNULL(sb.R24,  @Fb24)),
       CONVERT(decimal(6,2), @Snow24EpicIn  * ISNULL(sb.R24,  @Fb24)),
       CONVERT(decimal(6,2), @Snow72In      * ISNULL(sb.R72,  @Fb72)),
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
                /* Converted HERE, not on the way into the table, so that the
                   value the tiers test and the value the page prints are
                   literally the same number rather than two roundings of it. */
                MeanTempF      = CONVERT(decimal(6,3), AVG(TempF)),
                MeanApparentF  = CONVERT(decimal(6,3), AVG(ApparentF)),
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
               b.Snow24Cut2In, b.Snow24Cut4In, b.Snow72Cut5In, b.Snow168Cut5In, b.CoverCutFt,
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
            S72_5  = CASE WHEN c.Me72 IS NOT NULL
                          THEN CASE WHEN c.Me72 >= @Snow72In THEN 1 ELSE 0 END
                          ELSE CASE WHEN c.M72  >= c.Snow72Cut5In AND c.M72  > 0 THEN 1 ELSE 0 END END,
            S168_5 = CASE WHEN c.Me168 IS NOT NULL
                          THEN CASE WHEN c.Me168 >= @Snow168In THEN 1 ELSE 0 END
                          ELSE CASE WHEN c.M168 >= c.Snow168Cut5In AND c.M168 > 0 THEN 1 ELSE 0 END END,
            /* SAFE is the three things no amount of snow can buy you out of:
               you cannot read the terrain, the upper lifts are on hold, or it
               rained on the pack. Kept apart from the temperature window
               because EPIC accepts a colder day than Good does, and only the
               temperature differs between them. */
            Safe   = CASE WHEN c.Flat = 0 AND c.Blown = 0 AND c.Wet = 0
                      THEN 1 ELSE 0 END,
            -- SAFE plus the temperature window an ordinary day is judged on
            Ride   = CASE WHEN ROUND(c.MeanApparentF, 0) >= @MinApparentF
                           AND ROUND(c.MeanApparentF, 0) <= @MaxApparentF
                           AND c.Flat = 0 AND c.Blown = 0 AND c.Wet = 0
                      THEN 1 ELSE 0 END
        FROM Calc c
    ),
    /* ---- the tiers ----
       GOOD   rideable, and if the sky is Mostly Cloudy or worse then
              Comfortable or better as well
       GREAT  a GOOD day, a 5-inch week, and then EITHER sun and comfort
              (which is what carries a day with nothing fresh on it) OR snow:
              2 inches this morning, or 5 over three days
       EPIC   a RIDEABLE POWDER DAY: safe, 8F or better, a 5-inch week, and
              4 inches this morning -- plus, if it is Very Cold, Partly Sunny
              or better

       NOTHING NESTS ANY MORE. Great's 24-hour branch reaches to 8F where Good
       stops at 16F, so a day can be Great without being Good -- 9,116 of them
       are. Epic was already outside. The three flags are now three separate
       verdicts and only the display orders them, as epic ? 3 : great ? 2 :
       good ? 1 : 0. Anything that treats one as implying another is wrong.

       EPIC DELIBERATELY DOES NOT. It is not the top rung of the ladder any
       more; it is a separate verdict about the snow, and it answers a
       different question -- not "was this a nice day" but "was this a powder
       day you could ride". So it accepts two kinds of day Good rejects:

         - VERY COLD, 8..15F.  4,586 days. The floor at 16F is a comfort line,
           and comfort is not what Epic is measuring. Taos on 2005-02-27 had
           37 inches of measured snow at 12F under a 36% sky and scored Meh.
         - CHILLY UNDER HEAVY CLOUD.  2,707 days. Good wants Comfortable once
           the sky passes 62.5%; Epic asks only that you are not Very Cold.

       Those two populations are exactly the days the MEH reasons now waive
       (see FailReason below), so no Epic day is ever labelled Meh -- 7,293
       days that used to be.

       The COLD LADDER is monotone, which is the property worth checking:
       Bitter Cold never qualifies at all; Very Cold must be Partly Sunny or
       better; Chilly and up need no sky at all. The colder the day, the more
       light it has to be given before snow can carry it.                      */
    Tiers AS
    (
        SELECT f.*,
            Good = CASE WHEN f.Ride = 1
                         AND (f.OpaquePct <= @MostlyCloudPct OR f.App >= @ComfortMinF)
                    THEN 1 ELSE 0 END,
            /* Written as three explicit branches rather than one gate and a
               choice of snow tests, because the branches no longer share a
               temperature floor: the 24-hour one reaches down into Very Cold
               and the other two do not. Collapsing them again would lose that.

               BRANCH 2 IS WHY GREAT NO LONGER NESTS INSIDE GOOD. Good stops at
               16F; this reaches 8F, so 9,116 of the 9,124 days it adds are
               days Good rejects -- 4,584 of them already Epic, 4,532 of them
               presently Meh. Whistler on 2018-02-24 is the case it was written
               for: 10F felt under 2% cloud, a 5-inch week, and 1.46 modelled
               inches against a 1.42-inch line.

               BOTH SNOW BRANCHES NOW SHARE THE 8F FLOOR. Branch 3 kept 16F
               for a single build and the asymmetry it produced was the
               argument against it: 9,865 Very Cold days had five inches down
               over three days, no 2-inch morning, and were rejected while
               thinner days were taken. Only branch 1 keeps a higher floor,
               and it has to -- nothing fresh has fallen, so comfort and sun
               are the entire case for the day. */
            Great = CASE WHEN f.Safe = 1 AND f.S168_5 = 1
                          AND (
                               /* nothing fresh: sun and comfort carry the day */
                               (f.App >= @ComfortMinF AND f.App <= @MaxApparentF
                                AND f.OpaquePct <= @MostlySunnyPct)
                               /* 2 inches this morning -- Very Cold admitted,
                                  under Good's own cloud clause */
                            OR (f.App >= @EpicMinF AND f.App <= @MaxApparentF
                                AND (f.OpaquePct <= @MostlyCloudPct
                                     OR f.App >= @ComfortMinF)
                                AND f.S24_2 = 1)
                               /* 5 inches over three days -- same floor as the
                                  24-hour branch since 2026-09-20. It kept 16F
                                  for one build, which rejected 9,865 Very Cold
                                  days that had five inches down over three days
                                  but no 2-inch morning: more snow on the ground,
                                  lower tier. */
                            OR (f.App >= @EpicMinF AND f.App <= @MaxApparentF
                                AND (f.OpaquePct <= @MostlyCloudPct
                                     OR f.App >= @ComfortMinF)
                                AND f.S72_5 = 1)
                              )
                     THEN 1 ELSE 0 END,
            Epic  = CASE WHEN f.Safe = 1
                          AND f.App >= @EpicMinF
                          AND f.App <= @MaxApparentF
                          -- Very Cold has to be given Partly Sunny or better
                          AND (f.App >= @MinApparentF OR f.OpaquePct <= @MostlyCloudPct)
                          AND f.S168_5 = 1
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
     IsCovered, IsFreshModel, IsFreshMeasured, FreshSource, IsFresh, IsWeekSnow,
     SnotelSwe72In, SnotelNewSnow72In, SnotelNewSnow24In, SnotelNewSnow168In,
     SnotelBaseFt, BaseSource, IsGood, IsGreat, IsEpic, FailReason, FailMask, MissMask)
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
            MeanTempF      = t.MeanTempF,
            MinTempF       = CONVERT(decimal(5,1), t.MinTempF),
            MaxTempF       = CONVERT(decimal(5,1), t.MaxTempF),
            MeanApparentF  = t.MeanApparentF,
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
               CAVEAT, and the cards overstate this: h20 still scores
               IsFreshModel against its OWN target -- the 80th percentile of a
               72-hour SWE composite -- which is not the event this flag now
               describes. So the kappa and recall printed on each card measure
               "does ERA5 find the snowy stretches", not "does ERA5 agree about
               a 2-inch morning". Retargeting h20 at NewSnow24In >= 2.0 would
               make the figure mean what the card implies.                      */
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
            IsWeekSnow  = t.S168_5,
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
               The six that make a day Meh come first, then the ones that stop a
               Good day short of Great.
               'Grey' IS NOW UNREACHABLE and kept only so the packed reason
               indexes do not shift. It used to fire when a day had the snow and
               the cold but too much cloud -- which is precisely the case the
               tiers above stopped rejecting. A Good day that holds the week and
               is not Great now always lacks fresh snow, so 'No fresh snow'
               catches every one of them. The ordinal array in h07_pack.py,
               _hscript.js and both verifiers must keep the slot regardless. */
            FailReason = CASE
                /* EPIC OR GREAT FIRST, and this one line carries both waivers
                   the rules ask for: "Too Cold ... AND not EPIC" and "Cloudy
                   and Cold ... AND not EPIC". Neither is ever labelled Meh.
                   GREAT joined EPIC here on 2026-09-20, when its 24-hour
                   branch was allowed down to 8F: without it, 4,532 days that
                   the tiers call Great would carry FailReason 'Too cold' and
                   be counted as such in the failure panel. The rules do not
                   spell this out -- their MEH list only excepts EPIC -- but
                   FailReason answers "why is this day not Great", so for a day
                   that IS Great the answer can only be 'nothing'.
                   It is safe at the top of the chain because Epic requires
                   Safe = 1, so the three rows below it are already 0.
                   'Great' is this list's index-0 sentinel meaning NOTHING WENT
                   WRONG, not a claim that the day was Great -- an Epic day that
                   is Very Cold is not Great and never will be. Without this
                   branch such a day falls through every row and lands on
                   'Grey', which says "too much cloud" about days that are
                   Bluebird as often as not. */
                WHEN t.Epic = 1 OR t.Great = 1          THEN 'Great'
                WHEN t.Wet   = 1                        THEN 'Rain on snow'
                WHEN t.Blown = 1                        THEN 'Wind hold'
                WHEN t.Flat  = 1                        THEN 'Flat light'
                WHEN t.App < @MinApparentF              THEN 'Too cold'
                WHEN t.App > @MaxApparentF              THEN 'Too warm'
                WHEN t.OpaquePct > @MostlyCloudPct
                 AND t.App < @ComfortMinF               THEN 'Cloudy and cold'
                WHEN t.S168_5 = 0                       THEN 'No week snow'
                WHEN t.Great = 0 AND t.S24_2 = 0
                                 AND t.S72_5 = 0        THEN 'No fresh snow'
                WHEN t.Great = 0                        THEN 'Grey'
                ELSE 'Great' END,

            /* Every Good-tier test the day failed, not just the first to trip.
               About a third of Meh days trip more than one.
               NOT waived for Epic days, unlike FailReason above: this is the
               factual record of which Good-tier tests a day failed, and an Epic
               day at 12F did fail the 16F one. The page only renders it on Meh
               days, so the distinction never reaches a reader -- except through
               bit 2, which paints the wind-hold edge, and no Epic day sets it. */
            FailMask =
                  CASE WHEN t.Wet   = 1 THEN 1 ELSE 0 END
                + CASE WHEN t.Blown = 1 THEN 2 ELSE 0 END
                + CASE WHEN t.Flat  = 1 THEN 4 ELSE 0 END
                + CASE WHEN t.App < @MinApparentF THEN 8 ELSE 0 END
                + CASE WHEN t.App > @MaxApparentF THEN 16 ELSE 0 END
                + CASE WHEN t.OpaquePct > @MostlyCloudPct
                        AND t.App < @ComfortMinF THEN 32 ELSE 0 END,

            /* The same idea one tier up: what a day that cleared its tier fell
               short of on the next. Written against the tier expressions above
               rather than re-deriving them, so the two cannot drift.
               Unchanged by B2, and it needs no Epic clause: 4 inches implies 2
               (the modelled cut for 4 is exactly twice the cut for 2 at every
               resort), so a day that is both Good and Epic is necessarily also
               Great -- there is no Good-but-not-Great Epic day for bits 1 and 2
               to mislabel. */
            MissMask =
                  CASE WHEN t.Good = 1 AND t.Great = 0
                        AND t.S168_5 = 0 THEN 1 ELSE 0 END
                + CASE WHEN t.Good = 1 AND t.Great = 0
                        AND NOT ((t.App >= @ComfortMinF AND t.OpaquePct <= @MostlySunnyPct)
                                 OR t.S24_2 = 1 OR t.S72_5 = 1) THEN 2 ELSE 0 END
                /* Bit 4 is 'everything EPIC asks for except the morning',
                   not 'a Great day that fell short'. It read the latter until
                   2026-09-20, which was the ladder assumption surviving in a
                   model that no longer has one: Epic is reachable straight
                   from Meh, so a Meh day can be one test from the top and say
                   nothing. 56,131 days were exactly that -- safe, warm
                   enough, clear enough, a 5-inch week behind them, short only
                   of 4 inches that morning. Whistler on 2018-02-24 is the
                   case: Bluebird at 2% cloud, an 8-inch week, 2 inches fresh,
                   and the only thing the page said was 'too cold'.
                   A strict SUPERSET of the old condition -- a Great day
                   clears 16F and so carries the floor and the sky clause
                   automatically -- so no day loses the row it had. */
                + CASE WHEN t.Epic = 0 AND t.S24_4 = 0
                        AND t.Safe = 1
                        AND t.App >= @EpicMinF AND t.App <= @MaxApparentF
                        AND (t.App >= @MinApparentF OR t.OpaquePct <= @MostlyCloudPct)
                        AND t.S168_5 = 1
                   THEN 4 ELSE 0 END
    FROM Tiers t
;
END
GO

CREATE OR ALTER VIEW meteo.vSkiDay
AS
SELECT d.*, r.ResortName, r.StateOrProv, r.Region, r.MidElevationFt,
       r.GreenPercent, r.GreenAcres, r.PeakDayTicketUsd, r.Acres, r.VerticalFt,
       b.Snow24Cut2In, b.Snow24Cut4In, b.Snow72Cut5In, b.Snow168Cut5In, b.CoverCutFt
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
