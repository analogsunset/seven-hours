# Seven Hours

**A riding day is not a day.** It is the seven hours the lifts turn, and the
weather during those seven hours is not the weather in a daily forecast summary.

This scores every winter day at **431 North American ski resorts** against
27 years of hourly reanalysis — 1999-06-01 to 2026-05-31, 102 million hourly
observations — and sorts each one into **Meh / Good / Great / Epic**. Pick the
dates of a trip and every winter on record is replayed over that same window.

## What decides a day

Each resort-day is reduced to the lift hours (09:00–15:00 local) and judged on
four axes. The full rules are in [`fail_rules.txt`](fail_rules.txt); the short
version:

| | |
|---|---|
| **Felt temperature** | apparent temperature, mean over the lift hours. Bitter Cold under 10 °F · Very Cold 10–15 · Chilly 16–19 · Comfortable 20–32 · Warm 33–45 · Very Warm over 45 |
| **Sky** | percent of sky under *opaque* cloud — the thicker of the low and mid layers, high cirrus excluded. Bluebird ≤5% through Cloudy >87.5%, with flat light outranking all six |
| **Wind** | gusts ≥40 mph over more than half the lift day |
| **Snow** | absolute inches across three windows (24 h, 72 h, a week), measured by SNOTEL wherever a gauge reaches and modelled otherwise |

**Good** is a rideable day. **Great** needs a 5-inch week behind it plus either
sun and comfort or 2 inches that morning. **Epic** is Great's snow path with
4 inches instead of 2. They nest by construction: every Epic day is Great, every
Great day is Good.

### Two things worth knowing about the model

**Every snow test is an absolute depth, never a percentile.** A per-resort
percentile ranks each mountain against itself, so it hands every one of them the
same quota of big-snow days however little it snows. Under that rule Mt. Lemmon,
Arizona — which averages about ten inches of snow in an entire season — scored
more Epic days than Alta, because its own 95th percentile was a fifth of an inch.
Resorts without a gauge are judged on modelled inches converted to their own
scale, not on their own ranking.

**Wind is measured on gusts, not sustained speed.** ERA5's 10 m wind is a
~25 km grid-cell mean: across 4.4 million lift hours it averages 5.3 mph and
reaches 40 mph exactly once, so a sustained-40 rule would never fire in 27
winters. The gust field is the one carrying mountain wind.

## How it fits together

```
Open-Meteo ERA5 (hourly)  ──h01_fetch──▶ json/  ──h02_shred──▶ pipe-delimited text
NRCS SNOTEL (daily)       ──h19_snotel_all──────────────────▶ station record
                                                     │
                                            SQL Server: 102M hourly rows
                                                     │
                                          h05_skiday.sql  ← the model
                                                     │
                                          h14_export.sql  ← the only SQL the page reads
                                    ┌────────────────┴────────────────┐
                          h07_pack.py                        h07_build.py
                    19 packed chars/day                 index + per-resort JSON
                          h15_build.py                        h15_web.py
                    seven_hours.html                          web/
                   one self-contained file            587 KB first paint, 431 resorts
```

Two build targets from one model. The single file exists because a published
Claude artifact is one uncompressed file under 16 MB, and inside that limit a
hand-rolled 92-character encoding is the only way the data fits. Served over
HTTP that inverts: gzipped, columnar JSON is ~10% *smaller* than the packing, so
the hosted build ships plain integers and lets the transport compress them.

```bash
python run_pipeline.py --all          # full rebuild from the JSON, ~86 min
python run_pipeline.py --export-only  # re-export and rebuild the page, ~40 s
python run_pipeline.py --web          # the hosted build, all 431 resorts
```

Every build ends in a verifier that decodes the shipped payload and compares
**every value** back to the SQL it came from — 11.9 million comparisons for the
artifact, 33.4 million for the hosted build. It exists because the encoding's
positional coupling has silently broken twice.

## Running it yourself

This is a personal project wired to one desktop, and it shows:

- **SQL Server 2022** is required, and the server (`NESO2`) and database
  (`SKI_RESORT`) names are **hardcoded** in `run_pipeline.py` and every SQL file.
- **Absolute paths are baked into the `BULK INSERT` statements** of
  `h03_reference.sql`, `h04_load_hourly.sql` and `h20_snotel_all.sql`. You will
  have to edit them.
- **The source data is not in this repo.** It is ~15 GiB of Open-Meteo JSON
  across 431 files plus the SNOTEL record. `h01_fetch.py` and
  `h19_snotel_all.py` regenerate both, but a full fetch is roughly 820,000
  Open-Meteo call-units — about 82 days on the free tier.
- Python 3 and Node, both standard library only. No dependencies to install.

[`REBUILD.md`](REBUILD.md) is the reconstruction spec: every table, every
parameter, the decisions already settled by measurement, and the defects known
to exist.

## Data

- **Weather** — [Open-Meteo](https://open-meteo.com/) ERA5 reanalysis archive.
- **Snow measurement** — USDA NRCS [SNOTEL](https://www.nrcs.usda.gov/wps/portal/wcc/home/)
  automated stations, via the AWDB REST API.
- **Resort statistics** — `ski_resort_stats_2026.csv`: Resort metadata in this project was assembled with the assistance of ChatGPT from publicly available web sources and subsequently edited, corrected, and supplemented by the project author.

Because source provenance was not retained for every original value, the dataset should not be treated as a verbatim reproduction of any single third-party dataset. Where possible, resort statistics are being independently verified against official resort websites, trail maps, and other primary sources.

Derived fields and weather-model fields are calculated by Seven Hours and are documented separately.

Neither ERA5 nor SNOTEL can see **snowmaking**, so every base-depth and snowfall
figure here is natural snow only, and resorts that manufacture theirs are
under-rated.
