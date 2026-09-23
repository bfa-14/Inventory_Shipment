CREATE   PROCEDURE masterdata.usp_ContainerType_Save
    @Id           INT           = NULL,
    @TypeCode     NVARCHAR(10),
    @TypeName     NVARCHAR(100),
    @MaxUnits     INT           = NULL,
    @MaxWeightKg  DECIMAL(18,3) = NULL,
    @MaxVolumeCbm DECIMAL(18,3) = NULL,
    @Description  NVARCHAR(500) = NULL,
    @IsActive     BIT           = 1,
    @RowVersion   BINARY(8)     = NULL,
    @UserId       INT           = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @TypeCode = UPPER(NULLIF(LTRIM(RTRIM(@TypeCode)), N''));
    SET @TypeName = NULLIF(LTRIM(RTRIM(@TypeName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @TypeCode IS NULL THROW 69000, 'Container type code is required.', 1;
    IF @TypeName IS NULL THROW 69000, 'Container type name is required.', 1;
    IF @MaxUnits IS NOT NULL AND @MaxUnits <= 0 THROW 69000, 'Maximum units must be greater than zero.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE TypeCode = @TypeCode AND (@Id IS NULL OR Id <> @Id))
        THROW 69013, 'This container type code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.ContainerTypes (TypeCode, TypeName, MaxUnits, MaxWeightKg, MaxVolumeCbm, Description, IsActive, CreatedBy)
        VALUES (@TypeCode, @TypeName, @MaxUnits, @MaxWeightKg, @MaxVolumeCbm, @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id) THROW 69006, 'Container type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.ContainerTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container type was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.ContainerTypes
        SET TypeCode = @TypeCode, TypeName = @TypeName, MaxUnits = @MaxUnits, MaxWeightKg = @MaxWeightKg,
            MaxVolumeCbm = @MaxVolumeCbm, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END
GO

