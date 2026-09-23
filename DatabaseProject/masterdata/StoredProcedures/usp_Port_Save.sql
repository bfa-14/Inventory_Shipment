CREATE   PROCEDURE masterdata.usp_Port_Save
    @Id          INT           = NULL,
    @PortCode    NVARCHAR(10),
    @PortName    NVARCHAR(100),
    @CountryCode NCHAR(2)      = NULL,
    @Kind        NVARCHAR(10)  = N'Sea',
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PortCode = UPPER(NULLIF(LTRIM(RTRIM(@PortCode)), N''));
    SET @PortName = NULLIF(LTRIM(RTRIM(@PortName)), N'');
    SET @CountryCode = UPPER(NULLIF(LTRIM(RTRIM(@CountryCode)), N''));
    SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), N'');
    IF @PortCode IS NULL THROW 69000, 'Port code is required.', 1;
    IF @PortName IS NULL THROW 69000, 'Port name is required.', 1;
    IF @Kind IS NULL OR @Kind NOT IN (N'Sea', N'Inland', N'Border', N'Air') THROW 69000, 'Kind must be Sea, Inland, Border or Air.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.Ports WHERE PortCode = @PortCode AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This port code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.Ports (PortCode, PortName, CountryCode, Kind, IsActive, CreatedBy)
        VALUES (@PortCode, @PortName, @CountryCode, @Kind, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id) THROW 69006, 'Port not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Ports WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This port was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.Ports
        SET PortCode = @PortCode, PortName = @PortName, CountryCode = @CountryCode, Kind = @Kind,
            IsActive = ISNULL(@IsActive, 1), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END

GO

