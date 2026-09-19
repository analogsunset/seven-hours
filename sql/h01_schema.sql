/* ============================================================================
   Hourly ski-conditions warehouse -- schema
   Target: SQL Server 2016+ (2019+ for the UTF-8 collation)

   REPLACES the daily pipeline (00-11). This is not an extension of it: the
   resort reference file changed shape (431 rows, 29 columns) and its naming
   convention changed from "Alta, UT" to "Alta - UT", so the old daily fact
   could not join to it any more. The old objects are dropped in h00_reset.sql.

   SOURCE: json/hourly/<Resort> - <ST>_19990601-20260531.json
   One file per resort, Open-Meteo ERA5 archive, 236,688 hourly rows each
   covering 1999-06-01 to 2026-05-31 -- 27 years.

   THREE PROPERTIES OF THIS FEED THAT THE DAILY DATA DID NOT HAVE
   --------------------------------------------------------------
   1. TIMES ARE LOCAL. Each request passed an explicit IANA timezone
      (timezone=America/Denver and so on), so hour 09:00 in the file is 09:00
      at the resort. Lift hours need no conversion, and a "sunny day" can be
      restricted to the hours the lifts actually turn.

   2. ELEVATION-CORRECTED. Each request passed elevation=<mid_elevation_meters>,
      so the model interpolates to mid-mountain rather than returning the ~25 km
      grid cell's own elevation. The old daily pull did not do this, and its
      temperatures were biased warm and its snowfall low wherever the cell sat
      below the resort.

   3. IT CARRIES WHAT ACTUALLY RUINS A SKI DAY. Not just temperature and
      snowfall, but snow_depth (is there a base at all), rain (rain-on-snow),
      wind_gusts_10m (lift holds), cloud_cover_low (flat light and whiteout,
      which is a different problem from "not sunny"), and apparent_temperature
      (what the wind makes it feel like).

   Coverage today is 9 resorts. ref.Resort holds all 431 and every row carries
   an OpenMeteoHourlyUrl, so the loader scales to the rest unchanged.

   JOINING FILES TO RESORTS: by filename, not by coordinate. Two of the nine
   filenames are shortened ("Showdown - MT" for "Showdown Montana - MT",
   "Whitefish - MT" for "Whitefish Mountain - MT"), so the rule is exact match
   first, then unique prefix within the same state. Coordinates CANNOT be used:
   the returned point is grid-snapped, and nearest-neighbour matching puts
   Heavenly's file on Sierra-at-Tahoe and Snowbird's on Alta.
   ============================================================================ */

IF DB_ID('SKI_RESORT') IS NULL
    CREATE DATABASE SKI_RESORT;
GO
USE SKI_RESORT;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID('ref')   IS NULL EXEC('CREATE SCHEMA ref');
IF SCHEMA_ID('meteo') IS NULL EXEC('CREATE SCHEMA meteo');
IF SCHEMA_ID('stg')   IS NULL EXEC('CREATE SCHEMA stg');
GO

/* -------------------------------------------------------------- reference -- */

-- WMO weather interpretation codes. PrecipType is the only thing taken from
-- them: measured against sunshine, the codes classify what fell, not how
-- cloudy it was. cloud_cover_low/mid/high do the cloud job properly now.
CREATE TABLE ref.WeatherCode
(
    WeatherCode int          NOT NULL CONSTRAINT PK_WeatherCode PRIMARY KEY,
    Description nvarchar(80) NOT NULL,
    PrecipType  varchar(12)  NOT NULL,
    CONSTRAINT CK_WeatherCode_PrecipType CHECK (PrecipType IN
        ('None', 'Drizzle', 'Rain', 'Freezing', 'Snow', 'Thunderstorm'))
);
GO

/*
   Resorts, from ski_resort_stats_2026.csv -- 431 rows, 29 columns, pipe
   delimited. resort_name is the key: unique, and the naming convention
   ("Alta - UT") is what the hourly filenames follow.

   MidElevationFt is new and is the elevation the weather was actually
   requested at, so it is the one to quote alongside any temperature here.
*/
CREATE TABLE ref.Resort
(
    ResortId        int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Resort PRIMARY KEY,
    ResortName      nvarchar(80)      NOT NULL,   -- 'Showdown Montana - MT'
    StateOrProv     nvarchar(40)      NULL,
    Region          nvarchar(60)      NULL,
    PostalCode      nvarchar(12)      NULL,
    Country         nvarchar(20)      NULL,
    Latitude        decimal(9,6)      NOT NULL,   -- as requested from the API
    Longitude       decimal(9,6)      NOT NULL,
    IanaTimeZone    varchar(40)       NULL,       -- 'America/Denver'

    SummitFt        int               NULL,
    MidElevationFt  decimal(8,1)      NULL,       -- what the weather is modelled at;
                                                -- fractional, it is the summit/base midpoint
    BaseFt          int               NULL,
    MidElevationM   decimal(9,4)      NULL,       -- as sent in the API's elevation=
    VerticalFt      int               NULL,
    Lifts           int               NULL,
    Runs            int               NULL,
    Acres           int               NULL,
    GreenPercent    decimal(4,2)      NULL,
    GreenAcres      decimal(9,2)      NULL,
    BluePercent     decimal(4,2)      NULL,
    BlueAcres       decimal(9,2)      NULL,
    BlackPercent    decimal(4,2)      NULL,
    BlackAcres      decimal(9,2)      NULL,

    TicketCurrency  char(3)           NULL,
    PeakDayTicketLocal    decimal(9,2) NULL,
    PeakDayTicketUsd      decimal(9,2) NULL,
    AdvanceDayTicketLocal decimal(9,2) NULL,
    TicketBasis     varchar(20)       NULL,
    TrailMapUrl     nvarchar(400)     NULL,
    OpenMeteoHourlyUrl nvarchar(1000) NULL,

    -- filled by the hourly load; null until this resort has data
    GridLatitude    decimal(9,6)      NULL,       -- the cell the request snapped to
    GridLongitude   decimal(9,6)      NULL,
    GridElevationM  decimal(7,1)      NULL,

    CONSTRAINT UQ_Resort_Name  UNIQUE (ResortName),
    CONSTRAINT UQ_Resort_Point UNIQUE (Latitude, Longitude),
    CONSTRAINT CK_Resort_Lat CHECK (Latitude  BETWEEN  -90 AND  90),
    CONSTRAINT CK_Resort_Lon CHECK (Longitude BETWEEN -180 AND 180)
);
GO

/* ---------------------------------------------------------------- sources -- */

CREATE TABLE meteo.SourceFile
(
    SourceFileId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SourceFile PRIMARY KEY,
    ResortId     int               NOT NULL,
    FileName     nvarchar(260)     NOT NULL,
    RangeStart   date              NOT NULL,
    RangeEnd     date              NOT NULL,
    HourCount    int               NOT NULL,
    Timezone     nvarchar(64)      NULL,
    UtcOffsetSec int               NULL,
    GridLatitude    decimal(9,6)   NULL,
    GridLongitude   decimal(9,6)   NULL,
    GridElevationM  decimal(7,1)   NULL,
    LoadedUtc    datetime2(3)      NOT NULL CONSTRAINT DF_SourceFile_Loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_SourceFile_FileName UNIQUE (FileName),
    CONSTRAINT UQ_SourceFile_Resort   UNIQUE (ResortId),
    CONSTRAINT FK_SourceFile_Resort FOREIGN KEY (ResortId) REFERENCES ref.Resort (ResortId)
);
GO

-- daily_units / hourly_units as returned, so a silent switch to mm or celsius
-- cannot corrupt the fact table unnoticed.
CREATE TABLE meteo.SourceFileUnit
(
    SourceFileId int          NOT NULL,
    VariableName varchar(40)  NOT NULL,
    UnitText     nvarchar(40) NOT NULL,
    CONSTRAINT PK_SourceFileUnit PRIMARY KEY (SourceFileId, VariableName),
    CONSTRAINT FK_SourceFileUnit_SourceFile FOREIGN KEY (SourceFileId)
        REFERENCES meteo.SourceFile (SourceFileId) ON DELETE CASCADE
);
GO

/* ------------------------------------------------------------------ fact -- */

/*
   One row per resort per local hour. 236,688 hours per resort.

   Observed ranges across the nine loaded resorts, which set the column widths:
     TempF        -42.2 .. 87.2      SnowfallIn      0 .. 1.874 per hour
     ApparentF    -52.1 .. 85.1      SnowDepthFt     0 .. 9.547
     RainIn        0 .. 0.378        Gust10Mph     0.9 .. 73.4
     SunshineSec   0 .. 3600         CloudCover*     0 .. 100
   No nulls in any variable in any file.
*/
CREATE TABLE meteo.HourlyObs
(
    ResortId       int          NOT NULL,
    ObsHour        datetime2(0) NOT NULL,   -- LOCAL time at the resort

    TempF          decimal(5,1) NOT NULL,
    ApparentF      decimal(5,1) NOT NULL,
    DewPointF      decimal(5,1) NOT NULL,
    RelHumidity    smallint     NOT NULL,

    SnowfallIn     decimal(6,3) NOT NULL,   -- new snow this hour
    SnowDepthFt    decimal(6,3) NOT NULL,   -- settled base
    RainIn         decimal(6,3) NOT NULL,

    CloudTotalPct  smallint     NOT NULL,   -- all layers combined
    CloudLowPct    smallint     NOT NULL,   -- flat light / whiteout when high
    CloudMidPct    smallint     NOT NULL,
    CloudHighPct   smallint     NOT NULL,
    SunshineSec    decimal(6,1) NOT NULL,   -- 0..3600 within the hour

    /* Radiation, W/m2. SunshineSec is a threshold count and saturates; these do
       not. ShortwaveWm2 / TerrestrialWm2 gives a clear-sky index that separates
       a dull overcast hour from a brilliant one, which SunshineSec cannot.
       *_Inst are instantaneous at the timestamp; the others are hour means. */
    DirectNormalWm2     decimal(6,1) NOT NULL,
    DiffuseWm2          decimal(6,1) NOT NULL,
    ShortwaveWm2        decimal(6,1) NOT NULL,
    TerrestrialWm2      decimal(6,1) NOT NULL,
    DirectNormalInstWm2 decimal(6,1) NOT NULL,
    DiffuseInstWm2      decimal(6,1) NOT NULL,
    ShortwaveInstWm2    decimal(6,1) NOT NULL,
    TerrestrialInstWm2  decimal(6,1) NOT NULL,

    WindSpd10Mph   decimal(5,1) NOT NULL,
    WindSpd100Mph  decimal(5,1) NOT NULL,
    Gust10Mph      decimal(5,1) NOT NULL,
    WindDir10Deg   smallint     NOT NULL,
    WindDir100Deg  smallint     NOT NULL,

    WeatherCode    int          NOT NULL,
    IsDaylight     bit          NOT NULL,

    -- The ski season a date belongs to: Jul 1 YYYY .. Jun 30 YYYY+1 -> YYYY.
    SeasonStartYear AS (CASE WHEN MONTH(ObsHour) >= 7
                             THEN YEAR(ObsHour) ELSE YEAR(ObsHour) - 1 END) PERSISTED NOT NULL,
    ObsDate AS (CONVERT(date, ObsHour)) PERSISTED NOT NULL,
    ObsHourOfDay AS (DATEPART(hour, ObsHour)) PERSISTED NOT NULL,

    CONSTRAINT PK_HourlyObs PRIMARY KEY CLUSTERED (ResortId, ObsHour),
    CONSTRAINT FK_HourlyObs_Resort      FOREIGN KEY (ResortId)    REFERENCES ref.Resort (ResortId),
    CONSTRAINT FK_HourlyObs_WeatherCode FOREIGN KEY (WeatherCode) REFERENCES ref.WeatherCode (WeatherCode),
    CONSTRAINT CK_HourlyObs_Temp     CHECK (TempF BETWEEN -100 AND 130),
    CONSTRAINT CK_HourlyObs_Sun      CHECK (SunshineSec BETWEEN 0 AND 3600),
    CONSTRAINT CK_HourlyObs_Cloud    CHECK (CloudLowPct BETWEEN 0 AND 100
                                        AND CloudMidPct BETWEEN 0 AND 100
                                        AND CloudHighPct BETWEEN 0 AND 100),
    CONSTRAINT CK_HourlyObs_NonNeg   CHECK (SnowfallIn >= 0 AND SnowDepthFt >= 0 AND RainIn >= 0)
);
GO

CREATE INDEX IX_HourlyObs_Date   ON meteo.HourlyObs (ObsDate, ResortId);
CREATE INDEX IX_HourlyObs_Season ON meteo.HourlyObs (SeasonStartYear, ResortId);
GO

/* --------------------------------------------------------------- staging -- */

-- Landing table for the shredded hourly files. The JSON is 22 MB per resort
-- with 18 parallel arrays of 236,688 elements; OPENJSON would need a pass per
-- variable per file. h02_load.py flattens to pipe-delimited text instead and
-- this is BULK INSERTed, which is the difference between minutes and seconds.
CREATE TABLE stg.HourlyRaw
(
    ResortName    nvarchar(80) NOT NULL,
    ObsHour       datetime2(0) NOT NULL,
    TempF          decimal(5,1) NOT NULL,
    ApparentF      decimal(5,1) NOT NULL,
    SnowfallIn     decimal(6,3) NOT NULL,
    SnowDepthFt    decimal(6,3) NOT NULL,
    RainIn         decimal(6,3) NOT NULL,
    CloudTotalPct  smallint     NOT NULL,
    CloudLowPct    smallint     NOT NULL,
    CloudMidPct    smallint     NOT NULL,
    CloudHighPct   smallint     NOT NULL,
    WeatherCode    int          NOT NULL,
    WindDir100Deg  smallint     NOT NULL,
    WindDir10Deg   smallint     NOT NULL,
    WindSpd100Mph  decimal(5,1) NOT NULL,
    WindSpd10Mph   decimal(5,1) NOT NULL,
    Gust10Mph      decimal(5,1) NOT NULL,
    DewPointF      decimal(5,1) NOT NULL,
    RelHumidity    smallint     NOT NULL,
    SunshineSec    decimal(6,1) NOT NULL,
    /* The radiation block, in url order. sunshine_duration is a threshold and
       saturates -- 230 W/m2 under solid cloud and 915 W/m2 at clear noon both
       score a full 3600 s -- so these carry the magnitude it discards.
       terrestrial_* is top-of-atmosphere: the clear-sky reference to divide by.
       The *_Inst twins are the instantaneous value at the timestamp rather than
       the hour mean. Observed 0 .. ~1050 W/m2. */
    DirectNormalWm2     decimal(6,1) NOT NULL,
    DiffuseWm2          decimal(6,1) NOT NULL,
    ShortwaveWm2        decimal(6,1) NOT NULL,
    TerrestrialWm2      decimal(6,1) NOT NULL,
    DirectNormalInstWm2 decimal(6,1) NOT NULL,
    DiffuseInstWm2      decimal(6,1) NOT NULL,
    ShortwaveInstWm2    decimal(6,1) NOT NULL,
    TerrestrialInstWm2  decimal(6,1) NOT NULL,
    IsDaylight     bit          NOT NULL
);
GO

CREATE TABLE stg.ResortCsv
(
    resort_name nvarchar(200) NULL, state nvarchar(200) NULL, region nvarchar(200) NULL,
    postal_code nvarchar(200) NULL, summit nvarchar(200) NULL, mid_elevation nvarchar(200) NULL,
    base nvarchar(200) NULL, vertical nvarchar(200) NULL, lifts nvarchar(200) NULL,
    runs nvarchar(200) NULL, acres nvarchar(200) NULL,
    green_percent nvarchar(200) NULL, green_acres nvarchar(200) NULL,
    blue_percent nvarchar(200) NULL, blue_acres nvarchar(200) NULL,
    black_percent nvarchar(200) NULL, black_acres nvarchar(200) NULL,
    lat nvarchar(200) NULL, lon nvarchar(200) NULL, mid_elevation_meters nvarchar(200) NULL,
    timezone nvarchar(200) NULL, country nvarchar(200) NULL, ticket_currency nvarchar(200) NULL,
    peak_day_ticket_local nvarchar(200) NULL, peak_day_ticket_usd nvarchar(200) NULL,
    advance_day_ticket_local nvarchar(200) NULL, ticket_basis nvarchar(200) NULL,
    map nvarchar(1000) NULL, openmeteo_hourly_api_call nvarchar(2000) NULL
);
GO

PRINT 'Hourly schema created.';
GO
