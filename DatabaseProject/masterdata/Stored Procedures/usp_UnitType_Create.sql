CREATE   PROCEDURE masterdata.usp_UnitType_Create
    @UnitTypeName NVARCHAR(50),
    @IsActive     BIT = 1,
    @UserId       INT = NULL,
    @NewId        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @UnitTypeName = LTRIM(RTRIM(@UnitTypeName));
    SET @IsActive = ISNULL(@IsActive, 1);

    IF @UnitTypeName IS NULL OR @UnitTypeName = N''
        THROW 57000, 'Unit Type name is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.UnitTypes WHERE UnitTypeName = @UnitTypeName)
        THROW 57001, 'A unit type with this name already exists.', 1;

    INSERT INTO masterdata.UnitTypes (UnitTypeName, IsActive, CreatedBy) VALUES (@UnitTypeName, @IsActive, @UserId);
    SET @NewId = SCOPE_IDENTITY();
END