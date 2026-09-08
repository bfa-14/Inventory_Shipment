CREATE   PROCEDURE masterdata.usp_UnitType_Update
    @Id           INT,
    @UnitTypeName NVARCHAR(50),
    @IsActive     BIT       = 1,
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @UnitTypeName = LTRIM(RTRIM(@UnitTypeName));
    SET @IsActive = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id)
        THROW 57006, 'Unit type not found.', 1;
    IF @UnitTypeName IS NULL OR @UnitTypeName = N''
        THROW 57000, 'Unit Type name is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE UnitTypeName = @UnitTypeName AND Id <> @Id)
        THROW 57001, 'A unit type with this name already exists.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 57004, 'This unit type was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.UnitTypes
    SET UnitTypeName = @UnitTypeName, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END