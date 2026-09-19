/* ============================================================================
   Trip odds over the hourly ski-day model.

   Same shape as the old daily version but on 27 winters instead of 9, which
   is the difference between "8 of 9 winters delivered" being noise and being
   a number worth acting on. A 6-day window across 27 seasons is 162
   observations per resort rather than 54.

   Each season is scored in its OWN calendar, so padding four days past Feb 28
   lands on Mar 3 in a leap winter and Mar 4 otherwise, and Feb 29 is a real
   date that 20 of the 27 winters simply do not have.
   ============================================================================ */

USE SKI_RESORT;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION meteo.fn_TripOdds
(
    @TripStart date,
    @TripEnd   date,
    @PadDays   int = 4
)
RETURNS TABLE
AS
RETURN
(
    WITH Seasons AS
    (
        SELECT DISTINCT SeasonStartYear FROM meteo.vSkiDay
    ),
    Win AS
    (
        -- each season's own window, in that season's calendar
        SELECT s.SeasonStartYear,
               WStart = DATEADD(day, -@PadDays,
                          DATEFROMPARTS(s.SeasonStartYear + CASE WHEN MONTH(@TripStart) >= 7 THEN 0 ELSE 1 END,
                                        MONTH(@TripStart), DAY(@TripStart))),
               WEnd   = DATEADD(day,  @PadDays,
                          DATEFROMPARTS(s.SeasonStartYear + CASE WHEN MONTH(@TripEnd) >= 7 THEN 0 ELSE 1 END,
                                        MONTH(@TripEnd), DAY(@TripEnd)))
        FROM Seasons s
    ),
    PerSeason AS
    (
        SELECT  d.ResortId, d.SeasonStartYear,
                Days      = COUNT(*),
                Covered   = SUM(d.IsCovered),
                Good      = SUM(d.IsGood),
                Great     = SUM(d.IsGreat),
                WindHold  = SUM(CASE WHEN d.WindHoldHours > 0 THEN 1 ELSE 0 END),
                FlatLight = SUM(CASE WHEN d.FlatLightHours > d.LiftHours / 2 THEN 1 ELSE 0 END),
                RainDays  = SUM(d.RainOnSnow),
                MeanApparentF = AVG(d.MeanApparentF),
                MeanChillF    = AVG(d.WindChillGapF),
                MeanSunFrac   = AVG(d.SunFraction),
                MeanBaseFt    = AVG(d.ModelBaseFt)
        FROM meteo.vSkiDay d
        JOIN Win w ON w.SeasonStartYear = d.SeasonStartYear
                  AND d.ObsDate BETWEEN w.WStart AND w.WEnd
        GROUP BY d.ResortId, d.SeasonStartYear
    )
    SELECT  r.ResortId, r.ResortName, r.StateOrProv, r.Region,
            r.MidElevationFt, r.PeakDayTicketUsd, r.GreenPercent, r.GreenAcres,
            r.Acres, r.VerticalFt,

            SeasonsObserved  = COUNT(*),
            DaysObserved     = SUM(p.Days),

            -- headline: how many winters delivered, out of 27
            SeasonsWithGreat = SUM(CASE WHEN p.Great >= 1 THEN 1 ELSE 0 END),
            SeasonsWithGood  = SUM(CASE WHEN p.Good  >= 1 THEN 1 ELSE 0 END),
            SeasonsWithTwoGreat = SUM(CASE WHEN p.Great >= 2 THEN 1 ELSE 0 END),

            AvgGreatPerTrip  = CONVERT(decimal(5,2), 1.0 * SUM(p.Great) / COUNT(*)),
            AvgGoodPerTrip   = CONVERT(decimal(5,2), 1.0 * SUM(p.Good)  / COUNT(*)),
            MinGreat = MIN(p.Great), MaxGreat = MAX(p.Great),

            -- the specific ways a trip goes wrong, per trip
            AvgWindHoldDays  = CONVERT(decimal(5,2), 1.0 * SUM(p.WindHold)  / COUNT(*)),
            AvgFlatLightDays = CONVERT(decimal(5,2), 1.0 * SUM(p.FlatLight) / COUNT(*)),
            AvgRainDays      = CONVERT(decimal(5,2), 1.0 * SUM(p.RainDays)  / COUNT(*)),

            AvgApparentF     = CONVERT(decimal(5,1), AVG(p.MeanApparentF)),
            AvgWindChillF    = CONVERT(decimal(5,1), AVG(p.MeanChillF)),
            AvgSunFraction   = CONVERT(decimal(5,3), AVG(p.MeanSunFrac)),
            AvgModelBaseFt   = CONVERT(decimal(5,2), AVG(p.MeanBaseFt))
    FROM PerSeason p
    JOIN ref.Resort r ON r.ResortId = p.ResortId
    GROUP BY r.ResortId, r.ResortName, r.StateOrProv, r.Region,
             r.MidElevationFt, r.PeakDayTicketUsd, r.GreenPercent, r.GreenAcres,
             r.Acres, r.VerticalFt
);
GO

PRINT 'Trip odds created: meteo.fn_TripOdds';
GO
