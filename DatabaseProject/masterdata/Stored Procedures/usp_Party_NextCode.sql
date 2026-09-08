CREATE   PROCEDURE masterdata.usp_Party_NextCode
    @PartyType NVARCHAR(20)   -- Supplier | Client | Salesman | Employee
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Prefix NVARCHAR(4) =
        CASE @PartyType WHEN N'Supplier' THEN N'SUP-' WHEN N'Client' THEN N'CLI-'
                        WHEN N'Salesman' THEN N'SAL-' WHEN N'Employee' THEN N'EMP-' END;
    IF @Prefix IS NULL
        THROW 60000, 'Party type must be Supplier, Client, Salesman or Employee.', 1;

    DECLARE @Seq INT = 1, @Code NVARCHAR(20);
    SET @Code = @Prefix + RIGHT(N'0000' + CAST(@Seq AS NVARCHAR(10)), 4);
    WHILE EXISTS (SELECT 1 FROM masterdata.Parties WHERE PartyCode = @Code) AND @Seq < 100000
    BEGIN
        SET @Seq += 1;
        SET @Code = @Prefix + RIGHT(N'0000' + CAST(@Seq AS NVARCHAR(10)), 4);
    END

    SELECT SuggestedCode = @Code;
END