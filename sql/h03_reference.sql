/* ============================================================================
   Reference load: WMO codes, and the 431 resorts from ski_resort_stats_2026.csv.
   Idempotent -- safe to re-run.

   The file is pipe-delimited with no quoting (resort names contain no pipes),
   pure ASCII, and LF-terminated -- note LF, not CRLF as the earlier revision
   of this file used, so ROWTERMINATOR is 0x0a.
   ============================================================================ */

USE SKI_RESORT;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

MERGE ref.WeatherCode AS tgt
USING (VALUES
    ( 0, N'Clear sky',                        'None'),
    ( 1, N'Mainly clear',                     'None'),
    ( 2, N'Partly cloudy',                    'None'),
    ( 3, N'Overcast',                         'None'),
    (45, N'Fog',                              'None'),
    (48, N'Depositing rime fog',              'None'),
    (51, N'Drizzle: light',                   'Drizzle'),
    (53, N'Drizzle: moderate',                'Drizzle'),
    (55, N'Drizzle: dense',                   'Drizzle'),
    (56, N'Freezing drizzle: light',          'Freezing'),
    (57, N'Freezing drizzle: dense',          'Freezing'),
    (61, N'Rain: slight',                     'Rain'),
    (63, N'Rain: moderate',                   'Rain'),
    (65, N'Rain: heavy',                      'Rain'),
    (66, N'Freezing rain: light',             'Freezing'),
    (67, N'Freezing rain: heavy',             'Freezing'),
    (71, N'Snow fall: slight',                'Snow'),
    (73, N'Snow fall: moderate',              'Snow'),
    (75, N'Snow fall: heavy',                 'Snow'),
    (77, N'Snow grains',                      'Snow'),
    (80, N'Rain showers: slight',             'Rain'),
    (81, N'Rain showers: moderate',           'Rain'),
    (82, N'Rain showers: violent',            'Rain'),
    (85, N'Snow showers: slight',             'Snow'),
    (86, N'Snow showers: heavy',              'Snow'),
    (95, N'Thunderstorm: slight or moderate', 'Thunderstorm'),
    (96, N'Thunderstorm with slight hail',    'Thunderstorm'),
    (99, N'Thunderstorm with heavy hail',     'Thunderstorm')
) AS src (WeatherCode, Description, PrecipType)
    ON tgt.WeatherCode = src.WeatherCode
WHEN MATCHED THEN UPDATE SET tgt.Description = src.Description, tgt.PrecipType = src.PrecipType
WHEN NOT MATCHED BY TARGET THEN
    INSERT (WeatherCode, Description, PrecipType)
    VALUES (src.WeatherCode, src.Description, src.PrecipType);
GO

TRUNCATE TABLE stg.ResortCsv;
GO

BULK INSERT stg.ResortCsv
FROM 'D:\TFS\JTDEV\python\ski_resort_stats\ski_resort_stats_2026.csv'
WITH (
    FIRSTROW        = 2,
    FIELDTERMINATOR = '|',
    ROWTERMINATOR   = '0x0a',   -- LF
    CODEPAGE        = '65001',
    TABLOCK
);
GO

/* The file's row terminator is not stable: it is maintained in Excel, and a
   save there writes CRLF where the previous revision was LF. ROWTERMINATOR is
   0x0a either way, so under CRLF the carriage return survives as the last
   character of the LAST column -- openmeteo_hourly_api_call, whose trailing
   "&elevation=1477.8228" would then be merged into ref.Resort and handed
   back to the fetcher. Stripping it here costs nothing on an LF file and makes
   the load indifferent to which one arrives. */
UPDATE stg.ResortCsv
SET openmeteo_hourly_api_call = REPLACE(openmeteo_hourly_api_call, CHAR(13), '')
WHERE openmeteo_hourly_api_call LIKE '%' + CHAR(13) + '%';
GO

IF (SELECT COUNT(*) FROM stg.ResortCsv) <> 431
    PRINT 'WARNING: expected 431 staged resorts -- check the CSV.';
GO

-- resort_name is the key: it is unique, and it is what the hourly filenames
-- follow. Coordinates are kept unique too, because they are what was sent to
-- the API, but they are not the join key for the hourly files.
IF EXISTS (SELECT 1 FROM stg.ResortCsv GROUP BY LTRIM(RTRIM(resort_name)) HAVING COUNT(*) > 1)
    THROW 50030, 'Two staged resorts share a name -- resort_name cannot be the key.', 1;
GO

MERGE ref.Resort AS tgt
USING (
    SELECT  ResortName   = LTRIM(RTRIM(s.resort_name)),
            StateOrProv  = NULLIF(LTRIM(RTRIM(s.state)), ''),
            Region       = NULLIF(LTRIM(RTRIM(s.region)), ''),
            PostalCode   = NULLIF(LTRIM(RTRIM(s.postal_code)), ''),
            Country      = NULLIF(LTRIM(RTRIM(s.country)), ''),
            Latitude     = TRY_CONVERT(decimal(9,6), s.lat),
            Longitude    = TRY_CONVERT(decimal(9,6), s.lon),
            IanaTimeZone = NULLIF(LTRIM(RTRIM(s.timezone)), ''),
            SummitFt       = TRY_CONVERT(int, s.summit),
            MidElevationFt = TRY_CONVERT(decimal(8,1), s.mid_elevation),
            BaseFt         = TRY_CONVERT(int, s.base),
            MidElevationM  = TRY_CONVERT(decimal(9,4), s.mid_elevation_meters),
            VerticalFt     = TRY_CONVERT(int, s.vertical),
            Lifts          = TRY_CONVERT(int, s.lifts),
            Runs           = TRY_CONVERT(int, s.runs),
            Acres          = TRY_CONVERT(int, s.acres),
            GreenPercent   = TRY_CONVERT(decimal(4,2), s.green_percent),
            GreenAcres     = TRY_CONVERT(decimal(9,2), s.green_acres),
            BluePercent    = TRY_CONVERT(decimal(4,2), s.blue_percent),
            BlueAcres      = TRY_CONVERT(decimal(9,2), s.blue_acres),
            BlackPercent   = TRY_CONVERT(decimal(4,2), s.black_percent),
            BlackAcres     = TRY_CONVERT(decimal(9,2), s.black_acres),
            TicketCurrency = NULLIF(LTRIM(RTRIM(s.ticket_currency)), ''),
            PeakDayTicketLocal    = TRY_CONVERT(decimal(9,2), s.peak_day_ticket_local),
            PeakDayTicketUsd      = TRY_CONVERT(decimal(9,2), s.peak_day_ticket_usd),
            AdvanceDayTicketLocal = TRY_CONVERT(decimal(9,2), s.advance_day_ticket_local),
            TicketBasis    = NULLIF(LTRIM(RTRIM(s.ticket_basis)), ''),
            TrailMapUrl    = NULLIF(LTRIM(RTRIM(s.map)), ''),
            OpenMeteoHourlyUrl = NULLIF(LTRIM(RTRIM(s.openmeteo_hourly_api_call)), '')
    FROM stg.ResortCsv s
    WHERE NULLIF(LTRIM(RTRIM(s.resort_name)), '') IS NOT NULL
      AND TRY_CONVERT(decimal(9,6), s.lat) IS NOT NULL
      AND TRY_CONVERT(decimal(9,6), s.lon) IS NOT NULL
) AS src
    ON tgt.ResortName = src.ResortName
WHEN MATCHED THEN UPDATE SET
        tgt.StateOrProv = src.StateOrProv, tgt.Region = src.Region,
        tgt.PostalCode = src.PostalCode, tgt.Country = src.Country,
        tgt.Latitude = src.Latitude, tgt.Longitude = src.Longitude,
        tgt.IanaTimeZone = src.IanaTimeZone,
        tgt.SummitFt = src.SummitFt, tgt.MidElevationFt = src.MidElevationFt,
        tgt.BaseFt = src.BaseFt, tgt.MidElevationM = src.MidElevationM,
        tgt.VerticalFt = src.VerticalFt, tgt.Lifts = src.Lifts,
        tgt.Runs = src.Runs, tgt.Acres = src.Acres,
        tgt.GreenPercent = src.GreenPercent, tgt.GreenAcres = src.GreenAcres,
        tgt.BluePercent = src.BluePercent, tgt.BlueAcres = src.BlueAcres,
        tgt.BlackPercent = src.BlackPercent, tgt.BlackAcres = src.BlackAcres,
        tgt.TicketCurrency = src.TicketCurrency,
        tgt.PeakDayTicketLocal = src.PeakDayTicketLocal,
        tgt.PeakDayTicketUsd = src.PeakDayTicketUsd,
        tgt.AdvanceDayTicketLocal = src.AdvanceDayTicketLocal,
        tgt.TicketBasis = src.TicketBasis, tgt.TrailMapUrl = src.TrailMapUrl,
        tgt.OpenMeteoHourlyUrl = src.OpenMeteoHourlyUrl
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ResortName, StateOrProv, Region, PostalCode, Country, Latitude, Longitude,
            IanaTimeZone, SummitFt, MidElevationFt, BaseFt, MidElevationM, VerticalFt,
            Lifts, Runs, Acres, GreenPercent, GreenAcres, BluePercent, BlueAcres,
            BlackPercent, BlackAcres, TicketCurrency, PeakDayTicketLocal, PeakDayTicketUsd,
            AdvanceDayTicketLocal, TicketBasis, TrailMapUrl, OpenMeteoHourlyUrl)
    VALUES (src.ResortName, src.StateOrProv, src.Region, src.PostalCode, src.Country,
            src.Latitude, src.Longitude, src.IanaTimeZone, src.SummitFt, src.MidElevationFt,
            src.BaseFt, src.MidElevationM, src.VerticalFt, src.Lifts, src.Runs, src.Acres,
            src.GreenPercent, src.GreenAcres, src.BluePercent, src.BlueAcres,
            src.BlackPercent, src.BlackAcres, src.TicketCurrency, src.PeakDayTicketLocal,
            src.PeakDayTicketUsd, src.AdvanceDayTicketLocal, src.TicketBasis,
            src.TrailMapUrl, src.OpenMeteoHourlyUrl);
GO

SELECT Resorts = COUNT(*), WithMidElev = SUM(CASE WHEN MidElevationFt IS NOT NULL THEN 1 ELSE 0 END),
       WithHourlyUrl = SUM(CASE WHEN OpenMeteoHourlyUrl IS NOT NULL THEN 1 ELSE 0 END)
FROM ref.Resort;
GO
