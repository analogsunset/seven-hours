/* ============================================================================
   Drop everything in ref / meteo / stg so the hourly build starts clean.

   DESTRUCTIVE. The daily pipeline (00-11) is removed rather than kept beside
   the hourly one: ski_resort_stats_2026.csv changed its naming convention from
   "Alta, UT" to "Alta - UT", so the daily fact can no longer join to the
   reference data and would silently answer with stale identities.

   Foreign keys are dropped dynamically rather than by hand-ordering the table
   drops. Two pipelines here use the same object names -- meteo.SourceFile and
   meteo.SourceFileUnit exist in both -- so any fixed order is wrong for one of
   them. Clearing every FK first makes the order irrelevant.
   ============================================================================ */

USE SKI_RESORT;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1. every foreign key in the three schemas
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
                   + N' DROP CONSTRAINT ' + QUOTENAME(f.name) + N';' + CHAR(10)
FROM sys.foreign_keys f
JOIN sys.tables  t ON t.object_id = f.parent_object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('ref', 'meteo', 'stg');
EXEC sp_executesql @sql;
GO

-- 2. every view, function and procedure in the three schemas
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'DROP ' +
       CASE o.type WHEN 'V' THEN N'VIEW' WHEN 'P' THEN N'PROCEDURE' ELSE N'FUNCTION' END +
       N' ' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) + N';' + CHAR(10)
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name IN ('ref', 'meteo', 'stg') AND o.type IN ('V', 'P', 'FN', 'IF', 'TF');
EXEC sp_executesql @sql;
GO

-- 3. every table
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'DROP TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N';' + CHAR(10)
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('ref', 'meteo', 'stg');
EXEC sp_executesql @sql;
GO

SELECT RemainingTables = COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('ref', 'meteo', 'stg');
GO

PRINT 'Reset complete -- run h01_schema.sql next.';
GO
