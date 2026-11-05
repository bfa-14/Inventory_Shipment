/* ================================================================== 6. reporting.usp_ItemBalance_LogRun */

CREATE   PROCEDURE reporting.usp_ItemBalance_LogRun
    @UserId     INT,
    @OutputKind NVARCHAR(10),
    @DateFrom   DATE,
    @DateTo     DATE,
    @CurrencyId INT = NULL,
    @RateType   TINYINT = NULL,
    @Criteria   NVARCHAR(MAX) = NULL,
    @RowsReturned INT,
    @DurationMs INT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO reporting.ItemBalanceReportRuns (UserId, OutputKind, DateFrom, DateTo, CurrencyId, RateType, Criteria, RowsReturned, DurationMs)
    VALUES (@UserId, @OutputKind, @DateFrom, @DateTo, @CurrencyId, @RateType, @Criteria, @RowsReturned, @DurationMs);
END