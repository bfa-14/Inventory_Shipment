/* ================================================================== 6. The functions */

-- (93) THE ONE PLACE OF RULE B4: a batch or serial no. as typed, scanned or pasted -> as kept. Tabs, line breaks, the
--      no-break space (NCHAR 160), the byte order mark (NCHAR 65279) and spaces are trimmed at BOTH ENDS ONLY (a scanner
--      adds a CR or a tab); one left inside stays, and the rules refuse it, so that a pasted "serial TAB expiry" never
--      glues into one serial. Then capitals (the comparison does not depend on the collation). Empty -> NULL. Compared
--      by code point (UNICODE), not by collation: a zero-width character is "ignorable" to a Windows collation. Called
--      ONCE per row by the procedures, never inside the problem function.
CREATE   FUNCTION inventory.fn_TrackingNo_Normalize (@Value NVARCHAR(100))
RETURNS NVARCHAR(100)
AS
BEGIN
    IF @Value IS NULL RETURN NULL;

    DECLARE @First INT = 1, @Last INT = DATALENGTH(@Value) / 2;   -- DATALENGTH: LEN ignores trailing spaces
    WHILE @First <= @Last AND UNICODE(SUBSTRING(@Value, @First, 1)) IN (9, 10, 13, 32, 160, 65279) SET @First += 1;
    WHILE @Last >= @First AND UNICODE(SUBSTRING(@Value, @Last, 1)) IN (9, 10, 13, 32, 160, 65279) SET @Last -= 1;
    IF @Last < @First RETURN NULL;

    RETURN UPPER(SUBSTRING(@Value, @First, @Last - @First + 1));
END

GO

