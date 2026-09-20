/* Exports the page payload. Three files, pipe-delimited, consumed by
   h07_pack.py. The snow-provenance fields are APPENDED to each layout so the
   existing positional reads in the packer keep working.

   THE VERTICAL CUT. Only resorts with at least @MinVerticalFt of vertical drop
   are exported. This is an editorial line, not missing data: the page is for
   mountains worth planning a trip around, and the payload is ~56 KB per resort
   so all 431 would come to 23.7 MB -- past the 16 MB an artifact can publish.
   At 899 ft it is 230 resorts and 12.6 MB.
   899 rather than a round 900 is deliberate: Mount Bohemia is exactly 900 ft
   and is a genuine destination, so the cut is set one foot below it rather
   than at a rounder number that would drop it.
   The three queries each declare the threshold because sqlcmd batches do not
   share variables; h07_pack.py asserts the resort count it reads matches the
   count the meta row reports, so a drift between them fails the build. */
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/* $(AllResorts) is supplied by run_pipeline.py: 0 builds the artifact's cut,
   1 builds everything. It is an INTEGER because sqlcmd 16 cannot carry a -v
   value containing spaces, and the region list is full of them. Passing the
   flag instead of the lists keeps both cuts defined here, once per batch, and
   sqlcmd fails loudly if the variable is not supplied. */
DECLARE @AllResorts bit = $(AllResorts);
DECLARE @MinVerticalFt int = CASE WHEN @AllResorts = 1 THEN 0 ELSE 899 END;
DECLARE @Regions nvarchar(400) = CASE WHEN @AllResorts = 1 THEN N''
       ELSE N'Alaska,Colorado & Utah,Northern Rockies,Pacific Northwest,Sierra Nevada,Southwest,Western Canada' END;
SELECT CONVERT(nvarchar(max), d.ResortName) + '|' +
       CONVERT(char(8), d.ObsDate, 112) + '|' +
       CONVERT(varchar(4), d.SeasonStartYear) + '|' +
       CONVERT(varchar(1), d.IsGood) + '|' + CONVERT(varchar(1), d.IsGreat) + '|' +
       CONVERT(varchar(1), d.IsEpic) + '|' +
       CONVERT(varchar(1), d.IsCovered) + '|' + CONVERT(varchar(1), d.IsFresh) + '|' +
       CONVERT(varchar(10), d.MeanApparentF) + '|' +
       CONVERT(varchar(10), d.SunFraction) + '|' +
       CONVERT(varchar(10), d.MaxGustMph) + '|' +
       CONVERT(varchar(10), d.WindHoldHours) + '|' +
       CONVERT(varchar(10), d.FlatLightHours) + '|' +
       CONVERT(varchar(10), d.ModelSnow72In) + '|' +
       CONVERT(varchar(10), d.ModelBaseFt) + '|' +
       d.FailReason + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(decimal(6,3), d.SnotelSwe72Rel)), '') + '|' +
       d.Visibility + '|' +
       CONVERT(varchar(10), d.MinApparentF) + '|' +
       CONVERT(varchar(10), d.MaxApparentF) + '|' +
       ISNULL(CONVERT(varchar(10), d.SnotelNewSnow72In), '') + '|' +
       ISNULL(CONVERT(varchar(10), d.SnotelSwe72In), '') + '|' +
       ISNULL(CONVERT(varchar(10), d.SnotelNewSnow24In), '') + '|' +
       CONVERT(varchar(10), d.FailMask) + '|' +
       -- APPENDED. Air temperature beside the felt one the tip already
       -- shows, in the same mean/low/high shape so the packer can quantise
       -- it exactly the way it quantises the apparent trio.
       CONVERT(varchar(10), d.MeanTempF) + '|' +
       CONVERT(varchar(10), d.MinTempF) + '|' +
       CONVERT(varchar(10), d.MaxTempF) + '|' +
       -- APPENDED for the 2026-09 tier rewrite. OpaquePct is the sky test the
       -- tiers now run on; the three snow windows are what Good, Great and Epic
       -- actually read. All four go on the END, because the packer reads this
       -- layout positionally.
       CONVERT(varchar(10), d.OpaquePct) + '|' +
       CONVERT(varchar(10), d.ModelSnow24In) + '|' +
       CONVERT(varchar(10), d.ModelSnow168In) + '|' +
       ISNULL(CONVERT(varchar(10), d.SnotelNewSnow168In), '') + '|' +
       -- APPENDED: the week verdict, decided once in SQL. Both builds used to
       -- re-derive it and the hosted one got it wrong on 98,896 days.
       CONVERT(varchar(1), d.IsWeekSnow) + '|' +
       -- APPENDED: what a day that cleared its tier fell short of on the next
       -- one up, so the tooltip can say "missed Great on" without the page
       -- re-deriving a rule it does not own. See MissMask in h05_skiday.sql.
       CONVERT(varchar(10), d.MissMask) + '|' +
       /* MEASURED-EQUIVALENT INCHES for the three modelled windows.
          The model side of every snow test is this resort's own bias-corrected
          equivalent of an inch figure, so dividing back out by the cut and
          multiplying by the inches it stands for returns the modelled snowfall
          to the scale a gauge would have reported it on.
          It is computed HERE, not on the page, for the same reason the week
          verdict is: it is a conversion that belongs to the benchmark, and a
          page that re-derives a scale it does not own gets it wrong eventually.
          Without these, 292 of 431 resorts -- 69.6% of all days -- printed a
          tooltip in multiples of their own thresholds while the other 139
          printed inches, and the 72-hour window, which is one of Great's three
          paths, did not appear on the modelled side at all. */
       CONVERT(varchar(10), CONVERT(decimal(7,2),
           ISNULL(d.ModelSnow24In  * 4.0 / NULLIF(b.Snow24Cut4In,  0), 0))) + '|' +
       CONVERT(varchar(10), CONVERT(decimal(7,2),
           ISNULL(d.ModelSnow72In  * 5.0 / NULLIF(b.Snow72Cut5In,  0), 0))) + '|' +
       CONVERT(varchar(10), CONVERT(decimal(7,2),
           ISNULL(d.ModelSnow168In * 5.0 / NULLIF(b.Snow168Cut5In, 0), 0)))
FROM meteo.vSkiDaySnow d
JOIN ref.Resort rr ON rr.ResortId = d.ResortId
JOIN meteo.ResortBenchmark b ON b.ResortId = d.ResortId
WHERE MONTH(d.ObsDate) IN (12,1,2,3,4)
  AND rr.VerticalFt >= @MinVerticalFt
  AND (@Regions = N'' OR rr.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ',')))
ORDER BY d.ResortName, d.ObsDate;
GO

/* Resort card: identity, terrain, the two model cuts, mean season snowfall,
   then the snow provenance the page labels each card with. */
/* $(AllResorts) is supplied by run_pipeline.py: 0 builds the artifact's cut,
   1 builds everything. It is an INTEGER because sqlcmd 16 cannot carry a -v
   value containing spaces, and the region list is full of them. Passing the
   flag instead of the lists keeps both cuts defined here, once per batch, and
   sqlcmd fails loudly if the variable is not supplied. */
DECLARE @AllResorts bit = $(AllResorts);
DECLARE @MinVerticalFt int = CASE WHEN @AllResorts = 1 THEN 0 ELSE 899 END;
DECLARE @Regions nvarchar(400) = CASE WHEN @AllResorts = 1 THEN N''
       ELSE N'Alaska,Colorado & Utah,Northern Rockies,Pacific Northwest,Sierra Nevada,Southwest,Western Canada' END;
SELECT CONVERT(nvarchar(max), r.ResortName) + '|' + r.StateOrProv + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.MidElevationFt)), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.VerticalFt)), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.Acres)), '') + '|' +
       ISNULL(CONVERT(varchar(10), r.GreenPercent), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.GreenAcres)), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.PeakDayTicketUsd)), '') + '|' +
       -- was FreshCutIn, the retired 80th-percentile fresh line. Now the
       -- model-inch equivalent of a 5-inch week, which is what the snow bar on
       -- each cell is drawn as a multiple of.
       CONVERT(varchar(10), b.Snow168Cut5In) + '|' +
       CONVERT(varchar(10), b.CoverCutFt) + '|' +
       CONVERT(varchar(10), s.SeasonSnowIn) + '|' +
       CASE WHEN sb.ResortId IS NULL THEN 'modelled' ELSE 'measured' END + '|' +
       ISNULL(CONVERT(varchar(10), sb.Stations), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(decimal(5,1), sb.NearestKm)), '') + '|' +
       ISNULL(CONVERT(varchar(10), sb.Kappa), '') + '|' +
       ISNULL(CONVERT(varchar(10), sb.Recall), '') + '|' +
       ISNULL(r.TicketCurrency, '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.PeakDayTicketLocal)), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.AdvanceDayTicketLocal)), '') + '|' +
       ISNULL(r.TrailMapUrl, '') + '|' +
       -- APPENDED, like the snow-provenance fields before it: the packer reads
       -- this layout positionally, so new columns go on the end, never in the
       -- middle. Region drives the page's region filter; the blue and black
       -- shares complete the terrain split the green columns already started.
       ISNULL(r.Region, '') + '|' +
       ISNULL(CONVERT(varchar(10), r.BluePercent), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.BlueAcres)), '') + '|' +
       ISNULL(CONVERT(varchar(10), r.BlackPercent), '') + '|' +
       ISNULL(CONVERT(varchar(10), CONVERT(int, r.BlackAcres)), '') + '|' +
       -- the elevation band. MidElevationFt already ships above and is what the
       -- weather was modelled at; base and summit give it a top and a bottom.
       ISNULL(CONVERT(varchar(10), r.BaseFt), '') + '|' +
       ISNULL(CONVERT(varchar(10), r.SummitFt), '') + '|' +
       ISNULL(CONVERT(varchar(10), r.Lifts), '') + '|' +
       ISNULL(CONVERT(varchar(10), r.Runs), '') + '|' +
       -- APPENDED: the model-inch equivalent of 2 measured inches in 24h, so
       -- the tooltip can say how far past its own line a day's snow sat.
       CONVERT(varchar(10), b.Snow24Cut2In)
FROM ref.Resort r
JOIN meteo.ResortBenchmark b ON b.ResortId = r.ResortId
CROSS APPLY (
    SELECT SeasonSnowIn = CONVERT(decimal(7,1), AVG(t.Tot))
    FROM (SELECT Tot = SUM(d.ModelDaySnowIn + d.ModelOvernightIn)
          FROM meteo.SkiDay d
          WHERE d.ResortId = r.ResortId AND MONTH(d.ObsDate) IN (12,1,2,3,4)
          GROUP BY d.SeasonStartYear) t
) s
LEFT JOIN meteo.SnotelBenchmark sb ON sb.ResortId = r.ResortId
WHERE r.VerticalFt >= @MinVerticalFt
  AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ',')))
ORDER BY r.ResortName;
GO

/* ---------------------------------------------------------------------------
   Build facts, one row, for the prose on the page.

   The page used to state its own scale in hardcoded text -- "9 resorts",
   "2.13 million hours", "only nine have been fetched". Those were written when
   nine resorts were loaded and were silently wrong the moment the set changed,
   which is exactly the failure mode a page that ships its own data should not
   have. Every count the page asserts about ITSELF now comes from here.

   What does NOT come from here: findings from the nine-resort calibration
   study (the lag test, the station gate, the consensus comparison). Those are
   measurements of a completed experiment, not descriptions of this build, and
   recomputing them per build would make them say something they never showed.
   They are labelled as that sample's results in the page instead.
   --------------------------------------------------------------------------- */
/* $(AllResorts) is supplied by run_pipeline.py: 0 builds the artifact's cut,
   1 builds everything. It is an INTEGER because sqlcmd 16 cannot carry a -v
   value containing spaces, and the region list is full of them. Passing the
   flag instead of the lists keeps both cuts defined here, once per batch, and
   sqlcmd fails loudly if the variable is not supplied. */
DECLARE @AllResorts bit = $(AllResorts);
DECLARE @MinVerticalFt int = CASE WHEN @AllResorts = 1 THEN 0 ELSE 899 END;
DECLARE @Regions nvarchar(400) = CASE WHEN @AllResorts = 1 THEN N''
       ELSE N'Alaska,Colorado & Utah,Northern Rockies,Pacific Northwest,Sierra Nevada,Southwest,Western Canada' END;
-- 'resorts' is what the page SHOWS: loaded AND past the vertical cut. 'loaded'
-- is everything fetched, so the page can say how many it set aside and why.
SELECT CONVERT(varchar(20), (SELECT COUNT(*) FROM meteo.SourceFile sf
                             JOIN ref.Resort r ON r.ResortId = sf.ResortId
                             WHERE r.VerticalFt >= @MinVerticalFt
                               AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       -- Filtered like every other figure here. It answers 27 either way today,
       -- because all 431 resorts carry the identical 27 seasons -- but that is
       -- a property of this fetch, not of the query, and an unfiltered count
       -- would keep saying 27 after a partial one.
       CONVERT(varchar(20), (SELECT COUNT(DISTINCT d.SeasonStartYear) FROM meteo.SkiDay d
                             JOIN ref.Resort r ON r.ResortId = d.ResortId
                             WHERE MONTH(d.ObsDate) IN (12,1,2,3,4)
                               AND r.VerticalFt >= @MinVerticalFt
                               AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       CONVERT(varchar(20), (SELECT COUNT_BIG(*) FROM meteo.HourlyObs h
                             JOIN ref.Resort r ON r.ResortId = h.ResortId
                             WHERE r.VerticalFt >= @MinVerticalFt
                               AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       -- likewise: the years the SHOWN mountains span, not the whole warehouse
       CONVERT(varchar(20), (SELECT MIN(YEAR(h.ObsHour)) FROM meteo.HourlyObs h
                             JOIN ref.Resort r ON r.ResortId = h.ResortId
                             WHERE r.VerticalFt >= @MinVerticalFt
                               AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       CONVERT(varchar(20), (SELECT MAX(YEAR(h.ObsHour)) FROM meteo.HourlyObs h
                             JOIN ref.Resort r ON r.ResortId = h.ResortId
                             WHERE r.VerticalFt >= @MinVerticalFt
                               AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       CONVERT(varchar(20), (SELECT COUNT(*) FROM ref.Resort)) + '|' +
       -- resorts in the reference file with at least one station inside the gate
       CONVERT(varchar(20), (SELECT COUNT(DISTINCT ResortId) FROM ref.ResortSnotel)) + '|' +
       -- of the loaded resorts, how many carry a measured-snow badge
       CONVERT(varchar(20), (SELECT COUNT(*) FROM meteo.SnotelBenchmark sb
                             JOIN ref.Resort r ON r.ResortId = sb.ResortId
                             WHERE r.VerticalFt >= @MinVerticalFt
                               AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       -- the cut itself, and how many loaded resorts it set aside
       CONVERT(varchar(20), @MinVerticalFt) + '|' +
       CONVERT(varchar(20), (SELECT COUNT(*) FROM meteo.SourceFile)) + '|' +
       CONVERT(varchar(20), (SELECT COUNT(*) FROM ref.Resort
                             WHERE VerticalFt >= @MinVerticalFt
                               AND (@Regions = N'' OR Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       -- Share of shown Dec-Apr days whose BASE came from a gauge rather than
       -- the model. The page states this figure, and it moves with the resort
       -- set: on the nine it was 93-100%, on 154 with 33 ungauged it is ~74%.
       CONVERT(varchar(20), (SELECT CONVERT(int, ROUND(100.0 *
                 SUM(CASE WHEN d.BaseSource = 'measured' THEN 1 ELSE 0 END) / COUNT(*), 0))
              FROM meteo.SkiDay d
              JOIN ref.Resort r ON r.ResortId = d.ResortId
              WHERE MONTH(d.ObsDate) IN (12,1,2,3,4)
                AND r.VerticalFt >= @MinVerticalFt
                AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ','))))) + '|' +
       -- Share of shown days the page labels "Flat light" -- the same test the
       -- Viz label uses, so the figure in the legend cannot drift from the
       -- labels beside it.
       CONVERT(varchar(20), (SELECT CONVERT(int, ROUND(100.0 *
                 SUM(CASE WHEN d.FlatLightHours > d.LiftHours / 2.0 THEN 1 ELSE 0 END) / COUNT(*), 0))
              FROM meteo.SkiDay d
              JOIN ref.Resort r ON r.ResortId = d.ResortId
              WHERE MONTH(d.ObsDate) IN (12,1,2,3,4)
                AND r.VerticalFt >= @MinVerticalFt
                AND (@Regions = N'' OR r.Region IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Regions, ',')))));
GO
