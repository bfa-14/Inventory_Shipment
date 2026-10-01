CREATE   PROCEDURE masterdata.usp_PaymentMethod_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, MethodCode, MethodName, Description, IsActive,
           CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.PaymentMethods WHERE Id = @Id;
END

GO

