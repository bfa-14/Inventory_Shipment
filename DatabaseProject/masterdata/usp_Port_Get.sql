
CREATE   PROCEDURE masterdata.usp_Port_Get
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, PortCode, PortName, CountryCode, Kind, IsActive, CreatedAtUtc, CreatedBy, UpdatedAtUtc, UpdatedBy, RowVersion
    FROM masterdata.Ports WHERE Id = @Id;
END
GO

