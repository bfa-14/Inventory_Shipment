CREATE   PROCEDURE masterdata.usp_Port_Lookup
    @Kind       NVARCHAR(10) = NULL,
    @ActiveOnly BIT          = 1,
    @IncludeId  INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), N'');
    SELECT Id, PortCode, PortName, CountryCode, Kind, IsActive
    FROM masterdata.Ports
    WHERE (@ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId)
      AND (@Kind IS NULL OR Kind = @Kind OR Id = @IncludeId)
    ORDER BY PortName;
END

GO

