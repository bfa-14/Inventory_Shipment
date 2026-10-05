/* ================================================================== 2. Helpers: number key, place of a container */

-- A container number or ref as it is compared: upper case, without spaces (non-breaking ones too), tabs, line breaks,
-- '-', '.', '/'. 'mscu 123-456.7' and 'MSCU1234567' give the same key; empty = nothing to match.
CREATE   FUNCTION logistics.fn_ContainerNumberKey (@Value NVARCHAR(100))
RETURNS TABLE
AS
RETURN
SELECT NumberKey = UPPER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@Value, N''),
                       N' ', N''), NCHAR(160), N''), NCHAR(8239), N''), NCHAR(9), N''), NCHAR(10), N''), NCHAR(13), N''),
                       N'-', N''), N'.', N''), N'/', N''));

GO

