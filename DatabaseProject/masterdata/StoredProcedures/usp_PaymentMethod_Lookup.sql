CREATE   PROCEDURE masterdata.usp_PaymentMethod_Lookup
    @ActiveOnly BIT = 1,
    @IncludeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, MethodCode, MethodName, IsActive
    FROM masterdata.PaymentMethods
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
    ORDER BY MethodName;
END

GO

